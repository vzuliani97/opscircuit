-- Makes the table match service-catalog/services.json exactly: upsert what is listed, delete what is not.
BEGIN;

INSERT INTO service_catalog (service, owner, runbook, page_severities)
SELECT service, owner, runbook, page_severities
FROM jsonb_to_recordset(:'catalog'::jsonb -> 'services')
  AS s (service text, owner text, runbook text, page_severities text[])
ON CONFLICT (service) DO UPDATE
SET owner = EXCLUDED.owner, runbook = EXCLUDED.runbook, page_severities = EXCLUDED.page_severities;

DELETE FROM service_catalog
WHERE service NOT IN (SELECT jsonb_array_elements(:'catalog'::jsonb -> 'services') ->> 'service');

COMMIT;
