# Postmortem: total backend outage went unalerted (game day, 2026-10-30)

Blameless format. This was a planned drill on the local kind cluster, run with `scripts/drills.sh`. The raw logs are in this folder.

## Summary

We scaled the PayPoint backend to zero to simulate a total outage. **The API was down for 3.5 minutes and no alert fired.** A second problem made it worse for users: requests hung instead of failing fast. Both were fixed and the fix was verified by repeating the drill. A separate drill confirmed that a broken release is contained by Kubernetes without user impact, and rolled back.

## Impact (simulated)

| | Before the fix | After the fix |
|---|---|---|
| Time to alert on a total outage | **Never** (3.5 min observed, no alert) | Pending at +41 s, firing at about +2 min, auto-resolved after recovery |
| User experience while the backend is down | Request hangs (no response within 3 s; nginx waits up to 60 s by default) | **HTTP 504 in 3.0 s** |

## Timeline (UTC)

| Time | Event |
|---|---|
| 01:10:03 | Drill 1 starts. Backend scaled to 0. |
| 01:10:25 | `PayPointBackendDown` briefly **pending**, then disappears |
| 01:10:43 – 01:13:27 | API down, **no active alerts** |
| 01:13:42 | Backend scaled back to 2; recovered at 01:13:47 |
| 01:16:16 | Drill 1 repeated with the fix. Backend scaled to 0. |
| 01:16:57 | `PayPointBackendAbsent` **pending** |
| 01:18:10 | `PayPointBackendAbsent` **firing** |
| 01:20:00 | Recovered; alert resolved by 01:20:31 |
| 01:21:08 | Drill 2: release with a broken `DATABASE_URL` |
| 01:21:08 – 01:22:20 | New pod in `CrashLoopBackOff`; **health stayed 200 the whole time** |
| 01:22:35 | Rollout timed out; `kubectl rollout undo`; back on the previous release |

## Root causes

1. **The alert could not see a total outage.** `PayPointBackendDown` fires on `up == 0`. Prometheus discovers backend pods dynamically, so when every pod is gone there is no target left. The `up` series stops existing, and an alert on a missing series never fires. It only worked for a single unhealthy pod that still existed.
2. **No fail-fast timeout at the proxy.** nginx waits 60 s by default to connect to an upstream. With no backend endpoints, clients hung instead of getting an error they could retry or show.

## What went well

- The broken release in drill 2 never received traffic. The readiness probe kept the pod out of the Service, `maxUnavailable: 0` kept both healthy pods running, and the rollout stalled instead of progressing.
- Recovery in both drills took one command and under a minute.

## Action items

| Action | Status | Evidence |
|---|---|---|
| Add `PayPointBackendAbsent: absent(up{job="paypoint-backend"} == 1)` | **Done, verified** | `observability/alerts.yml`; `drill-outage-after-fix.log` |
| `proxy_connect_timeout 3s` / `proxy_read_timeout 30s` in the PayPoint nginx | **Done, verified** | PayPoint `frontend/nginx.conf`; `nginx-fail-fast.log` (504 in 3.0 s) |
| Route alerts somewhere a human sees them (Alertmanager to chat/email) | Open | Today alerts are only visible in Prometheus |
| Blackbox or synthetic check of the public URL, independent of pod discovery | Open | Would also catch DNS, ingress and nginx failures |
| In GitOps mode, roll back with `git revert`, not `kubectl rollout undo` | Documented | Argo CD self-heal would otherwise revert a manual undo back to the broken commit |

## Lessons

- Test alerts by breaking things on purpose. A config can look right and still be unable to fire.
- Alert on the **absence** of healthy targets, not only on unhealthy ones.
- Set explicit timeouts at every hop; defaults are tuned for compatibility, not for a good user experience.
