#!/usr/bin/env bash
# =============================================================================
# post-build.sh — AsBuiltReport Manager OVA
#
# Called by Buildroot after the target rootfs is assembled but before the
# filesystem image is created.  This script:
#
#   1. Downloads / copies the Docker CE static binaries into the rootfs
#   2. Copies pre-saved Docker images (docker save output) into the rootfs
#   3. Installs the Docker Compose plugin binary
#   4. Finalises systemd unit symlinks (enable on boot)
#   5. Sets correct permissions on overlay directories
#
# Environment variables provided by Buildroot:
#   TARGET_DIR   — path to the assembled rootfs
#   BUILD_DIR    — Buildroot build directory
#   BINARIES_DIR — output/images
#   BR2_EXTERNAL_ASBUILTREPORT_MANAGER_PATH — this external tree root
# =============================================================================
set -euo pipefail

TARGET_DIR="${TARGET_DIR:?TARGET_DIR not set}"
EXTERNAL="${BR2_EXTERNAL_ASBUILTREPORT_MANAGER_PATH:?not set}"

DOCKER_VERSION="26.1.4"
COMPOSE_VERSION="2.27.1"
ARCH="x86_64"

DOCKER_BUNDLE_URL="https://download.docker.com/linux/static/stable/${ARCH}/docker-${DOCKER_VERSION}.tgz"
COMPOSE_URL="https://github.com/docker/compose/releases/download/v${COMPOSE_VERSION}/docker-compose-linux-${ARCH}"

PRELOAD_DIR="${TARGET_DIR}/var/lib/docker-preload"
DOCKER_IMAGES_SRC="${EXTERNAL}/board/asbuiltreport-manager/docker-images"

# ── Colour helpers ─────────────────────────────────────────────────────────
info()  { echo "[post-build] INFO:  $*"; }
warn()  { echo "[post-build] WARN:  $*" >&2; }
error() { echo "[post-build] ERROR: $*" >&2; exit 1; }

# =============================================================================
# 1. Docker CE static binaries
# =============================================================================
DOCKER_BIN_DIR="${TARGET_DIR}/usr/bin"

if [[ ! -f "${DOCKER_BIN_DIR}/dockerd" ]]; then
    info "Downloading Docker CE ${DOCKER_VERSION} static bundle…"
    TMPTAR=$(mktemp /tmp/docker-XXXXXX.tgz)
    curl -fsSL "${DOCKER_BUNDLE_URL}" -o "${TMPTAR}"
    info "Extracting Docker binaries to ${DOCKER_BIN_DIR}…"
    tar -xzf "${TMPTAR}" --strip-components=1 -C "${DOCKER_BIN_DIR}"
    rm -f "${TMPTAR}"
    chmod 0755 "${DOCKER_BIN_DIR}"/docker \
               "${DOCKER_BIN_DIR}"/dockerd \
               "${DOCKER_BIN_DIR}"/docker-proxy \
               "${DOCKER_BIN_DIR}"/docker-init \
               "${DOCKER_BIN_DIR}"/containerd \
               "${DOCKER_BIN_DIR}"/containerd-shim-runc-v2 \
               "${DOCKER_BIN_DIR}"/ctr \
               "${DOCKER_BIN_DIR}"/runc
    info "Docker CE binaries installed."
else
    info "Docker CE binaries already present, skipping download."
fi

# =============================================================================
# 2. Docker Compose plugin
# =============================================================================
COMPOSE_PLUGIN_DIR="${TARGET_DIR}/usr/libexec/docker/cli-plugins"
mkdir -p "${COMPOSE_PLUGIN_DIR}"

if [[ ! -f "${COMPOSE_PLUGIN_DIR}/docker-compose" ]]; then
    info "Downloading Docker Compose plugin v${COMPOSE_VERSION}…"
    curl -fsSL "${COMPOSE_URL}" -o "${COMPOSE_PLUGIN_DIR}/docker-compose"
    chmod 0755 "${COMPOSE_PLUGIN_DIR}/docker-compose"
    info "Docker Compose plugin installed."
