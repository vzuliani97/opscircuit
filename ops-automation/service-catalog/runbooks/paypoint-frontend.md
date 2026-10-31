# Runbook: paypoint-frontend

Synthetic team and owner names; the steps match the local OpsCircuit cluster.

1. `kubectl -n paypoint get pods -l app=frontend` — both replicas should be Ready.
2. If nginx fails to start, read `kubectl -n paypoint logs <pod>`: the config fails fast on an unknown upstream (see `docs/incidents/nginx-fail-fast.log`).
3. If the backend is the cause, follow `runbooks/paypoint-backend.md` instead.
4. Roll back with `kubectl -n paypoint rollout undo deployment/frontend`.
