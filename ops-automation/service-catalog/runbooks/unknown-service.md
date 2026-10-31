# Runbook: service not in the catalog

The alert came from a service that `service-catalog/services.json` does not list, so it was routed to the default owner (`platform-oncall`) and pages only on `critical`.

1. Find who owns the workload: `kubectl get pods -A -l app=<service> -o wide` and the repository that deploys it.
2. Handle the alert with that team.
3. Add the service to `service-catalog/services.json` with its owner, runbook and paging policy, and open a pull request. The catalog reloads on the next `make up`.