else
    info "Docker Compose plugin already present, skipping download."
fi

# =============================================================================
# 3. Pre-saved Docker images
#    Place your docker-save tarballs in:
#      buildroot/external/board/asbuiltreport-manager/docker-images/
#        asbuiltreport-manager-app.tar
#        asbuiltreport-manager-worker.tar
#
#    These are produced by the build pipeline:
#      docker save asbuiltreport-manager-app   | gzip > app.tar.gz
#      docker save asbuiltreport-manager-worker | gzip > worker.tar.gz
# =============================================================================
mkdir -p "${PRELOAD_DIR}"

if [[ -d "${DOCKER_IMAGES_SRC}" ]]; then
    shopt -s nullglob
    IMAGE_FILES=("${DOCKER_IMAGES_SRC}"/*.tar "${DOCKER_IMAGES_SRC}"/*.tar.gz)
    shopt -u nullglob

    if (( ${#IMAGE_FILES[@]} > 0 )); then
        log "Copying ${#IMAGE_FILES[@]} pre-saved Docker image(s) into rootfs…"
        for image_tar in "${IMAGE_FILES[@]}"; do
            BASENAME=$(basename "${image_tar}")
            log "  → ${BASENAME}"
            cp "${image_tar}" "${PRELOAD_DIR}/${BASENAME}"
        done
        log "Docker image tarballs staged in ${PRELOAD_DIR}."
        ls -lh "${PRELOAD_DIR}/"
    else
        warn "No image tarballs found in ${DOCKER_IMAGES_SRC}."
        warn "Expected: ${DOCKER_IMAGES_SRC}/asbuiltreport-app.tar.gz"
        warn "          ${DOCKER_IMAGES_SRC}/asbuiltreport-worker.tar.gz"
        warn "The VM will attempt to pull images on first boot — requires internet!"
    fi
else
    warn "docker-images directory not found at: ${DOCKER_IMAGES_SRC}"
    warn "Run 'make prepare-images' or let the CI workflow build them."
fi

# =============================================================================
# 4. Systemd — enable services
# =============================================================================
SYSTEMD_WANTS="${TARGET_DIR}/etc/systemd/system/multi-user.target.wants"
mkdir -p "${SYSTEMD_WANTS}"

for unit in \
    docker.service \
    asbuiltreport-manager.service \
    asbuiltreport-first-boot.service \
    asbuiltreport-console.service \
    asbuiltreport-ovf-init.service
do
    SRC="${TARGET_DIR}/lib/systemd/system/${unit}"
    LINK="${SYSTEMD_WANTS}/${unit}"
    if [[ -f "${SRC}" ]] && [[ ! -L "${LINK}" ]]; then
        ln -sf "/lib/systemd/system/${unit}" "${LINK}"
        info "Enabled systemd unit: ${unit}"
    fi
done

# first-boot service wants — runs once then self-disables
SYSTEMD_SYSINIT="${TARGET_DIR}/etc/systemd/system/sysinit.target.wants"
mkdir -p "${SYSTEMD_SYSINIT}"
OVFINIT="${TARGET_DIR}/lib/systemd/system/asbuiltreport-ovf-init.service"
if [[ -f "${OVFINIT}" ]]; then
    ln -sf "/lib/systemd/system/asbuiltreport-ovf-init.service" \
           "${SYSTEMD_SYSINIT}/asbuiltreport-ovf-init.service" 2>/dev/null || true
fi

# =============================================================================
# 5. Permissions
# =============================================================================
# Bind-mount dirs owned by root, world-readable
for d in \
    "${TARGET_DIR}/var/www/reports" \
    "${TARGET_DIR}/etc/asbuiltreport" \
    "${TARGET_DIR}/var/lib/asbuiltreport/ps-modules"
do
    install -d -m 0755 "${d}"
done

# Docker socket dir
install -d -m 0710 "${TARGET_DIR}/run/docker" 2>/dev/null || true

# sshd host keys directory
install -d -m 0700 "${TARGET_DIR}/etc/ssh" 2>/dev/null || true

info "post-build.sh completed successfully."
