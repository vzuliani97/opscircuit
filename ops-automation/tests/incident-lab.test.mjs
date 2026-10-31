// Integration tests for the incident lab. They drive the running stack (`make up`) through the public
// webhook and through Alertmanager, and read the results from PostgreSQL and the mock notifier.
// They reset lab data first. Tests run in order; the restart test depends on the happy-path incident.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFileSync, spawn } from 'node:child_process';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const WEBHOOK = 'http://127.0.0.1:5678/webhook/alertmanager';
const N8N = 'http://127.0.0.1:5678';
const NOTIFIER = 'http://127.0.0.1:8099';
const ALERTMANAGER = 'http://127.0.0.1:9093';
const MAX_NOTIFY_ATTEMPTS = 3; // "Notify on-call" node: retryOnFail with maxTries 3, 1 s apart

const env = Object.fromEntries(
  readFileSync(path.join(ROOT, '.env'), 'utf8')
    .split('\n')
    .filter((line) => line && !line.startsWith('#'))
    .map((line) => [line.slice(0, line.indexOf('=')), line.slice(line.indexOf('=') + 1)]),
);
const TOKEN = env.ALERT_WEBHOOK_TOKEN;
const RUN = Date.now();

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function sql(query) {
  return execFileSync(
    'docker',
    ['compose', 'exec', '-T', 'postgres', 'psql', '-U', 'postgres', '-d', 'incidents', '-AtX', '-v', 'ON_ERROR_STOP=1', '-c', query],
    { cwd: ROOT, encoding: 'utf8' },
  ).trim();
}

function rows(query) {
  return JSON.parse(sql(`SELECT coalesce(json_agg(t), '[]') FROM (${query}) AS t`));
}

function count(table, where = 'true') {
  return Number(sql(`SELECT count(*) FROM ${table} WHERE ${where}`));
}

function quote(text) {
  return `'${String(text).replaceAll("'", "''")}'`;
}

function rawFixture(name) {
  return JSON.parse(readFileSync(path.join(ROOT, 'fixtures', `${name}.json`), 'utf8'));
}

// Each test gets its own firing episode (startsAt), so incidents never collide across tests.
function fixture(name, episode) {
  const body = rawFixture(name);
  const startsAt = new Date(RUN - episode * 60_000).toISOString();
  for (const alert of body.alerts) alert.startsAt = startsAt;
  return body;
}

function fingerprintOf(alert) {
  const identity = JSON.stringify([
    alert.labels.alertname,
    alert.labels.namespace ?? 'default',
    alert.labels.service ?? 'unknown',
    new Date(alert.startsAt).toISOString(),
  ]);
  return createHash('sha256').update(identity).digest('hex');
}

async function post(body, { token = TOKEN } = {}) {
  const headers = { 'content-type': 'application/json' };
  if (token) headers.authorization = `Bearer ${token}`;
  const res = await fetch(WEBHOOK, { method: 'POST', headers, body: JSON.stringify(body) });
  const text = await res.text();
  let json = null;
  try {
    json = JSON.parse(text);
  } catch {
    // auth failures answer with plain text
  }
  return { status: res.status, body: json, text };
}

async function waitFor(what, check, { timeoutMs = 20_000, intervalMs = 250 } = {}) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const result = await check();
    if (result) return result;
    await sleep(intervalMs);
  }
  throw new Error(`timed out after ${timeoutMs} ms waiting for ${what}`);
}

function incident(fingerprint) {
  return rows(`SELECT * FROM incidents WHERE fingerprint = ${quote(fingerprint)}`)[0];
}

async function notifier(pathname, body) {
  const res = await fetch(`${NOTIFIER}${pathname}`, body ? { method: 'POST', body: JSON.stringify(body) } : {});
  return res.json();
}

async function waitForN8n() {
  await waitFor('n8n readiness', async () => (await fetch(`${N8N}/healthz/readiness`).catch(() => null))?.ok, {
    timeoutMs: 120_000,
    intervalMs: 1000,
  });
}

function runReplay() {
  return execFileSync('sh', ['scripts/replay-dead-letters.sh'], { cwd: ROOT, encoding: 'utf8' });
}

before(async () => {
  await waitForN8n();
  sql('TRUNCATE dead_letters, incidents, alert_deliveries, rejected_events RESTART IDENTITY CASCADE');
  await notifier('/reset', {});
});

