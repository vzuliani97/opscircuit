# OpsCircuit — Cloud Delivery & Incident Automation Lab

*Formerly PlatformOps.*

[![CI](https://github.com/vzuliani97/opscircuit/actions/workflows/ci.yml/badge.svg)](https://github.com/vzuliani97/opscircuit/actions/workflows/ci.yml)

A local-first platform engineering and incident-operations lab. It delivers and operates PayPoint, the sample transactional service from [AtomicTrail](https://github.com/vzuliani97/atomictrail): Kubernetes manifests with Kustomize, GitOps with Argo CD, Prometheus and Grafana with alerts, hardened workloads, game-day drills with a postmortem, and the AWS production equivalent in Terraform. Everything runs locally at zero cost on a 3-node kind cluster.

**Problem:** applications go down, get misconfigured or receive broken releases. The team has to notice fast, protect users, and recover with one command.

![Grafana dashboard provisioned as code: pods, sales by status, request rate, p95 latency, error ratio, memory](docs/screenshots/grafana-dashboard.png)

## What is verified (on the local cluster)

| Check | Result | Evidence |
|---|---|---|
| End-to-end smoke test: web, health, login, a confirmed sale, metrics | Pass | `make smoke` |
| Signed partner sale through nginx inside the cluster | 201 | `scripts/` + PayPoint partner client |
| Prometheus scrapes both backend replicas, on different nodes | 2/2 up | `docs/screenshots/prometheus-targets.png` |
| NetworkPolicy: an unlabeled pod tries to reach PostgreSQL | `no response` (blocked) | Negative and positive probe |
| Game day: total backend outage | Found an alert that could never fire; fixed and re-verified | [Postmortem](docs/incidents/2026-10-30-postmortem.md) |
| Game day: broken release | Health 200 throughout; rollout stalled; rollback in one command | `docs/incidents/drill-bad-deploy.log` |
| Checkov on Terraform + rendered manifests | 0 failed checks (33 Terraform, 438 Kubernetes), with accepted findings documented. A clean static scan is not proof of no risk | `.checkov.yaml` |
| Schema validation of every rendered manifest | 39/39 valid | `make validate` |
| `terraform validate` and `fmt` | Pass | `make tf-validate` |
| **GitOps from GitHub**: Argo CD syncs `main`, pulls multi-arch images from GHCR | Synced/Healthy; smoke test passes | Revision on the cluster equals `main` |
| **Self-heal**: Deployment deleted by hand | Recreated by Argo CD in 2 s | Drill 2026-10-30 |
| CI on GitHub (validate, Terraform, Checkov, Gitleaks, shellcheck) | Green | Actions tab |
| **n8n incident automation lab**: authenticated Alertmanager webhook, validation, deduplication, enrichment, bounded retry, dead letters, replay, restart | 15/15 integration tests, locally and in CI | [Verification](docs/INCIDENT_AUTOMATION_VERIFICATION.md) |
| **Terraform applied on AWS** | **Never applied** (it would cost money) | — |

## Architecture

```mermaid
flowchart LR
  subgraph kind["kind cluster: 1 control plane + 2 workers"]
    subgraph paypoint["namespace paypoint"]
      FE[frontend x2<br/>non-root nginx] --> BE[backend x2<br/>NestJS]
      BE --> PG[(postgres<br/>StatefulSet + PVC)]
    end
    subgraph monitoring["namespace monitoring"]
      PR[Prometheus] -->|pod discovery| BE
      GR[Grafana] --> PR
    end
    AC[Argo CD]
  end
  U[Browser :8082] --> FE
  GH[(GitHub)] --> AC -->|sync| paypoint
  REG[(GHCR images)] --> paypoint
```

## Incident automation (n8n)

[`ops-automation/`](ops-automation) adds a self-hosted n8n workflow between Alertmanager and on-call.
- **Alertmanager** groups alerts.
- **n8n:**
  - authenticates and validates each delivery;
  - stores it before answering 202;
  - keeps one incident per firing episode;
  - adds owner and runbook from a catalog in git;
  - pages through a retrying notifier and dead-letters what still fails, for a safe replay.

It runs in Docker Compose with a mock notifier, and its 15 integration tests run in CI. Read more in the [architecture](docs/INCIDENT_AUTOMATION_ARCHITECTURE.md), [runbook](docs/INCIDENT_AUTOMATION_RUNBOOK.md) and [verification](docs/INCIDENT_AUTOMATION_VERIFICATION.md).

![n8n execution stopped by a database lock timeout; the error workflow records a replayable dead letter](docs/screenshots/n8n-execution-lock-timeout.png)

GitOps flow: a push to PayPoint runs its tests and publishes images to GHCR; Argo CD keeps the cluster in sync with `k8s/overlays/gitops` on `main` (`prune` + `selfHeal`). Nobody applies changes with `kubectl` in GitOps mode.

## Quick start

Requirements: Docker, kubectl, and the `atomictrail` repo cloned next to this one (`PAYPOINT_DIR` in the Makefile). `make tools` downloads pinned `kind` and `kubeconform` into `./bin` and verifies their SHA-256; nothing is installed system-wide.

```bash
make up              # cluster + PayPoint + Prometheus/Grafana + smoke test (~5 min)
make drill-outage    # game day: total outage
make drill-bad-deploy
make down
```

| Service | URL |
|---|---|
| PayPoint | http://localhost:8082 |
| Grafana (read-only anonymous) | http://localhost:3030 |
| Prometheus | http://localhost:9090 |

## Reliability

- 2 replicas spread across nodes (`topologySpreadConstraints`), a `PodDisruptionBudget`, and rolling updates with `maxUnavailable: 0`.
- Separate startup, readiness and liveness probes, so startup migrations never trigger restarts.
- Migrations run at startup under a PostgreSQL advisory lock, so only one replica applies them.
- **Alerts:** backend absent (total outage), backend down, more than 5% 5xx, p95 above 1 s, and sales stuck `PENDING` (provider not answering).

## Security

- Every workload runs as non-root, with read-only root filesystems, no privilege escalation, all capabilities dropped and seccomp `RuntimeDefault`. PostgreSQL runs as uid 70 with its writable paths on `emptyDir`.
- Pod Security Admission: `baseline` enforced in `paypoint`, `restricted` enforced in `monitoring`.
- Default-deny NetworkPolicies: PostgreSQL accepts only the backend; the backend accepts only the frontend and Prometheus. Verified with a blocked probe and an allowed one.
- Third-party images are pinned by digest. Secrets stay out of git: the local overlay generates them from an ignored file, and GitOps creates them out of band.
- Prometheus has a read-only ClusterRole on pods only.
- CI: Checkov, Gitleaks over the full history, kubeconform, `terraform validate`, shellcheck, SHA-pinned actions and a least-privilege token.

## Terraform (AWS production equivalent, never applied)

- VPC across 3 explicit AZs with private, public and isolated database subnets.
- EKS (official module v21): spot nodes in dev, on-demand in production, and the API endpoint restricted to allowed CIDRs (`0.0.0.0/0` is rejected by validation).
- RDS PostgreSQL 16: private, encrypted, **TLS enforced**, IAM authentication, password generated into Secrets Manager, slow-query and DDL logging, Performance Insights, backups.
- ECR: immutable tags, scan on push, KMS encryption, lifecycle policy.
- `environment = "production"` turns on Multi-AZ, deletion protection, a final snapshot and one NAT per AZ.

Estimated cost of the demo environment in us-east-1: about **USD 140/month** (EKS control plane about 73, NAT about 33, 2 spot t3.medium about 20, RDS about 15). These are reference prices; check them with the AWS calculator.

## Known limitations and next steps

- The cluster's Prometheus does not route to Alertmanager yet. The n8n incident lab runs in Docker Compose next to the cluster; wiring the two together is the next step, together with a blackbox check of the public URL (open action items in the postmortem).
- The app images use the moving `main` tag in GitOps. Next: Argo CD Image Updater, or a commit that pins the SHA.
- Secrets are not managed by External Secrets or Sealed Secrets yet.
- No Ingress or Gateway API with TLS, no HPA, no centralized logs (Loki).

## Design walkthrough

[DESIGN_WALKTHROUGH.md](DESIGN_WALKTHROUGH.md): a 90-second demo script and the hard questions this design invites, with answers that point to code and evidence.

## License and provenance

MIT.

Independent portfolio reconstruction based on engineering patterns from professional work. It uses synthetic data and contains no employer code or confidential information. AI-assisted development tools were used; the implementation was reviewed and verified through tests and CI.
