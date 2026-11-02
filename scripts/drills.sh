#!/usr/bin/env bash
# Reproducible incident drills against the local cluster (run `make up` first).
#   ./scripts/drills.sh outage       backend goes down completely; does an alert fire?
#   ./scripts/drills.sh bad-deploy   a broken release is rolled out; is traffic protected, and does rollback work?
#   ./scripts/drills.sh unsigned-image   an image CI did not sign is submitted; does admission refuse it? (`make policies` first)
set -euo pipefail

KUBECTL="kubectl --context kind-opscircuit -n paypoint"
WEB="${WEB_URL:-http://localhost:8082}"
PROMETHEUS="${PROMETHEUS_URL:-http://localhost:9090}"

log() { printf '%s  %s\n' "$(date -u +%H:%M:%S)" "$*"; }
health() { curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$WEB/health" || true; }
firing_alerts() {
  # shellcheck disable=SC2016 # ${...} below is a JavaScript template literal, not shell expansion
  curl -s "$PROMETHEUS/api/v1/alerts" | node -e '
    const alerts = JSON.parse(require("fs").readFileSync(0, "utf8")).data.alerts;
    const active = alerts.filter((a) => a.state === "firing" || a.state === "pending");
    console.log(active.map((a) => `${a.labels.alertname}(${a.state})`).join(", ") || "none");'
}

outage() {
  log "START outage drill. Health: $(health). Alerts: $(firing_alerts)"
  log "Inject: scale backend to 0 replicas"
  $KUBECTL scale deployment/backend --replicas=0 >/dev/null
  $KUBECTL wait --for=delete pod -l app=backend --timeout=60s >/dev/null 2>&1 || true
  for _ in $(seq 1 12); do
    log "Health: $(health). Alerts: $(firing_alerts)"
    sleep 15
  done
  log "Recover: scale backend back to 2 replicas"
  $KUBECTL scale deployment/backend --replicas=2 >/dev/null
  $KUBECTL rollout status deployment/backend --timeout=180s >/dev/null
  log "Recovered. Health: $(health)"
  sleep 30
  log "END. Alerts: $(firing_alerts)"
}

bad_deploy() {
  local revision
  revision="$($KUBECTL get deployment/backend -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}')"
  log "START bad-deploy drill. Current revision: $revision. Health: $(health)"
  log "Inject: release with a broken DATABASE_URL"
  $KUBECTL set env deployment/backend DATABASE_URL=postgres://paypoint:wrong@postgres-typo:5432/paypoint >/dev/null
  for _ in $(seq 1 8); do
    log "Health: $(health). Pods: $($KUBECTL get pods -l app=backend --no-headers | awk '{print $2"/"$3}' | tr '\n' ' ')"
    sleep 10
  done
  log "Rollout status: $($KUBECTL rollout status deployment/backend --timeout=5s 2>&1 | tail -1)"
  log "Recover: kubectl rollout undo"
  $KUBECTL rollout undo deployment/backend >/dev/null
  $KUBECTL rollout status deployment/backend --timeout=180s >/dev/null
  log "END. Revision: $($KUBECTL get deployment/backend -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}'). Health: $(health). Pods: $($KUBECTL get pods -l app=backend --no-headers | awk '{print $2"/"$3}' | tr '\n' ' ')"
}

unsigned_image() {
  # Server-side dry run: the request goes through admission (Kyverno included) but nothing is created.
  # The default namespace is outside the workload policies, so only the signature check applies.
  local image out
  log "START unsigned-image drill"
  for image in \
    ghcr.io/vzuliani97/paypoint-backend:2dfad07d6962b1b28c7d776b522363bf37cc4e48 \
    ghcr.io/vzuliani97/paypoint-backend:main; do
    if out="$(kubectl --context kind-opscircuit -n default run supply-chain-drill --image="$image" --restart=Never \
      --dry-run=server -o jsonpath='{.spec.containers[0].image}' 2>&1)"; then
      log "ADMITTED $image, pinned to $out"
    else
      log "DENIED $image: $out"
    fi
  done
  log "END"
}

case "${1:-}" in
  outage) outage ;;
  bad-deploy) bad_deploy ;;
  unsigned-image) unsigned_image ;;
  *) echo "usage: $0 outage|bad-deploy|unsigned-image" >&2; exit 1 ;;
esac
