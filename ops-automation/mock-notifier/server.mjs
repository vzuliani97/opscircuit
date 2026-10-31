// Stand-in for an on-call notifier (Slack, PagerDuty, a ticket system). Tests switch its failure mode
// to drive the workflow's retry, dead-letter and replay paths. Nothing here leaves the machine.
import { createServer } from 'node:http';

const PORT = 8099;
const MODES = ['ok', 'fail-then-ok', 'always-fail'];
let mode = { kind: 'ok', failures: 0 };
const attempts = new Map(); // idempotency key -> number of POST /notify calls
const delivered = new Map(); // idempotency key -> the first notification accepted for it

function log(event, fields) {
  console.log(JSON.stringify({ time: new Date().toISOString(), event, ...fields }));
}

function send(res, status, payload) {
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(JSON.stringify(payload));
}

async function readJson(req) {
  let body = '';
  for await (const chunk of req) {
    body += chunk;
    if (body.length > 64 * 1024) throw new Error('body too large');
  }
  return body ? JSON.parse(body) : {};
}

async function notify(req, res) {
  const key = req.headers['idempotency-key'];
  if (!key) return send(res, 400, { error: { code: 'MISSING_IDEMPOTENCY_KEY', message: 'Idempotency-Key header is required' } });
  const body = await readJson(req);
  const attempt = (attempts.get(key) ?? 0) + 1;
  attempts.set(key, attempt);

  const fail = mode.kind === 'always-fail' || (mode.kind === 'fail-then-ok' && attempt <= mode.failures);
  if (fail) {
    log('notify_failed', { key, attempt, mode: mode.kind });
    return send(res, 503, { error: { code: 'UNAVAILABLE', message: 'simulated notifier outage' } });
  }
  // A replay or a concurrent retry with the same key must not page twice.
  if (delivered.has(key)) {
    log('notify_duplicate', { key, attempt });
    return send(res, 200, { status: 'duplicate' });
  }
  delivered.set(key, { key, receivedAt: new Date().toISOString(), body });
  log('notify_delivered', { key, attempt });
  return send(res, 200, { status: 'delivered' });
}

createServer(async (req, res) => {
  try {
    if (req.method === 'GET' && req.url === '/health') return send(res, 200, { status: 'ok' });
    if (req.method === 'POST' && req.url === '/notify') return await notify(req, res);
    if (req.method === 'GET' && req.url === '/state') {
      return send(res, 200, { mode, attempts: Object.fromEntries(attempts), delivered: [...delivered.values()] });
    }
    if (req.method === 'POST' && req.url === '/mode') {
      const next = await readJson(req);
      if (!MODES.includes(next.kind)) {
        return send(res, 400, { error: { code: 'INVALID_MODE', message: `kind must be one of ${MODES.join(', ')}` } });
      }
      mode = { kind: next.kind, failures: Number.isInteger(next.failures) ? next.failures : 0 };
      log('mode_changed', mode);
      return send(res, 200, mode);
    }
    if (req.method === 'POST' && req.url === '/reset') {
      mode = { kind: 'ok', failures: 0 };
      attempts.clear();
      delivered.clear();
      return send(res, 200, { status: 'reset' });
    }
    return send(res, 404, { error: { code: 'NOT_FOUND', message: 'unknown route' } });
  } catch (err) {
    return send(res, 400, { error: { code: 'BAD_REQUEST', message: err.message } });
  }
}).listen(PORT, () => log('listening', { port: PORT }));
