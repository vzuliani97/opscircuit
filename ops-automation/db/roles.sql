-- n8n gets its own database. The workflow connects to the incident store as incident_writer,
-- which can only read the catalog and write incident data.
SELECT format('CREATE ROLE n8n LOGIN PASSWORD %L', :'n8n_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'n8n') \gexec
ALTER ROLE n8n PASSWORD :'n8n_password';

SELECT 'CREATE DATABASE n8n OWNER n8n'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'n8n') \gexec

SELECT format('CREATE ROLE incident_writer LOGIN PASSWORD %L', :'incidents_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'incident_writer') \gexec
ALTER ROLE incident_writer PASSWORD :'incidents_password';
-- Fail fast instead of piling up executions behind a lock; the error workflow records the failure.
ALTER ROLE incident_writer SET lock_timeout = '2s';
ALTER ROLE incident_writer SET statement_timeout = '5s';

SELECT 'CREATE DATABASE incidents'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'incidents') \gexec
REVOKE ALL ON DATABASE incidents FROM PUBLIC;
GRANT CONNECT ON DATABASE incidents TO incident_writer;
