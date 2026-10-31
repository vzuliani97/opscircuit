# Runbook: paypoint-backend

Synthetic team and owner names; the steps match the local OpsCircuit cluster.

| Alert | First check | Likely cause | Action |
|---|---|---|---|
| `PayPointBackendAbsent` | `kubectl -n paypoint get pods -l app=backend` | Every replica is gone or failing readiness | `kubectl -n paypoint rollout undo deployment/backend` if a release just went out; otherwise read the pod events |
| `PayPointBackendDown` | Prometheus targets page | One replica is failing scrapes | Check `kubectl -n paypoint logs <pod>`; the PodDisruptionBudget keeps the other replica serving |
| `PayPointHighErrorRate` | Grafana error-ratio panel | Database or provider errors | Check PostgreSQL first (`runbooks/postgres.md`), then the provider |
| `PayPointSalesPending` | `SELECT count(*) FROM sales WHERE status = 'PENDING'` | Top-up provider not answering | Money is reserved but not settled: escalate to the provider; do not retry sales by hand |

Rollback is one command and is preferred over a hot fix during an incident. See `docs/incidents/2026-10-30-postmortem.md`.
