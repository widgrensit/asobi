.PHONY: test db-reset db-up db-down migrate

db-up:
	docker compose up -d
	@echo "Waiting for PostgreSQL..."
	@until docker compose exec -T postgres pg_isready -U postgres > /dev/null 2>&1; do sleep 1; done
	@echo "PostgreSQL is ready"

db-down:
	docker compose down -v

db-reset: db-down db-up
	@docker compose exec -T postgres psql -U postgres -c "DROP DATABASE IF EXISTS asobi_dev;" > /dev/null 2>&1
	@docker compose exec -T postgres psql -U postgres -c "CREATE DATABASE asobi_dev;" > /dev/null 2>&1
	@echo "Database reset"

test: db-reset
	rebar3 ct --sname asobi_test
