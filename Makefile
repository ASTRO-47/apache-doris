.PHONY: up down init status clean logs logs-fe logs-be logs-gen

COMPOSE=docker-compose -f docker-compose.yml

up:
	mkdir -p fe-data-01 be-data-01 be-data-02 minio-data
	$(COMPOSE) up -d

down:
	$(COMPOSE) --profile generate down

init:
	./scripts/init-cluster.sh

status:
	$(COMPOSE) --profile generate ps -a

gen:
	$(COMPOSE) --profile generate up -d --build data-generator

stop-gen:
	$(COMPOSE) stop data-generator

clean:
	$(COMPOSE) --profile generate down -v
	sudo rm -rf fe-data-01 be-data-01 be-data-02 minio-data

logs:
	$(COMPOSE) --profile generate logs -f

logs-fe:
	$(COMPOSE) logs -f doris-fe-01

logs-be:
	$(COMPOSE) logs -f doris-be-01

logs-gen:
	$(COMPOSE) --profile generate logs -f data-generator

stats:
	bash check-compression.sh