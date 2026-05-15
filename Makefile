# =============================================================================
# AsBuiltReport Manager — Makefile
#
# This repo supports two deployment modes:
#
#   DOCKER MODE  — clone the repo and run locally with Docker Compose
#   APPLIANCE    — download the pre-built OVA and deploy to VMware
#
# Docker mode targets (everyday use):
#   make up              Start containers (build if needed)
#   make down            Stop containers
#   make build           Build all images (with cache)
#   make rebuild         Force rebuild all images, then start
#   make rebuild-app     Rebuild app image only
#   make rebuild-worker  Rebuild worker image only
#   make logs            Tail all logs
#   make shell-app       sh into app container
#   make shell-worker    pwsh into worker container
#   make deploy-backend  Hot-copy backend source, restart app (no rebuild)
#   make deploy-worker   Hot-copy worker scripts, restart worker (no rebuild)
#   make status          Container health summary
#   make reset           Wipe all data and start fresh
#
# OVA build targets (CI / release pipeline):
#   make prepare-images  Build both images and save as .tar.gz for Buildroot
#   make prepare-app     Rebuild + save app image only
#   make prepare-worker  Rebuild + save worker image only
#   make defconfig       Configure Buildroot (downloads Buildroot if needed)
#   make ova-build       Build the OVA (~1-2 hours)
#   make menuconfig      Interactive Buildroot config
#   make savedefconfig   Save config back to external tree
# =============================================================================
.PHONY: help \
        up down restart ps build rebuild rebuild-app rebuild-worker \
        deploy-backend deploy-worker \
        logs logs-app logs-worker \
        shell-app shell-worker \
        dirs status clean reset \
        prepare-images prepare-app prepare-worker \
        defconfig ova-build menuconfig savedefconfig linux-menuconfig \
        ova-shell ova-clean ova-distclean

# ── Shared ────────────────────────────────────────────────────────────────────
COMPOSE  = docker compose
APP      = asbuiltreport-app
WORKER   = asbuiltreport-worker
BUST     = $(shell date +%s)

# ── OVA build config ──────────────────────────────────────────────────────────
BUILDROOT_VERSION  ?= 2024.02.6
BUILDROOT_DIR      ?= buildroot-$(BUILDROOT_VERSION)
BUILDROOT_URL       = https://buildroot.org/downloads/buildroot-$(BUILDROOT_VERSION).tar.gz
EXTERNAL_DIR       := $(CURDIR)/buildroot/external
OVA_OUTPUT_DIR     := $(CURDIR)/output
OVA_DOWNLOADS_DIR  := $(CURDIR)/downloads
DOCKER_IMAGES_DIR  := $(EXTERNAL_DIR)/board/asbuiltreport-manager/docker-images

