COMPOSE_FILE=docker-compose.yml

up:
	mkdir -p fe-data-01 fe-data-02 be-data-01 be-data-02 be-data-03
	docker compose -f $(COMPOSE_FILE) up -d 

down:
	docker compose -f $(COMPOSE_FILE) down

restart:
	docker compose -f $(COMPOSE_FILE) restart

logs:
	docker compose -f $(COMPOSE_FILE) logs -f

logs-fe:
	docker logs -f doris-fe-01

logs-be:
	docker logs -f doris-be-01

logs-gen:
	docker logs -f doris-data-generator

status:
	docker compose -f $(COMPOSE_FILE) ps

init:
	./scripts/init-cluster.sh

check:
	./scripts/check-cluster.sh

clean:
	docker compose -f $(COMPOSE_FILE) down -v
	rm -rf fe-data-01 fe-data-02 be-data-01 be-data-02 be-data-03

fresh: clean up
	@echo "Waiting 30 seconds for services to start..."
	@sleep 30
	@$(MAKE) init

# Data Generator
build-gen:
	docker build -t doris-data-generator ./data-generator

run-gen:
	docker run -d \
		--name doris-data-generator \
		--network apache-dori_doris_net \
		-e DORIS_FE_HOST=172.20.80.2 \
		-e DORIS_FE_PORT=9030 \
		-e DORIS_USER=root \
		-e DORIS_PASSWORD= \
		-e EVENTS_PER_SECOND=10 \
		doris-data-generator
	@echo "Data generator started! View logs with: make logs-gen"

stop-gen:
	docker stop doris-data-generator && docker rm doris-data-generator

gen: build-gen run-gen