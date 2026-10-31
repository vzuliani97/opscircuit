COMPOSE := docker compose
PSQL    := $(COMPOSE) exec -T postgres psql -U postgres -d incidents

.PHONY: env up test down clean audit replay report logs validate

## Random local secrets, created once and never committed (hex only: they end up inside JSON)
env:
	@test -f .env || { umask 077; printf 'POSTGRES_PASSWORD=%s\nN8N_DB_PASSWORD=%s\nINCIDENTS_DB_PASSWORD=%s\nN8N_ENCRYPTION_KEY=%s\nALERT_WEBHOOK_TOKEN=%s\n' \
		"$$(openssl rand -hex 16)" "$$(openssl rand -hex 16)" "$$(openssl rand -hex 16)" "$$(openssl rand -hex 32)" "$$(openssl rand -hex 32)" > .env; }

## Start the lab and wait until every health check passes (bounded, no fixed sleeps)
up: env
	$(COMPOSE) up -d --wait --wait-timeout 240

## Integration tests against the running lab. They reset lab data first.
test:
	node --test tests/*.test.mjs

## Static checks that need no running containers (also run in CI)
validate:
	$(COMPOSE) --env-file .env.example config --quiet
	@for f in workflows/*.json service-catalog/services.json fixtures/*.json; do jq empty "$$f" || exit 1; done
	@echo "compose and JSON files are valid"

## n8n's built-in security audit of this instance
audit:
	$(COMPOSE) exec -T n8n n8n audit

replay:
	./scripts/replay-dead-letters.sh

report:
	$(PSQL) -x -c 'SELECT * FROM incident_outcomes'

logs:
	$(COMPOSE) logs --no-color --tail=200

down:
	$(COMPOSE) down

## Also deletes the PostgreSQL and n8n volumes
clean:
	$(COMPOSE) down -v