after(() => {
  console.log(`\nincident_outcomes after the suite:\n${JSON.stringify(rows('SELECT * FROM incident_outcomes')[0], null, 2)}`);
});

test('authentication: a missing or wrong token is rejected before the workflow runs', async () => {
  const body = fixture('firing-paypoint-backend', 1);
  const missing = await post(body, { token: null });
  const wrong = await post(body, { token: 'not-the-token' });

  assert.ok([401, 403].includes(missing.status), `missing token answered ${missing.status}`);
  assert.ok([401, 403].includes(wrong.status), `wrong token answered ${wrong.status}`);
  await sleep(1000);
  assert.equal(count('alert_deliveries'), 0);
  assert.equal(count('rejected_events'), 0);
  assert.equal(count('incidents'), 0);
});

test('validation: malformed payloads get 400 with a reason and are recorded', async () => {
  const cases = [
    ['malformed-missing-alertname', /alertname is missing/],
    ['malformed-wrong-version', /unsupported webhook payload version/],
    ['malformed-bad-timestamp', /startsAt is not a valid timestamp/],
  ];
  for (const [name, reason] of cases) {
    const res = await post(rawFixture(name)); // raw: fixture() would overwrite the bad startsAt
    assert.equal(res.status, 400, `${name} answered ${res.status}`);
    assert.equal(res.body.status, 'rejected');
    assert.match(res.body.reason, reason);
  }
  const empty = await post({ version: '4', alerts: [] });
  assert.equal(empty.status, 400);
  assert.match(empty.body.reason, /non-empty array/);

  assert.equal(count('rejected_events'), cases.length + 1);
  assert.equal(count('alert_deliveries'), 0, 'a rejected payload must not reach the inbox');
  assert.equal(count('incidents'), 0);
});

test('happy path: one firing alert creates one enriched incident and one notification', async (t) => {
  const body = fixture('firing-paypoint-backend', 3);
  const fingerprint = fingerprintOf(body.alerts[0]);
  const started = Date.now();

  const res = await post(body);
  assert.equal(res.status, 202);
  assert.deepEqual({ status: res.body.status, alerts: res.body.alerts }, { status: 'accepted', alerts: 1 });

  const row = await waitFor('notification sent', () => incident(fingerprint)?.notify_status === 'sent' && incident(fingerprint));
  t.diagnostic(`happy path end to end: ${Date.now() - started} ms`);
  assert.equal(row.owner, 'team-payments-api');
  assert.equal(row.runbook, 'runbooks/paypoint-backend.md');
  assert.equal(row.enrichment, 'catalog');
  assert.equal(row.occurrences, 1);

  const state = await notifier('/state');
  assert.equal(state.attempts[fingerprint], 1);
  assert.equal(state.delivered.filter((d) => d.key === fingerprint).length, 1);
});

test('deduplication: repeated and concurrent deliveries keep one incident and one notification', async () => {
  const body = fixture('firing-paypoint-backend', 3); // same episode as the happy path
  const fingerprint = fingerprintOf(body.alerts[0]);

  for (let i = 0; i < 3; i += 1) assert.equal((await post(body)).status, 202);
  const concurrent = await Promise.all(Array.from({ length: 5 }, () => post(body)));
  assert.deepEqual(concurrent.map((r) => r.status), [202, 202, 202, 202, 202]);

  await waitFor('9 occurrences', () => incident(fingerprint)?.occurrences === 9);
  assert.equal(count('incidents', `fingerprint = ${quote(fingerprint)}`), 1);
  const state = await notifier('/state');
  assert.equal(state.attempts[fingerprint], 1, 'duplicates must not call the notifier again');
});

test('enrichment: an unknown service falls back to the default owner, runbook and policy', async () => {
  const body = fixture('firing-unknown-service', 4);
  const fingerprint = fingerprintOf(body.alerts[0]);
  assert.equal((await post(body)).status, 202);

  const row = await waitFor('default enrichment', () => incident(fingerprint)?.notify_status === 'sent' && incident(fingerprint));
  assert.equal(row.service, 'billing-worker');
  assert.equal(row.owner, 'platform-oncall');
  assert.equal(row.runbook, 'runbooks/unknown-service.md');
  assert.equal(row.enrichment, 'default');
});

