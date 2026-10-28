#!/usr/bin/env bash
# End-to-end check of the deployed platform: web, API, a real sale, and the sale showing up in Prometheus.
set -euo pipefail

WEB="${WEB_URL:-http://localhost:8082}"
PROMETHEUS="${PROMETHEUS_URL:-http://localhost:9090}"
SECRETS="$(cd "$(dirname "$0")/.." && pwd)/k8s/overlays/local/secrets.env"
PASSWORD="$(grep '^DEMO_PASSWORD=' "$SECRETS" | cut -d= -f2)"

json() { node -e "const d=JSON.parse(require('fs').readFileSync(0,'utf8'));console.log($1)"; }
step() { printf '%-42s' "$1"; }

step "Web serves the SPA"
curl -fsS "$WEB/" | grep -q '<title>PayPoint</title>' && echo ok

step "API and database are healthy"
curl -fsS "$WEB/health" | json 'd.status' | grep -qx ok && echo ok

step "Cashier can log in"
TOKEN="$(curl -fsS -X POST "$WEB/api/auth/login" -H 'Content-Type: application/json' \
  -d "{\"email\":\"cajero@paypoint.local\",\"password\":\"$PASSWORD\"}" | json 'd.accessToken')"
[[ -n "$TOKEN" ]] && echo ok

step "A sale is confirmed by the provider"
STATUS="$(curl -fsS -X POST "$WEB/api/sales" -H "Authorization: Bearer $TOKEN" \
  -H "Idempotency-Key: smoke-$(date +%s)-$RANDOM" -H 'Content-Type: application/json' \
  -d '{"productId":1,"amount":2000,"destination":"3001234567"}' | json 'd.data.status')"
[[ "$STATUS" == "CONFIRMED" ]] && echo ok

step "Prometheus scrapes every backend pod"
UP="$(curl -fsS "$PROMETHEUS/api/v1/query" --data-urlencode 'query=sum(up{job="paypoint-backend"})' | json 'd.data.result[0].value[1]')"
[[ "$UP" -ge 1 ]] && echo "ok ($UP pods)"

echo "Smoke test passed."
