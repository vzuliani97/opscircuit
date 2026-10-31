#!/bin/sh
# Idempotent database setup, run by the db-setup container on every start: schema and catalog
# changes apply without wiping data.
set -eu

psql -v ON_ERROR_STOP=1 -d postgres \
  -v n8n_password="$N8N_DB_PASSWORD" \
  -v incidents_password="$INCIDENTS_DB_PASSWORD" \
  -f /setup/roles.sql

psql -v ON_ERROR_STOP=1 -d incidents -f /setup/schema.sql

psql -v ON_ERROR_STOP=1 -d incidents \
  -v catalog="$(cat /catalog/services.json)" \
  -f /setup/catalog.sql
