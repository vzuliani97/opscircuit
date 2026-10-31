CREATE TABLE IF NOT EXISTS service_catalog (
  service         text PRIMARY KEY,
  owner           text NOT NULL,
  runbook         text NOT NULL,
  page_severities text[] NOT NULL
);

-- Inbox: every accepted delivery is stored before n8n answers 202, so any later failure can be replayed.
CREATE TABLE IF NOT EXISTS alert_deliveries (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  execution_id text NOT NULL,
  receiver     text NOT NULL,
  group_key    text NOT NULL,
  alert_count  integer NOT NULL CHECK (alert_count > 0),
  payload      jsonb NOT NULL,
  received_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS alert_deliveries_execution_idx ON alert_deliveries (execution_id);

CREATE TABLE IF NOT EXISTS rejected_events (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  reason          text NOT NULL,
  payload_excerpt text NOT NULL,
  received_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS incidents (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  -- sha256 of alert name, namespace, service and startsAt: one incident per firing episode.
  fingerprint   text NOT NULL UNIQUE CHECK (fingerprint ~ '^[0-9a-f]{64}$'),
  alertname     text NOT NULL,
  service       text NOT NULL,
  namespace     text NOT NULL,
  severity      text NOT NULL,
  status        text NOT NULL CHECK (status IN ('firing', 'resolved')),
  summary       text NOT NULL,
  starts_at     timestamptz NOT NULL,
  owner         text NOT NULL,
  runbook       text NOT NULL,
  enrichment    text NOT NULL CHECK (enrichment IN ('catalog', 'default')),
  occurrences   integer NOT NULL DEFAULT 1,
  notify_status text NOT NULL CHECK (notify_status IN ('pending', 'sent', 'failed', 'skipped')),
  notified_at   timestamptz,
  first_seen    timestamptz NOT NULL DEFAULT now(),
  last_seen     timestamptz NOT NULL DEFAULT now(),
  resolved_at   timestamptz
);

CREATE TABLE IF NOT EXISTS dead_letters (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  stage        text NOT NULL CHECK (stage IN ('notify', 'workflow')),
  delivery_id  bigint REFERENCES alert_deliveries (id),
  incident_id  bigint REFERENCES incidents (id),
  execution_id text NOT NULL,
  error        text NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  replayed_at  timestamptz
);

-- One row an operator can read to tell accepted, rejected, deduplicated, notified and failed work apart.
CREATE OR REPLACE VIEW incident_outcomes AS
SELECT
  (SELECT count(*) FROM alert_deliveries)                                       AS deliveries_accepted,
  (SELECT count(*) FROM rejected_events)                                        AS deliveries_rejected,
  (SELECT count(*) FROM incidents)                                              AS incidents,
  (SELECT coalesce(sum(occurrences - 1), 0) FROM incidents)                     AS firing_duplicates_absorbed,
  (SELECT count(*) FROM incidents WHERE notify_status = 'sent')                 AS notified,
  (SELECT count(*) FROM incidents WHERE notify_status = 'skipped')              AS not_paged_by_policy,
  (SELECT count(*) FROM incidents WHERE notify_status = 'failed')               AS notify_failed,
  (SELECT count(*) FROM dead_letters WHERE replayed_at IS NULL)                 AS dead_letters_open,
  (SELECT count(*) FROM dead_letters WHERE replayed_at IS NOT NULL)             AS dead_letters_replayed;

GRANT USAGE ON SCHEMA public TO incident_writer;
GRANT SELECT ON service_catalog TO incident_writer;
GRANT SELECT, INSERT ON alert_deliveries, rejected_events TO incident_writer;
GRANT SELECT, INSERT, UPDATE ON incidents, dead_letters TO incident_writer;