test('paging policy: a warning for a service that pages only on critical is stored but not sent', async () => {
  const body = fixture('warning-paypoint-frontend', 5);
  const fingerprint = fingerprintOf(body.alerts[0]);
  assert.equal((await post(body)).status, 202);

  const row = await waitFor('incident stored', () => incident(fingerprint));
  assert.equal(row.owner, 'team-web');
  assert.equal(row.notify_status, 'skipped');
  await sleep(1000);
  assert.equal((await notifier('/state')).attempts[fingerprint], undefined);
});

test('batch: one delivery with two alerts creates two incidents linked to one inbox row', async () => {
  const body = fixture('batch-two-alerts', 6);
  const res = await post(body);
  assert.equal(res.status, 202);
  assert.equal(res.body.alerts, 2);

  const fingerprints = body.alerts.map(fingerprintOf);
  await waitFor('two incidents', () => fingerprints.every((f) => incident(f)));
  assert.equal(count('alert_deliveries', `id = ${Number(res.body.deliveryId)} AND alert_count = 2`), 1);
});

test('resolution: a resolved alert closes the incident without counting a new occurrence', async () => {
  const firing = fixture('firing-paypoint-backend', 3);
  const resolved = fixture('resolved-paypoint-backend', 3);
  const fingerprint = fingerprintOf(firing.alerts[0]);
  assert.equal((await post(resolved)).status, 202);

  const row = await waitFor('resolved status', () => incident(fingerprint)?.status === 'resolved' && incident(fingerprint));
  assert.equal(row.occurrences, 9);
  assert.ok(row.resolved_at);
});

test('retry: a notifier that fails twice is retried and the incident is notified once', async (t) => {
  await notifier('/mode', { kind: 'fail-then-ok', failures: 2 });
  const body = fixture('firing-unknown-service', 7);
  const fingerprint = fingerprintOf(body.alerts[0]);
  const started = Date.now();
  assert.equal((await post(body)).status, 202);

  await waitFor('notification sent after retries', () => incident(fingerprint)?.notify_status === 'sent');
  t.diagnostic(`retry path: ${Date.now() - started} ms`);
  const state = await notifier('/state');
  assert.equal(state.attempts[fingerprint], 3);
  assert.equal(state.delivered.filter((d) => d.key === fingerprint).length, 1);
  assert.equal(count('dead_letters'), 0);
  await notifier('/mode', { kind: 'ok' });
});

test('permanent failure: the notification is dead-lettered after a bounded number of attempts', async () => {
  await notifier('/mode', { kind: 'always-fail' });
  const body = fixture('firing-unknown-service', 8);
  const fingerprint = fingerprintOf(body.alerts[0]);
  assert.equal((await post(body)).status, 202);

  const letter = await waitFor('notify dead letter', () => rows(
    `SELECT d.* FROM dead_letters d JOIN incidents i ON i.id = d.incident_id WHERE i.fingerprint = ${quote(fingerprint)}`,
  )[0]);
  assert.equal(letter.stage, 'notify');
  assert.ok(letter.delivery_id, 'the dead letter must point at the stored payload');
  assert.match(letter.error, /503|unavailable|outage/i);
  assert.equal(incident(fingerprint).notify_status, 'failed');

  await sleep(3000); // longer than the retry window: no further attempts may appear
  assert.equal((await notifier('/state')).attempts[fingerprint], MAX_NOTIFY_ATTEMPTS);
});

test('replay: re-sending a dead letter after recovery notifies exactly once, and a second replay is a no-op', async () => {
  await notifier('/mode', { kind: 'ok' });
  const fingerprint = fingerprintOf(fixture('firing-unknown-service', 8).alerts[0]);

  const output = runReplay();
  assert.match(output, /re-sent \(HTTP 202\)/);
  await waitFor('notification sent after replay', () => incident(fingerprint)?.notify_status === 'sent');
  assert.match(runReplay(), /No open dead letters/);
  await sleep(1000);

  const state = await notifier('/state');
  assert.equal(state.delivered.filter((d) => d.key === fingerprint).length, 1);
  assert.equal(count('dead_letters', 'replayed_at IS NULL'), 0);
});

