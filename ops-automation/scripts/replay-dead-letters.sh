#!/bin/sh
# Re-sends the stored payload of every open dead letter to the webhook. Safe to repeat: the incident
# fingerprint absorbs the duplicate delivery, only a notification that failed is attempted again, and
# the notifier receives the same Idempotency-Key as before.
set -eu
cd "$(dirname "$0")/.."

url=${WEBHOOK_URL:-http://127.0.0.1:5678/webhook/alertmanager}
token=$(sed -n 's/^ALERT_WEBHOOK_TOKEN=//p' .env)
payload=$(mktemp)
trap 'rm -f "$payload"' EXIT

psql() {
  docker compose exec -T postgres psql -U postgres -d incidents -AtX -v ON_ERROR_STOP=1 "$@"
}

rows=$(psql -F ' ' -c "SELECT id, delivery_id FROM dead_letters
                       WHERE replayed_at IS NULL AND delivery_id IS NOT NULL ORDER BY id")
if [ -z "$rows" ]; then
  echo "No open dead letters with a stored payload."
  exit 0
fi

echo "$rows" | while read -r dead_letter delivery; do
  case "$dead_letter$delivery" in *[!0-9]*) echo "unexpected row: $dead_letter $delivery" >&2; exit 1 ;; esac
  psql -c "SELECT payload FROM alert_deliveries WHERE id = $delivery" > "$payload"
  status=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$url" \
    -H "Authorization: Bearer $token" -H 'Content-Type: application/json' --data-binary @"$payload")
  if [ "$status" = 202 ]; then
    psql -c "UPDATE dead_letters SET replayed_at = now() WHERE id = $dead_letter" > /dev/null
    echo "dead letter $dead_letter: delivery $delivery re-sent (HTTP 202)"
  else
    echo "dead letter $dead_letter: replay failed (HTTP $status); left open" >&2
  fi
done
