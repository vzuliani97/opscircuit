#!/bin/sh
# Sends a fixture to the n8n webhook as Alertmanager would, with startsAt set to now so every run is a
# new firing episode. Usage: scripts/send-fixture.sh fixtures/firing-paypoint-backend.json
set -eu
cd "$(dirname "$0")/.."

fixture=${1:?usage: scripts/send-fixture.sh <fixture.json>}
url=${WEBHOOK_URL:-http://127.0.0.1:5678/webhook/alertmanager}
token=$(sed -n 's/^ALERT_WEBHOOK_TOKEN=//p' .env)
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

jq --arg now "$now" 'if (.alerts | type) == "array" then .alerts |= map(.startsAt = $now) else . end' "$fixture" |
  curl -sS -X POST "$url" \
    -H "Authorization: Bearer $token" \
    -H 'Content-Type: application/json' \
    --data-binary @- \
    -w '\nHTTP %{http_code}\n'