test('workflow failure: a lock timeout reaches the error workflow and the payload can be replayed', async () => {
  const body = fixture('firing-paypoint-backend', 9);
  const fingerprint = fingerprintOf(body.alerts[0]);
  assert.equal((await post(body)).status, 202);
  await waitFor('incident created', () => incident(fingerprint)?.notify_status === 'sent');

  // A long transaction holds the incident row for longer than incident_writer's 2 s lock_timeout.
  const holder = spawn('docker', ['compose', 'exec', '-T', '-e', 'PGAPPNAME=lab-lock-holder', 'postgres',
    'psql', '-U', 'postgres', '-d', 'incidents', '-c',
    `BEGIN; SELECT id FROM incidents WHERE fingerprint = ${quote(fingerprint)} FOR UPDATE; SELECT pg_sleep(6); COMMIT;`],
  { cwd: ROOT, stdio: 'ignore' });
  const released = new Promise((resolve) => holder.on('exit', resolve));
  await waitFor('row lock held', () => count('pg_stat_activity', "application_name = 'lab-lock-holder' AND state = 'active'") > 0);

  const res = await post(body);
  assert.equal(res.status, 202, 'the delivery is stored and acknowledged before the incident write');

  const letter = await waitFor('workflow dead letter', () => rows("SELECT * FROM dead_letters WHERE stage = 'workflow'")[0]);
  assert.equal(Number(letter.delivery_id), Number(res.body.deliveryId));
  assert.match(letter.error, /Upsert incident: .*lock timeout/);
  assert.equal(incident(fingerprint).occurrences, 1, 'the failed delivery left no partial write');

  await released;
  assert.match(runReplay(), /re-sent \(HTTP 202\)/);
  await waitFor('occurrence counted by replay', () => incident(fingerprint)?.occurrences === 2);
  assert.equal((await notifier('/state')).attempts[fingerprint], 1, 'replaying a duplicate must not page again');
});

test('Alertmanager path: an alert posted to Alertmanager reaches n8n with the bearer token', async () => {
  const startsAt = new Date().toISOString();
  const res = await fetch(`${ALERTMANAGER}/api/v2/alerts`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify([{
      labels: { alertname: 'LabAlertmanagerPath', namespace: 'paypoint', service: 'paypoint-backend', severity: 'critical', run: String(RUN) },
      annotations: { summary: 'Synthetic alert sent through Alertmanager by the test suite' },
      startsAt,
    }]),
  });
  assert.equal(res.status, 200);

  const row = await waitFor('incident from Alertmanager', () => rows(
    "SELECT * FROM incidents WHERE alertname = 'LabAlertmanagerPath'",
  )[0], { timeoutMs: 30_000 });
  assert.equal(row.owner, 'team-payments-api');
  assert.equal(count('alert_deliveries', "receiver = 'n8n-incidents' AND payload->'commonLabels'->>'alertname' = 'LabAlertmanagerPath'"), 1);
});

test('metrics: n8n exposes execution outcomes to Prometheus', async () => {
  const res = await fetch(`${N8N}/metrics`);
  assert.equal(res.status, 200);
  const text = await res.text();
  // Runs before the restart test: these counters live in the n8n process and reset when it restarts.
  assert.match(text, /^n8n_workflow_execution_duration_seconds_count\{status="success",mode="webhook"\} [1-9]/m);
  assert.match(text, /^n8n_workflow_execution_duration_seconds_count\{status="failed",mode="webhook"\} [1-9]/m);
  // The error workflow itself runs in mode "error" and must succeed.
  assert.match(text, /^n8n_workflow_execution_duration_seconds_count\{status="success",mode="error"\} [1-9]/m);
});

test('restart: deduplication still holds after restarting PostgreSQL and n8n', async () => {
  const body = fixture('firing-paypoint-backend', 3);
  const fingerprint = fingerprintOf(body.alerts[0]);
  const before = incident(fingerprint);

  execFileSync('docker', ['compose', 'restart', 'postgres'], { cwd: ROOT, stdio: 'ignore' });
  execFileSync('docker', ['compose', 'restart', 'n8n'], { cwd: ROOT, stdio: 'ignore' });
  await waitForN8n();

  const res = await waitFor('webhook accepting again', async () => {
    const r = await post(body).catch(() => null);
    return r?.status === 202 && r;
  }, { timeoutMs: 60_000, intervalMs: 1000 });
  assert.equal(res.status, 202);
  await waitFor('occurrence counted after restart', () => incident(fingerprint)?.occurrences === before.occurrences + 1);
  assert.equal(count('incidents', `fingerprint = ${quote(fingerprint)}`), 1);
  assert.equal((await notifier('/state')).attempts[fingerprint], 1, 'no second page after a restart');
});
