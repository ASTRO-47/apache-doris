COMPOSE_FILE=docker-compose.yml

# ─── Core Cluster ───

up:
	mkdir -p fe-data-01 be-data-01 minio-data
	docker compose -f $(COMPOSE_FILE) up -d

down:
	docker compose -f $(COMPOSE_FILE) --profile generate down

restart:
	docker compose -f $(COMPOSE_FILE) restart

status:
	docker compose -f $(COMPOSE_FILE) --profile generate ps -a

# ─── Initialization ───

init:
	./scripts/init-cluster.sh

check:
	./scripts/check-cluster.sh

# ─── Data Generator ───

gen:
	docker compose -f $(COMPOSE_FILE) --profile generate up -d --build data-generator
	@echo "✓ Generator started! View logs: make logs-gen"

stop-gen:
	docker compose -f $(COMPOSE_FILE) stop data-generator

# ─── Full Lifecycle ───

fresh: clean up
	@echo "Waiting 30 seconds for services to start..."
	@sleep 30
	@$(MAKE) init

clean:
	docker compose -f $(COMPOSE_FILE) --profile generate down -v
	sudo rm -rf fe-data-01 fe-data-02 be-data-01 be-data-02 be-data-03 minio-data

# ─── Logs ───

logs:
	docker compose -f $(COMPOSE_FILE) --profile generate logs -f

logs-fe:
	docker logs -f doris-fe-01

logs-be:
	docker logs -f doris-be-01

logs-gen:
	docker logs -f doris-data-generator

logs-ms:
	docker logs -f doris-ms