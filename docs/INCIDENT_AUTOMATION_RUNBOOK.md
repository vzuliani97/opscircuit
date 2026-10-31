# Incident automation lab: runbook

Run every command from `ops-automation/`.

## Start, check, stop

```bash
make up        # generates .env once, starts everything, waits for health checks (bounded)
make test      # 15 integration tests; resets lab data first
make report    # one-row summary from the incident_outcomes view
make down      # stop, keep data
make clean     # stop and delete the PostgreSQL and n8n volumes
```

| Endpoint (localhost only) | Use |
|---|---|
| `http://127.0.0.1:5678` | n8n editor. The first visit asks you to create a local owner account |
| `http://127.0.0.1:5678/metrics` | Prometheus metrics, for example `n8n_workflow_execution_duration_seconds_count{status="failed"}` |
| `http://127.0.0.1:9093` | Alertmanager |
| `http://127.0.0.1:8099/state` | Mock notifier: attempts and delivered notifications |

## Send a test alert

```bash
scripts/send-fixture.sh fixtures/firing-paypoint-backend.json   # 202 and a new incident
scripts/send-fixture.sh fixtures/malformed-missing-alertname.json # 400 with the reason
```

## Telling outcomes apart

| Question | Where to look |
|---|---|
| Was it accepted or rejected? | `alert_deliveries` (accepted) and `rejected_events` (rejected, with the reason) |
| Was it a duplicate? | `incidents.occurrences` greater than 1 for the same fingerprint |
| Was the notification retried? | Mock notifier logs (`docker compose logs mock-notifier`): one line per attempt, with the attempt number |
| Did it fail? | `dead_letters` (`stage = notify` or `workflow`) and the n8n executions list |
| Did it complete? | `incidents.notify_status = 'sent'` (or `skipped` when the policy does not page) |

## Procedures

**Open dead letters**

```bash
docker compose exec postgres psql -U postgres -d incidents \
  -c "SELECT id, stage, delivery_id, incident_id, error, created_at FROM dead_letters WHERE replayed_at IS NULL"
```

Fix the cause first (notifier down, a lock, a bad deploy), then run `make replay`. Replaying is safe to repeat:
- The fingerprint absorbs the duplicate delivery.
- Only a notification that failed is attempted again.
- The notifier receives the same `Idempotency-Key` as before.

**Incidents stuck in `pending`** (n8n stopped between the incident write and the page):

```sql
SELECT id, alertname, service, last_seen FROM incidents
WHERE notify_status = 'pending' AND last_seen < now() - interval '5 minutes';
```

Page the owner by hand. If the same alert is delivered again, it is not paged again, because `pending` is not `failed`. A periodic sweep is planned.

**Rotate the webhook token**
1. Replace `ALERT_WEBHOOK_TOKEN` in `.env` (hex only).
2. Run `make up`. The import container rewrites the n8n credential, and Alertmanager is recreated with the new token file.
3. Senders with the old token get 403.

**Add or change a service**
1. Edit `service-catalog/services.json` (owner, runbook, severities that page) and add the runbook under `service-catalog/runbooks/`.
2. Run `make up`. `db-setup` makes the table match the file.

**Change a workflow**
1. Edit it in the n8n editor and test it.
2. Export it (Download) over `workflows/<name>.json`, keeping the `id`.
3. Run `make up`. Git is the source of truth: every start re-imports and publishes the files, which overwrites editor-only changes.

**Security audit**
- `make audit` prints n8n's report.
- The reviewed findings and their dispositions are in `INCIDENT_AUTOMATION_VERIFICATION.md`.
