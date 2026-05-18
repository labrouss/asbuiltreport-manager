#!/usr/bin/env bash
# =============================================================================
# post-build.sh — AsBuiltReport Manager OVA
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
        info "Staging ${#IMAGE_FILES[@]} Docker image tarball(s)..."
        for img in "${IMAGE_FILES[@]}"; do
            BASENAME=$(basename "${img}")
            cp "${img}" "${PRELOAD_DIR}/${BASENAME}"
            info "  → ${BASENAME}  ($(du -sh "${PRELOAD_DIR}/${BASENAME}" | cut -f1))"
        done
    else
        warn "No image tarballs found in ${DOCKER_IMAGES_SRC}"
    fi
else
    warn "docker-images directory not found: ${DOCKER_IMAGES_SRC}"
fi

# =============================================================================
# 3. Required directories that must exist in the rootfs image
# =============================================================================
# /dev/pts and /dev/shm are listed in fstab but missing from rootfs → mount fails
install -d -m 1777 "${TARGET_DIR}/dev/pts"
install -d -m 1777 "${TARGET_DIR}/dev/shm"
install -d -m 0755 "${TARGET_DIR}/run/network"
install -d -m 0755 "${TARGET_DIR}/var/lib/asbuiltreport"
install -d -m 0755 "${TARGET_DIR}/var/www/reports"
install -d -m 0755 "${TARGET_DIR}/etc/asbuiltreport"
install -d -m 0755 "${TARGET_DIR}/var/lib/asbuiltreport/ps-modules"
install -d -m 0755 "${TARGET_DIR}/var/lib/docker-preload"

# =============================================================================
# 4. Write /etc/fstab with correct mount points
# =============================================================================
cat > "${TARGET_DIR}/etc/fstab" << 'EOF'
# <file system>  <mount pt>   <type>   <options>                       <dump>  <pass>
/dev/sda2        /            ext4     rw,noatime                      0       1
/dev/sda1        /boot/efi    vfat     ro,noauto,umask=0077            0       0
proc             /proc        proc     defaults                         0       0
sysfs            /sys         sysfs    defaults                         0       0
EOF

# Create the EFI mount point
install -d -m 0755 "${TARGET_DIR}/boot/efi"

# =============================================================================
# 5. Write /etc/inittab — busybox init with proper mounts before rcS
# =============================================================================
cat > "${TARGET_DIR}/etc/inittab" << 'EOF'
# /etc/inittab — busybox init

# sysinit: mount filesystems and run S* scripts
::sysinit:/etc/init.d/rcS

# Respawn management console on tty1
tty1::respawn:/usr/local/bin/abr-console.sh

# Serial console on ttyS0
ttyS0::respawn:/sbin/getty -L ttyS0 115200 vt100

# Ctrl-Alt-Del
::ctrlaltdel:/sbin/reboot

# Shutdown
::shutdown:/etc/init.d/S40asbuiltreport stop
::shutdown:/etc/init.d/S30docker stop
::shutdown:/bin/umount -a -r
EOF

# =============================================================================
# 6. Write /etc/init.d/rcS — mounts first, then S* scripts
# =============================================================================
cat > "${TARGET_DIR}/etc/init.d/rcS" << 'EOF'
#!/bin/sh
# Mount critical filesystems before running init scripts
# The root filesystem is mounted read-only by the kernel; remount rw first.
mount -o remount,rw /

# Mount virtual filesystems
mount -t proc     proc     /proc
mount -t sysfs    sysfs    /sys

# devtmpfs replaces /dev entirely — /dev/pts and /dev/shm are hidden
# until we create them on the live devtmpfs after it's mounted
# (devtmpfs is auto-mounted by the kernel at boot since CONFIG_DEVTMPFS_MOUNT=y)
# Create the mount point directories on the live devtmpfs
mkdir -p /dev/pts /dev/shm

# Now mount devpts and tmpfs on top of them
mount -t devpts   devpts   /dev/pts  -o gid=5,mode=620
mount -t tmpfs    tmpfs    /dev/shm  -o mode=1777
mount -t tmpfs    tmpfs    /tmp      -o mode=1777
mount -t tmpfs    tmpfs    /run      -o mode=0755,nosuid,nodev

# Run S* init scripts in order
for script in /etc/init.d/S??*; do
    [ -x "$script" ] || continue
    "$script" start
done
EOF
chmod 0755 "${TARGET_DIR}/etc/init.d/rcS"

# =============================================================================
# 7. Init script permissions
# =============================================================================
for script in "${TARGET_DIR}"/etc/init.d/S*; do
    [[ -f "${script}" ]] && chmod 0755 "${script}"
done
chmod 0755 "${TARGET_DIR}"/usr/local/bin/abr-*.sh 2>/dev/null || true

# =============================================================================
# 8. Remove duplicate/conflicting init scripts that Buildroot may have added
#    from other packages (openssh, docker-engine add their own S* scripts
#    which conflict with ours)
# =============================================================================
# Keep only our scripts — remove any that Buildroot packages auto-install
for unwanted in \
    "${TARGET_DIR}/etc/init.d/S40network" \
    "${TARGET_DIR}/etc/init.d/S60dockerd" \
    "${TARGET_DIR}/etc/init.d/S50sshd"
do
    if [[ -f "${unwanted}" ]]; then
        info "Removing conflicting init script: $(basename ${unwanted})"
        rm -f "${unwanted}"
    fi
done

info "post-build.sh complete."
