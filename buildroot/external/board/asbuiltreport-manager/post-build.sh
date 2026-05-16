#!/usr/bin/env bash
# =============================================================================
# post-build.sh — AsBuiltReport Manager OVA
#
# Runs after the Buildroot rootfs is assembled but before the filesystem
# image is written. Mirrors the san-manager post-build.sh pattern exactly.
#
# This script:
#   1. Downloads Docker Compose plugin static binary (Buildroot's
#      BR2_PACKAGE_DOCKER_COMPOSE installs the compose package but we also
#      want the CLI plugin path for 'docker compose' subcommand)
#   2. Copies pre-saved Docker image tarballs into /var/lib/docker-preload/
#   3. Creates required bind-mount directories
#   4. Sets correct permissions on init scripts and overlay files
#   5. Writes /etc/inittab (busybox init — no systemd)
# =============================================================================
set -euo pipefail

TARGET_DIR="${TARGET_DIR:?}"
EXTERNAL="${BR2_EXTERNAL_ASBUILTREPORT_MANAGER_PATH:?}"

COMPOSE_VERSION="${COMPOSE_VERSION:-2.27.1}"
ARCH="x86_64"
COMPOSE_URL="https://github.com/docker/compose/releases/download/v${COMPOSE_VERSION}/docker-compose-linux-${ARCH}"

PRELOAD_DIR="${TARGET_DIR}/var/lib/docker-preload"
DOCKER_IMAGES_SRC="${EXTERNAL}/board/asbuiltreport-manager/docker-images"

info()  { echo "[post-build] INFO:  $*"; }
warn()  { echo "[post-build] WARN:  $*" >&2; }
error() { echo "[post-build] ERROR: $*" >&2; exit 1; }

# =============================================================================
# 1. Docker Compose CLI plugin
# =============================================================================
COMPOSE_PLUGIN_DIR="${TARGET_DIR}/usr/libexec/docker/cli-plugins"
mkdir -p "${COMPOSE_PLUGIN_DIR}"

if [[ ! -f "${COMPOSE_PLUGIN_DIR}/docker-compose" ]]; then
    info "Downloading Docker Compose plugin v${COMPOSE_VERSION}..."
    curl -fsSL "${COMPOSE_URL}" -o "${COMPOSE_PLUGIN_DIR}/docker-compose"
    chmod 0755 "${COMPOSE_PLUGIN_DIR}/docker-compose"
    info "Docker Compose plugin installed."
else
    info "Docker Compose plugin already present."
fi

# =============================================================================
# 2. Pre-saved Docker image tarballs
# =============================================================================
mkdir -p "${PRELOAD_DIR}"

if [[ -d "${DOCKER_IMAGES_SRC}" ]]; then
    shopt -s nullglob
    IMAGE_FILES=("${DOCKER_IMAGES_SRC}"/*.tar "${DOCKER_IMAGES_SRC}"/*.tar.gz)
    shopt -u nullglob

    if (( ${#IMAGE_FILES[@]} > 0 )); then
        info "Staging ${#IMAGE_FILES[@]} Docker image tarball(s) into rootfs..."
        for img in "${IMAGE_FILES[@]}"; do
            BASENAME=$(basename "${img}")
            cp "${img}" "${PRELOAD_DIR}/${BASENAME}"
            info "  → ${BASENAME}  ($(du -sh "${PRELOAD_DIR}/${BASENAME}" | cut -f1))"
        done
    else
        warn "No image tarballs in ${DOCKER_IMAGES_SRC}"
        warn "Expected: asbuiltreport-app.tar.gz  asbuiltreport-worker.tar.gz"
        warn "The VM will need internet access on first boot to pull images."
    fi
else
    warn "docker-images directory not found: ${DOCKER_IMAGES_SRC}"
fi

# =============================================================================
# 3. Bind-mount directories
# =============================================================================
install -d -m 0755 "${TARGET_DIR}/var/www/reports"
install -d -m 0755 "${TARGET_DIR}/etc/asbuiltreport"
install -d -m 0755 "${TARGET_DIR}/var/lib/asbuiltreport/ps-modules"
install -d -m 0755 "${TARGET_DIR}/var/lib/asbuiltreport"

# =============================================================================
# 4. Init script permissions (busybox init requires +x)
# =============================================================================
for script in "${TARGET_DIR}"/etc/init.d/S*; do
    [[ -f "${script}" ]] && chmod 0755 "${script}"
done

chmod 0755 "${TARGET_DIR}"/usr/local/bin/abr-*.sh 2>/dev/null || true

# =============================================================================
# 5. /etc/inittab — busybox init
#    Replaces any default that Buildroot may have written.
# =============================================================================
cat > "${TARGET_DIR}/etc/inittab" <<'EOF'
# /etc/inittab — busybox init

::sysinit:/etc/init.d/rcS

# Respawn management console on tty1
tty1::respawn:/usr/local/bin/abr-console.sh

# Allow root login on ttyS0 (serial console — useful for VMware remote console)
ttyS0::respawn:/sbin/getty -L ttyS0 115200 vt100

# Ctrl-Alt-Del
::ctrlaltdel:/sbin/reboot

# Shutdown actions
::shutdown:/etc/init.d/S40asbuiltreport stop
::shutdown:/etc/init.d/S30docker stop
::shutdown:/sbin/swapoff -a
::shutdown:/bin/umount -a -r
EOF

# =============================================================================
# 6. /etc/init.d/rcS — runs all S* scripts in order
# =============================================================================
cat > "${TARGET_DIR}/etc/init.d/rcS" <<'EOF'
#!/bin/sh
for script in /etc/init.d/S??*; do
    [ -x "$script" ] || continue
    "$script" start
done
EOF
chmod 0755 "${TARGET_DIR}/etc/init.d/rcS"

# =============================================================================
# 7. SSH config
# =============================================================================
mkdir -p "${TARGET_DIR}/etc/ssh"
cat > "${TARGET_DIR}/etc/ssh/sshd_config" <<'EOF'
Port 22
Protocol 2
HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_rsa_key
PermitRootLogin prohibit-password
PasswordAuthentication yes
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
X11Forwarding no
PrintMotd yes
EOF

info "post-build.sh complete."
