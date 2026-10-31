#!/bin/sh
# Runs before n8n starts. Git is the source of truth for workflows, so they are re-imported and
# published on every start. The credential file is built from environment variables inside the
# container and deleted on exit; it never exists in the repository.
set -eu
umask 077

creds=$(mktemp)
trap 'rm -f "$creds"' EXIT

cat > "$creds" <<EOF
[
  {
    "id": "alertWebhookAuth",
    "name": "Alertmanager webhook token",
    "type": "httpHeaderAuth",
    "data": { "name": "Authorization", "value": "Bearer ${ALERT_WEBHOOK_TOKEN}" }
  },
  {
    "id": "incidentStoreDb1",
    "name": "Incident store (PostgreSQL)",
    "type": "postgres",
    "data": {
      "host": "postgres", "port": 5432, "database": "incidents",
      "user": "incident_writer", "password": "${INCIDENTS_DB_PASSWORD}",
      "ssl": "disable", "allowUnauthorizedCerts": false, "sshTunnel": false
    }
  }
]
EOF

n8n import:credentials --input="$creds"
n8n import:workflow --separate --input=/workflows
n8n publish:workflow --id=incidentErrors01
n8n publish:workflow --id=incidentIntake01
