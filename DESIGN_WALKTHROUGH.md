# OpsCircuit design walkthrough

## 90-second demo

1. **(15 s)** "This is how I'd run PayPoint in production: Kubernetes, GitOps, monitoring, and the AWS version in Terraform, all reproducible on a laptop for free."
2. **(25 s)** `make up` output → app at :8082 → the Grafana dashboard with live sales, latency and errors.
3. **(30 s)** The postmortem: "I broke it on purpose. A total outage fired **no** alert, because `up == 0` can't fire once Prometheus has no targets left. I added an `absent()` alert and re-ran the drill: pending at 41 s, firing at 2 min. nginx also hung for 60 s; now it returns 504 in 3 s."
4. **(20 s)** The bad-deploy drill: the broken release never got traffic (readiness + `maxUnavailable: 0`), and the rollback took one command.

## Hard questions

**1. Why didn't your original alert fire during the outage?**
Targets come from pod discovery. With zero pods there are no targets and no `up` series, and an expression over an empty set never fires. `absent(up{job="paypoint-backend"} == 1)` fires when no healthy target exists. I only found this by testing the alert, which is the lesson.

**2. A deploy breaks the app. What protects users?**
The readiness probe keeps the new pod out of the Service; `maxUnavailable: 0` keeps the old pods until the new ones are ready; the PDB protects against voluntary disruptions. In the drill, health stayed 200 the whole time and the rollout simply stalled.

**3. And how do you roll back in GitOps?**
With `git revert`. A `kubectl rollout undo` would be reverted by Argo CD self-heal back to the broken commit, because git is the source of truth.

**4. Readiness vs liveness vs startup probes?**
Readiness decides whether the pod gets traffic. Liveness decides whether to restart it. Startup protects slow starts, here migrations, from liveness kills. Mixing them up causes restart loops or traffic to unready pods.

**5. Why no CPU limits?**
CPU limits cause CFS throttling and latency spikes even when the node is idle. I set CPU requests for scheduling and memory limits to contain leaks. It is a documented, deliberate Checkov exception.

**6. How do you know the NetworkPolicies work?**
I tested both directions: a pod without the `app=backend` label gets "no response" from PostgreSQL, and one with it gets "accepting connections". A policy you haven't tested negatively is a guess.

**7. Running PostgreSQL in Kubernetes: would you do it in production?**
For this lab it is a StatefulSet. For production I'd use RDS, which is why the Terraform provisions RDS with TLS enforced, IAM auth, backups and Performance Insights.

**8. How do secrets work here and what would you change?**
Locally, a kustomize `secretGenerator` reads a git-ignored file, and the hash suffix rolls the pods when a secret changes. In GitOps the Secret is created out of band. Next step: External Secrets Operator reading AWS Secrets Manager.

**9. How would GitHub Actions deploy to AWS without long-lived keys?**
With OIDC federation: the workflow gets a short-lived token, and AWS IAM trusts GitHub's identity provider for a role scoped to the repo and branch.

**10. What did Checkov find, and what did you not fix?**
It found RDS without TLS, IAM auth or logs, ECR without KMS, and unpinned AZs and modules, and I fixed those. I accepted, and documented in `.checkov.yaml`: CPU limits (deliberate), secrets as environment variables (twelve-factor), and app images on a moving tag (the next step is an image updater).