# ── Colours ───────────────────────────────────────────────────────────────────
BOLD  = \033[1m
RESET = \033[0m
GREEN = \033[0;32m
CYAN  = \033[36m
YELLOW = \033[1;33m

# =============================================================================
# Help
# =============================================================================
help:  ## Show this help
	@echo ""
	@printf "$(BOLD)AsBuiltReport Manager$(RESET)\n"
	@echo ""
	@printf "$(CYAN)── Docker mode (local deployment) ────────────────────────────$(RESET)\n"
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | \
	    grep -v "^prepare\|^defconfig\|^ova\|^menu\|^save\|^linux" | \
	    awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@printf "$(CYAN)── OVA appliance build ───────────────────────────────────────$(RESET)\n"
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | \
	    grep "^prepare\|^defconfig\|^ova\|^menu\|^save\|^linux" | \
	    awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""

# =============================================================================
# DOCKER MODE — local deployment with Docker Compose
# =============================================================================

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
build: dirs  ## Build all images (uses layer cache)
	$(COMPOSE) build

rebuild: dirs  ## Force rebuild ALL images (no cache), then start
	$(COMPOSE) build --no-cache
	$(COMPOSE) up -d

rebuild-app: dirs  ## Force rebuild app image only (busts frontend cache)
	$(COMPOSE) build --build-arg CACHEBUST=$(BUST) app
	$(COMPOSE) up -d app

rebuild-worker:  ## Force rebuild worker image only (no cache, ~40 min)
	$(COMPOSE) build --no-cache worker
	$(COMPOSE) up -d worker

## ── Hot-copy (no rebuild needed) ─────────────────────────────────────────────
deploy-backend:  ## Hot-copy backend source files and restart app (no rebuild)
	docker cp backend/src/server.js    $(APP):/app/backend/src/server.js
	docker cp backend/src/auth.js      $(APP):/app/backend/src/auth.js
	docker cp backend/src/scheduler.js $(APP):/app/backend/src/scheduler.js
	$(COMPOSE) restart app

deploy-worker:  ## Hot-copy worker scripts and restart worker (no rebuild)
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
dirs:  ## Create required host directories (idempotent)
	@mkdir -p /var/www/reports /etc/asbuiltreport /var/lib/asbuiltreport/ps-modules
	@chmod 777 /var/www/reports 2>/dev/null || true

status:  ## Show container health and recent app logs
	@printf "\n$(CYAN)── Containers ──────────────────────────────────────────────$(RESET)\n"
	@$(COMPOSE) ps
	@printf "\n$(CYAN)── App logs (last 20 lines) ────────────────────────────────$(RESET)\n"
	@docker logs $(APP) --tail 20 2>/dev/null || true

clean: down  ## Stop containers and remove images
	docker rmi $(APP):latest $(WORKER):latest 2>/dev/null || true

reset: clean  ## Full reset — remove containers, images AND all data (DESTRUCTIVE)
	@printf "$(YELLOW)⚠  This will delete ALL reports, configs and user data!$(RESET)\n"
	@read -p "Type 'yes' to confirm: " c && [ "$$c" = "yes" ] || exit 1
	rm -rf /var/www/reports/* /etc/asbuiltreport/* /var/lib/asbuiltreport/ps-modules/*
	@printf "$(GREEN)Reset complete. Run 'make up' to start fresh.$(RESET)\n"

# =============================================================================
# OVA APPLIANCE BUILD — Buildroot pipeline
# =============================================================================

## ── Step 1: Build & save Docker images as tarballs ───────────────────────────
prepare-images: prepare-app prepare-worker  ## Build both images and save as .tar.gz for Buildroot

prepare-app: $(DOCKER_IMAGES_DIR)/.stamp_app_saved  ## Build + save app image only (~2 min)

prepare-worker: $(DOCKER_IMAGES_DIR)/.stamp_worker_saved  ## Build + save worker image only (~40 min)

# App stamp — depends on every file the Dockerfile COPYs from the build context.
# Touch it to skip a rebuild: touch buildroot/external/board/.../docker-images/.stamp_app_saved
$(DOCKER_IMAGES_DIR)/.stamp_app_saved: Dockerfile .dockerignore \
    $(shell find frontend backend -type f 2>/dev/null)
	@printf "$(BOLD)Building app image ($(APP):latest)...$(RESET)\n"
	$(COMPOSE) build app
	@printf "$(BOLD)Saving $(APP):latest → tarball...$(RESET)\n"
	mkdir -p $(DOCKER_IMAGES_DIR)
	docker save $(APP):latest | gzip > $(DOCKER_IMAGES_DIR)/$(APP).tar.gz
	@printf "$(GREEN)  ✓ $(shell du -sh $(DOCKER_IMAGES_DIR)/$(APP).tar.gz | cut -f1)  $(DOCKER_IMAGES_DIR)/$(APP).tar.gz$(RESET)\n"
	touch $@

# Worker stamp — keyed on the expensive Dockerfile layers only.
# Changing entrypoint.ps1/worker.ps1 rebuilds the cheap final COPY layers only.
$(DOCKER_IMAGES_DIR)/.stamp_worker_saved: worker/Dockerfile \
    worker/install-powercli.ps1 worker/install-modules.ps1 \
    $(shell find worker -type f 2>/dev/null)
	@printf "$(BOLD)Building worker image ($(WORKER):latest)...$(RESET)\n"
	@printf "$(YELLOW)  Note: first build takes ~40 min (Veeam + PowerCLI + 16 PS modules)$(RESET)\n"
	$(COMPOSE) build worker
	@printf "$(BOLD)Saving $(WORKER):latest → tarball...$(RESET)\n"
	mkdir -p $(DOCKER_IMAGES_DIR)
	docker save $(WORKER):latest | gzip > $(DOCKER_IMAGES_DIR)/$(WORKER).tar.gz
	@printf "$(GREEN)  ✓ $(shell du -sh $(DOCKER_IMAGES_DIR)/$(WORKER).tar.gz | cut -f1)  $(DOCKER_IMAGES_DIR)/$(WORKER).tar.gz$(RESET)\n"
	touch $@

## ── Step 2: Buildroot ─────────────────────────────────────────────────────────
$(BUILDROOT_DIR)/.stamp_extracted:
	@printf "$(BOLD)Downloading Buildroot $(BUILDROOT_VERSION)...$(RESET)\n"
	mkdir -p $(OVA_DOWNLOADS_DIR)
	test -f $(OVA_DOWNLOADS_DIR)/buildroot-$(BUILDROOT_VERSION).tar.gz || \
	    curl -fL $(BUILDROOT_URL) -o $(OVA_DOWNLOADS_DIR)/buildroot-$(BUILDROOT_VERSION).tar.gz
	tar -xzf $(OVA_DOWNLOADS_DIR)/buildroot-$(BUILDROOT_VERSION).tar.gz
	touch $@

defconfig: $(BUILDROOT_DIR)/.stamp_extracted  ## Configure Buildroot (downloads Buildroot if needed)
	@printf "$(BOLD)Applying defconfig...$(RESET)\n"
	$(MAKE) -C $(BUILDROOT_DIR) \
	    BR2_EXTERNAL=$(EXTERNAL_DIR) \
	    O=$(OVA_OUTPUT_DIR) \
	    asbuiltreport_manager_defconfig

ova-build: $(BUILDROOT_DIR)/.stamp_extracted  ## Build the OVA appliance (~1-2 hours)
	@printf "$(BOLD)Building AsBuiltReport Manager OVA...$(RESET)\n"
	@printf "$(YELLOW)  This may take 1-2 hours on a fast machine.$(RESET)\n"
	@printf "$(YELLOW)  Run 'make prepare-images' first if tarballs are missing.$(RESET)\n"
	$(MAKE) -C $(BUILDROOT_DIR) \
	    BR2_EXTERNAL=$(EXTERNAL_DIR) \
	    O=$(OVA_OUTPUT_DIR) \
	    BR2_DL_DIR=$(OVA_DOWNLOADS_DIR) \
	    -j$(shell nproc)
	@printf "$(GREEN)  OVA ready: $(OVA_OUTPUT_DIR)/images/asbuiltreport-manager-v*.ova$(RESET)\n"

menuconfig: $(BUILDROOT_DIR)/.stamp_extracted  ## Interactive Buildroot kernel/package config
	$(MAKE) -C $(BUILDROOT_DIR) \
	    BR2_EXTERNAL=$(EXTERNAL_DIR) \
	    O=$(OVA_OUTPUT_DIR) \
	    menuconfig

savedefconfig: $(BUILDROOT_DIR)/.stamp_extracted  ## Save current Buildroot config back to external tree
	$(MAKE) -C $(BUILDROOT_DIR) \
	    BR2_EXTERNAL=$(EXTERNAL_DIR) \
	    O=$(OVA_OUTPUT_DIR) \
	    BR2_DEFCONFIG=$(EXTERNAL_DIR)/configs/asbuiltreport_manager_defconfig \
	    savedefconfig

linux-menuconfig: $(BUILDROOT_DIR)/.stamp_extracted  ## Interactive Linux kernel config
	$(MAKE) -C $(BUILDROOT_DIR) \
	    BR2_EXTERNAL=$(EXTERNAL_DIR) \
	    O=$(OVA_OUTPUT_DIR) \
	    linux-menuconfig

ova-shell: $(BUILDROOT_DIR)/.stamp_extracted  ## Drop into Buildroot shell environment
	@bash --rcfile <(echo "cd $(BUILDROOT_DIR); \
	    export BR2_EXTERNAL=$(EXTERNAL_DIR); \
	    export O=$(OVA_OUTPUT_DIR); \
	    export PS1='[buildroot] \w \$ '")

ova-clean:  ## Remove Buildroot output (keeps downloads and Docker image tarballs)
	rm -rf $(OVA_OUTPUT_DIR)

ova-distclean: ova-clean  ## Remove everything — Buildroot source, downloads, and image tarballs
	rm -rf $(BUILDROOT_DIR) $(OVA_DOWNLOADS_DIR)
	rm -f  $(DOCKER_IMAGES_DIR)/*.tar.gz \
	       $(DOCKER_IMAGES_DIR)/.stamp_app_saved \
	       $(DOCKER_IMAGES_DIR)/.stamp_worker_saved
