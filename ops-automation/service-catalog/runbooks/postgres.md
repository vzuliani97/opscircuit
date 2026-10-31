# Runbook: postgres

Synthetic team and owner names; the steps match the local OpsCircuit cluster.

1. `kubectl -n paypoint get statefulset postgres` and `kubectl -n paypoint describe pod postgres-0`.
2. Disk: `kubectl -n paypoint exec postgres-0 -- df -h /var/lib/postgresql/data`.
3. Locks: `SELECT pid, wait_event_type, query FROM pg_stat_activity WHERE wait_event_type = 'Lock';`
4. Never delete the PVC during an incident. Restore from backup only with a second person reviewing.
