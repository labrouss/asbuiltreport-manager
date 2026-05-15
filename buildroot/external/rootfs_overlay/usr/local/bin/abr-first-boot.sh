#!/bin/bash
# =============================================================================
# abr-first-boot.sh — AsBuiltReport Manager First-Boot Initialisation
#
# Runs exactly once (guarded by sentinel file).
# 1. Creates required bind-mount host directories
# 2. Loads pre-saved Docker images from /var/lib/docker-preload/
# 3. Starts the Docker Compose stack
# 4. Writes sentinel file
# =============================================================================
set -euo pipefail

SENTINEL="/var/lib/asbuiltreport/.first-boot-done"
PRELOAD_DIR="/var/lib/docker-preload"
COMPOSE_DIR="/etc/docker/compose/asbuiltreport-manager"
LOG_TAG="abr-first-boot"

log()  { echo "${LOG_TAG}: $*"; logger -t "${LOG_TAG}" "$*"; }
warn() { echo "${LOG_TAG}: WARN: $*" >&2; }
error(){ echo "${LOG_TAG}: ERROR: $*" >&2; exit 1; }

log "============================================================"
log " AsBuiltReport Manager — First Boot Initialisation"
log "============================================================"

# =============================================================================
# 1. Create bind-mount directories
# =============================================================================
log "Creating application directories…"
mkdir -p /var/www/reports
mkdir -p /etc/asbuiltreport
mkdir -p /var/lib/asbuiltreport/ps-modules
chmod 0755 /var/www/reports /etc/asbuiltreport /var/lib/asbuiltreport/ps-modules

# =============================================================================
# 2. Wait for Docker daemon to be ready
# =============================================================================
log "Waiting for Docker daemon…"
RETRIES=30
until docker info &>/dev/null; do
    RETRIES=$(( RETRIES - 1 ))
    if (( RETRIES == 0 )); then
        error "Docker daemon did not become ready in time."
    fi
    sleep 2
done
log "Docker daemon is ready."

# =============================================================================
# 3. Load pre-saved Docker images
# =============================================================================
if [[ -d "${PRELOAD_DIR}" ]]; then
    shopt -s nullglob
    IMAGE_FILES=("${PRELOAD_DIR}"/*.tar "${PRELOAD_DIR}"/*.tar.gz)
    shopt -u nullglob

    if (( ${#IMAGE_FILES[@]} > 0 )); then
        log "Loading ${#IMAGE_FILES[@]} pre-saved Docker image(s)…"
        for img in "${IMAGE_FILES[@]}"; do
            log "  Loading: $(basename "${img}")"
            if [[ "${img}" == *.tar.gz ]]; then
                gunzip -c "${img}" | docker load
            else
                docker load < "${img}"
            fi
        done
        log "All Docker images loaded successfully."
    else
        warn "No image tarballs found in ${PRELOAD_DIR}."
        warn "Attempting to pull images from Docker Hub (requires internet)."
        # Fallback: compose will pull on 'up'
    fi
else
    warn "Preload directory ${PRELOAD_DIR} not found."
fi

# =============================================================================
# 4. Start the Docker Compose stack
# =============================================================================
log "Starting AsBuiltReport Manager stack…"
cd "${COMPOSE_DIR}"
docker compose up -d --remove-orphans

# Wait for health checks
log "Waiting for containers to become healthy…"
RETRIES=30
while true; do
    APP_HEALTH=$(docker inspect --format '{{.State.Health.Status}}' asbuiltreport-app 2>/dev/null || echo "starting")
    WORKER_HEALTH=$(docker inspect --format '{{.State.Health.Status}}' asbuiltreport-worker 2>/dev/null || echo "starting")

    if [[ "${APP_HEALTH}" == "healthy" ]] && [[ "${WORKER_HEALTH}" == "healthy" ]]; then
        log "All containers are healthy."
        break
    fi

    RETRIES=$(( RETRIES - 1 ))
    if (( RETRIES == 0 )); then
        warn "Containers did not become healthy in time. Check: docker compose logs"
        break
    fi
    log "  app=${APP_HEALTH}  worker=${WORKER_HEALTH} — waiting…"
    sleep 10
done

# =============================================================================
# 5. Print access information
# =============================================================================
# Detect the primary IP address
PRIMARY_IP=$(ip -4 addr show scope global | grep -oP '(?<=inet )\d+\.\d+\.\d+\.\d+' | head -1)
PRIMARY_IP="${PRIMARY_IP:-<this-vm-ip>}"

log ""
log "  ┌─────────────────────────────────────────────────────────┐"
log "  │                                                         │"
log "  │   AsBuiltReport Manager is ready!                      │"
log "  │                                                         │"
log "  │   Web UI:  http://${PRIMARY_IP}:3001                   │"
log "  │                                                         │"
log "  └─────────────────────────────────────────────────────────┘"
log ""

# Display on tty1 as well
cat > /dev/tty1 <<EOF 2>/dev/null || true


  ╔═══════════════════════════════════════════════════════════╗
  ║      AsBuiltReport Manager — Ready                       ║
  ║                                                           ║
  ║   Web UI:  http://${PRIMARY_IP}:3001                      ║
  ║                                                           ║
  ║   Press ENTER to open the management console             ║
  ╚═══════════════════════════════════════════════════════════╝

EOF

# =============================================================================
# 6. Write sentinel — prevents re-running on subsequent boots
# =============================================================================
mkdir -p "$(dirname "${SENTINEL}")"
touch "${SENTINEL}"
log "First-boot initialisation complete."
