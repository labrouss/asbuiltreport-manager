# ──────────────────────────────────────────────────────────────────────────────
# AsBuiltReport Manager — Makefile
# Usage: make <target>
# ──────────────────────────────────────────────────────────────────────────────
.PHONY: help up down build rebuild rebuild-app rebuild-worker \
        logs logs-app logs-worker shell-app shell-worker \
        ps clean reset dirs

COMPOSE  = docker compose
APP      = asbuiltreport-app
WORKER   = asbuiltreport-worker
BUST     = $(shell date +%s)

help:  ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | \
	awk 'BEGIN {FS = ":.*##"}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

## ── Lifecycle ─────────────────────────────────────────────────────────────────
up: dirs  ## Start all containers (build if needed)
	$(COMPOSE) up -d

down:  ## Stop and remove containers
	$(COMPOSE) down

restart:  ## Restart all containers
	$(COMPOSE) restart

ps:  ## Show container status
	$(COMPOSE) ps

## ── Build ─────────────────────────────────────────────────────────────────────
build: dirs  ## Build all images (uses cache)
	$(COMPOSE) build

rebuild: dirs  ## Force rebuild ALL images (no cache)
	$(COMPOSE) build --no-cache
	$(COMPOSE) up -d

rebuild-app: dirs  ## Force rebuild app image only (busts frontend cache)
	$(COMPOSE) build --build-arg CACHEBUST=$(BUST) app
	$(COMPOSE) up -d app

rebuild-worker:  ## Force rebuild worker image only (no cache)
	$(COMPOSE) build --no-cache worker
	$(COMPOSE) up -d worker

## ── Hot-copy (no rebuild needed) ─────────────────────────────────────────────
deploy-backend:  ## Hot-copy server.js + auth.js and restart app
	docker cp backend/src/server.js $(APP):/app/backend/src/server.js
	docker cp backend/src/auth.js   $(APP):/app/backend/src/auth.js
	docker cp backend/src/scheduler.js $(APP):/app/backend/src/scheduler.js
	$(COMPOSE) restart app

deploy-worker:  ## Hot-copy worker.ps1 and restart worker
	docker cp worker/worker.ps1     $(WORKER):/app/worker.ps1
	docker cp worker/entrypoint.ps1 $(WORKER):/app/entrypoint.ps1
	docker cp worker/reports/Invoke-HPEOneViewReport.ps1 \
	          $(WORKER):/app/reports/Invoke-HPEOneViewReport.ps1
	$(COMPOSE) restart worker

## ── Logs ──────────────────────────────────────────────────────────────────────
logs:  ## Tail logs from all containers
	$(COMPOSE) logs -f

logs-app:  ## Tail app container logs
	$(COMPOSE) logs -f app

logs-worker:  ## Tail worker container logs
	$(COMPOSE) logs -f worker

## ── Shell access ──────────────────────────────────────────────────────────────
shell-app:  ## Open shell in app container
	docker exec -it $(APP) sh

shell-worker:  ## Open PowerShell in worker container
	docker exec -it $(WORKER) pwsh

## ── Maintenance ───────────────────────────────────────────────────────────────
dirs:  ## Create required host directories
	@mkdir -p /var/www/reports /etc/asbuiltreport /var/lib/asbuiltreport/ps-modules
	@chmod 777 /var/www/reports 2>/dev/null || true

clean: down  ## Stop containers and remove images
	docker rmi asbuiltreport-manager-app asbuiltreport-manager-worker 2>/dev/null || true

reset: clean  ## Full reset — remove containers, images AND all data volumes
	@echo "⚠️  This will delete ALL reports, configs and user data!"
	@read -p "Type 'yes' to confirm: " c && [ "$$c" = "yes" ] || exit 1
	rm -rf /var/www/reports/* /etc/asbuiltreport/* /var/lib/asbuiltreport/ps-modules/*
	@echo "Reset complete. Run 'make up' to start fresh."

status:  ## Show container health and ports
	@echo "\n── Containers ──────────────────────────────────────────────"
	@$(COMPOSE) ps
	@echo "\n── App logs (last 20 lines) ────────────────────────────────"
	@docker logs $(APP) --tail 20 2>/dev/null || true
