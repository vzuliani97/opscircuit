# Incident automation lab: verification

**Recorded on 2026-10-31.**
- **Machine:** macOS on Apple silicon, Docker Engine 29.7 and Compose v5.5, Node.js 24.20.
- **Images:** pinned by digest in `ops-automation/docker-compose.yml`: n8n 2.43.7, Alertmanager v0.34.1, PostgreSQL 18.4, Node.js 24.22.
- **Not a benchmark.** Timings are from this local machine. They show that retries wait as configured, not how fast the system is.

The same suite runs in GitHub Actions (job `n8n incident lab`) on every push. The CI run is the reproducibility check on a clean machine.

## Integration tests

Command: `make clean && make up && make test`.
- **Result:** 15 tests, 15 passed, 0 failed, 27.1 s in total.
- **Startup:** `make up` took 17 s from empty volumes with the images already pulled.
- **Before the final run:** the suite also passed twice in a row on the same data, and once more from empty volumes.

| Test | What it asserts | Time |
|---|---|---|
| authentication | Missing token and wrong token both answer 403; no delivery, rejection or incident is stored | 1.5 s (includes a 1 s settle wait) |
| validation | Missing `alertname`, version 3, invalid `startsAt` and an empty alert list answer 400 with the reason; 4 rows in `rejected_events`; nothing reaches the inbox | 0.6 s |
| happy path | 202; incident owned by `team-payments-api` with the catalog runbook; 1 notifier attempt, 1 notification; fingerprint equals the sha256 the test computes itself | 239 ms (end to end, 235 ms) |
| deduplication | 3 sequential plus 5 concurrent deliveries of the same alert: 1 incident with 9 occurrences, still 1 notifier attempt | 0.5 s |
| enrichment | Unknown service `billing-worker`: owner `platform-oncall`, runbook `runbooks/unknown-service.md`, `enrichment = default` | 0.2 s |
| paging policy | A warning for `paypoint-frontend` (pages on critical only) is stored as `skipped`; no notifier call | 1.1 s |
| batch | One delivery with 2 alerts: 2 incidents, 1 inbox row with `alert_count = 2` | 0.4 s |
| resolution | A resolved delivery sets `status = resolved` and `resolved_at` without adding an occurrence | 0.2 s |
| retry | Notifier fails twice, then accepts: 3 attempts, 1 notification, 0 dead letters | 2.5 s (two 1 s waits) |
| permanent failure | Notifier always fails: a dead letter with `stage = notify`, the delivery id and the 503; `notify_status = failed`; still exactly 3 attempts after waiting 3 s more | 5.6 s |
| replay | After recovery, `make replay` re-sends the stored payload: 1 notification; a second replay reports nothing to do | 1.7 s |
| workflow failure | Another transaction holds the incident row for 6 s; the upsert fails on the 2 s lock timeout after the 202; the error workflow writes a `workflow` dead letter pointing at the stored delivery; the incident is unchanged; the replay adds the occurrence without a second page | 6.7 s |
| Alertmanager path | An alert posted to Alertmanager's API reaches n8n with the bearer token from Alertmanager's file; the incident and an inbox row from receiver `n8n-incidents` exist | 1.4 s |
| metrics | `/metrics` counts successful and failed webhook executions and successful error-handler executions (`n8n_workflow_execution_duration_seconds_count`) | 12 ms |
| restart | After restarting PostgreSQL and then n8n, the same alert adds one occurrence to the same incident and causes no second page | 4.2 s |

State after the suite (the `incident_outcomes` view): 21 deliveries accepted, 4 rejected, 9 incidents, 11 firing duplicates absorbed, 8 notified, 1 not paged by policy, 0 failed, 0 open dead letters, 2 replayed.

Other observed behavior, not part of the suite: a body that is not valid JSON gets `422 Failed to parse request body` from n8n before the workflow runs.

## Bugs the tests found during development

1. **A failed notification was never retried after a replay.** The first upsert read the previous `notify_status` through a CTE with `SELECT ... FOR UPDATE`. PostgreSQL evaluated that CTE after the same statement had updated the row, so the lock skipped the row and the previous value came back empty. The fix is `RETURNING old/new`, available from PostgreSQL 18. The replay test now covers it.
2. **The error workflow could not record a table-level lock failure.** `ACCESS EXCLUSIVE` on `incidents` also blocks the foreign-key check of the dead-letter insert. The test now holds a row lock, which is the realistic case (a long transaction on one incident).
3. **The metrics label is `status="failed"`, not `"error"`.** The restart also resets n8n's in-process counters, so the metrics test runs before the restart test.

## n8n security audit (`make audit`)

| Finding | Disposition |
|---|---|
| Unused "Query Parameters" in 7 SQL nodes | **False positive, checked in the source.** The rule in `security-audit/risk-reporters/database-risk-reporter.js` only looks for `parameters.additionalFields.queryParams`, the Postgres v1 layout. All 7 nodes are Postgres v2.6, where parameters live in `options.queryReplacement`. Every value is passed as a parameter (`$1::text`); no query is built from an expression. |
| Official risky nodes: 3 Code nodes and 1 HTTP Request node | **Accepted.** The Code nodes run fixed, version-controlled JavaScript with environment access blocked (`N8N_BLOCK_ENV_ACCESS_IN_NODE=true`). The HTTP Request node has a fixed internal URL. |
| Outdated instance: 2.43.7, with 2.43.8, 2.44.7 and 2.45.7 available | **Accepted for now.** The pin follows a two-week minimum age for new releases; the audit lists no security fix for those versions. Dependabot now watches the Compose images. |
| Security settings: community packages enabled | **Fixed.** `N8N_COMMUNITY_PACKAGES_ENABLED=false`; the re-run reports `communityPackagesEnabled: false`. Templates, version notifications, diagnostics and the public API are also disabled. |

## Static checks

- `make validate`: Compose config and all workflow, catalog and fixture JSON parse.
- shellcheck on every script in the repository: clean.
- Gitleaks on the working tree flags only git-ignored files: the generated `ops-automation/.env`, the local Kubernetes `secrets.env`, and Terraform's downloaded module examples. `git check-ignore` confirms all three. The CI job scans the full git history.

## Screenshots

These are captured from the local lab after the suite, with headless Chrome:
- `docs/screenshots/n8n-incident-intake.png`: the workflow canvas.
- `n8n-execution-retry.png`: notified after retries.
- `n8n-execution-dead-letter.png`: the error branch.
- `n8n-execution-lock-timeout.png`: stopped at "Upsert incident" with the lock-timeout error.

The local n8n owner account used for the screenshots exists only in that local volume.

## Not verified

- A real paging integration (none is wired).
- Behavior under sustained load.
- A host reboot.
- PostgreSQL being fully unavailable when a delivery arrives. The workflow should fail before the 202 and n8n should answer 500; this is not tested.
