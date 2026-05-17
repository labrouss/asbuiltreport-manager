#!/usr/bin/env bash
# =============================================================================
# post-image.sh — AsBuiltReport Manager OVA
#
# Mirrors san-manager/post-image.sh exactly. Three tasks:
#
#  1. Build bootx64.efi using grub-mkstandalone with all required modules
#     baked in from Buildroot's own grub2 build output. This is necessary
#     because Buildroot's default bootx64.efi (~608 KB) is built with
#     BR2_TARGET_GRUB2_BUILTIN_MODULES_EFI which does NOT include the
#     'linux' command — so it cannot load a kernel. grub-mkstandalone
#     produces a fully self-contained binary (several MB) that includes
#     every module needed to boot.
#
#  2. Inject bzImage into rootfs.ext4 at /boot/bzImage using debugfs.
#     GRUB reads the kernel from the root filesystem, not the EFI partition.
#
#  3. Run genimage to assemble the final disk image.
#
#  4. Convert disk.img → monolithicSparse VMDK → OVA.
#
# Buildroot exports: BINARIES_DIR, TARGET_DIR, BUILD_DIR
# =============================================================================
set -euo pipefail

: "${BINARIES_DIR:?BINARIES_DIR not set}"
: "${TARGET_DIR:?TARGET_DIR not set}"
: "${BUILD_DIR:?BUILD_DIR not set}"

EXTERNAL="${BR2_EXTERNAL_ASBUILTREPORT_MANAGER_PATH:?}"
SCRIPT_DIR="${EXTERNAL}/board/asbuiltreport-manager"
GENIMAGE_TMP="${BUILD_DIR}/genimage.tmp"

APPLIANCE_NAME="asbuiltreport-manager"
VERSION="1.0.0"

log() { echo "[post-image] INFO:  $*"; }
warn() { echo "[post-image] WARN:  $*" >&2; }
die() { echo "[post-image] ERROR: $*" >&2; exit 1; }

log "=== BINARIES_DIR contents ==="
find "${BINARIES_DIR}" -maxdepth 2 | sort
log "==="

# ── Prerequisites ─────────────────────────────────────────────────────────────
[ -f "${BINARIES_DIR}/rootfs.ext2" ] || die "rootfs.ext2 missing from ${BINARIES_DIR}"
[ -f "${BINARIES_DIR}/bzImage" ]     || die "bzImage missing from ${BINARIES_DIR}"

# rootfs.ext4 is a symlink → rootfs.ext2 created by Buildroot; ensure it exists
[ -f "${BINARIES_DIR}/rootfs.ext4" ] || \
    ln -sf rootfs.ext2 "${BINARIES_DIR}/rootfs.ext4"

# ── Step 1: Build bootx64.efi with grub-mkstandalone ──────────────────────────
# Find Buildroot's grub2 build directory and module output
GRUB_BUILD_DIR=$(find "${BUILD_DIR}" -maxdepth 1 -name "grub2-*" -type d | head -1)
[ -n "${GRUB_BUILD_DIR}" ] || die "grub2 build dir not found in ${BUILD_DIR}"

GRUB_MODDIR="${GRUB_BUILD_DIR}/build-x86_64-efi/grub-core"
[ -d "${GRUB_MODDIR}" ] || die "GRUB2 module dir not found: ${GRUB_MODDIR}"

GRUB_MKSTANDALONE="${BUILD_DIR}/../host/bin/grub-mkstandalone"
[ -f "${GRUB_MKSTANDALONE}" ] || die "grub-mkstandalone not found at ${GRUB_MKSTANDALONE}"

GRUB_CFG_SRC="${SCRIPT_DIR}/grub.cfg"
[ -f "${GRUB_CFG_SRC}" ] || die "grub.cfg not found at ${GRUB_CFG_SRC}"

EFI_BOOT_DIR="${BINARIES_DIR}/efi-part/EFI/BOOT"
mkdir -p "${EFI_BOOT_DIR}"

log "Building bootx64.efi with grub-mkstandalone..."
log "  Module dir: ${GRUB_MODDIR}"
log "  grub.cfg:   ${GRUB_CFG_SRC}"

"${GRUB_MKSTANDALONE}" \
    --format=x86_64-efi \
    --directory="${GRUB_MODDIR}" \
    --modules="boot linux part_gpt part_msdos fat ext2 normal echo configfile \
               search search_fs_uuid search_fs_file search_label ls cat \
               reboot halt gfxterm font video all_video serial" \
    --output="${EFI_BOOT_DIR}/bootx64.efi" \
    "boot/grub/grub.cfg=${GRUB_CFG_SRC}"

EFI_SIZE=$(stat -c '%s' "${EFI_BOOT_DIR}/bootx64.efi")
log "bootx64.efi: $(numfmt --to=iec "${EFI_SIZE}") — should be several MB, not ~608KB"

# Verify the linux command is present in the binary
if strings "${EFI_BOOT_DIR}/bootx64.efi" | grep -q "^linux$"; then
    log "✓ 'linux' command confirmed in bootx64.efi"
else
    warn "'linux' command not found in bootx64.efi strings — boot may fail"
fi

# ── Step 2: Inject bzImage into rootfs.ext4 at /boot/bzImage ──────────────────
# GRUB loads the kernel from the root filesystem, not the EFI partition.
# debugfs writes directly into the ext4 image without mounting it.
log "Injecting bzImage into rootfs.ext4 at /boot/bzImage..."

if debugfs -R "stat /boot/bzImage" "${BINARIES_DIR}/rootfs.ext4" 2>/dev/null \
        | grep -q "Type: regular"; then
    log "bzImage already present in rootfs.ext4 — overwriting..."
fi

debugfs -w -R "mkdir /boot" "${BINARIES_DIR}/rootfs.ext4" 2>/dev/null || true
debugfs -w -R "write ${BINARIES_DIR}/bzImage /boot/bzImage" \
    "${BINARIES_DIR}/rootfs.ext4"
log "bzImage injected ($(du -sh "${BINARIES_DIR}/bzImage" | cut -f1))"

# Verify injection
if debugfs -R "stat /boot/bzImage" "${BINARIES_DIR}/rootfs.ext4" 2>/dev/null \
        | grep -q "Type: regular"; then
    log "✓ /boot/bzImage verified in rootfs.ext4"
else
    die "/boot/bzImage injection failed — kernel will not be found at boot"
fi

# ── Step 3: genimage → raw disk image ─────────────────────────────────────────
rm -rf "${GENIMAGE_TMP}"
log "Running genimage..."
genimage \
    --config     "${SCRIPT_DIR}/genimage.cfg" \
    --rootpath   "${TARGET_DIR}" \
    --tmppath    "${GENIMAGE_TMP}" \
    --inputpath  "${BINARIES_DIR}" \
    --outputpath "${BINARIES_DIR}"

RAW_IMG="${BINARIES_DIR}/${APPLIANCE_NAME}.img"
[ -f "${RAW_IMG}" ] || die "genimage did not produce ${APPLIANCE_NAME}.img"

RAW_SIZE_BYTES=$(stat -c %s "${RAW_IMG}")
log "Raw image: $(du -sh "${RAW_IMG}" | cut -f1)  (${RAW_SIZE_BYTES} bytes)"

# ── Step 4: Convert to streamOptimized VMDK ───────────────────────────────────
VMDK="${BINARIES_DIR}/${APPLIANCE_NAME}-disk1.vmdk"
log "Converting raw → streamOptimized VMDK..."
qemu-img convert \
    -f raw \
    -O vmdk \
    -o subformat=streamOptimized \
    "${RAW_IMG}" \
    "${VMDK}"

[ -f "${VMDK}" ] || die "qemu-img did not produce VMDK"
VMDK_SIZE_BYTES=$(stat -c %s "${VMDK}")
[ "${VMDK_SIZE_BYTES}" -gt 0 ] || die "VMDK is empty"

# The raw image is ~6.5 GB (6 GB rootfs + 512 MB EFI).
# The OVF must declare the VIRTUAL size as 40 GB — this is what vCenter
# provisions on the datastore as a thin disk. The VM's resize2fs script
# expands the ext4 filesystem into the remaining space on first boot.
# We override the capacity to 40 GiB rather than using the raw image size.
DISK_SIZE_GIB=40
DISK_SIZE_BYTES=$(( DISK_SIZE_GIB * 1024 * 1024 * 1024 ))
DISK_CAPACITY_SECTORS=$(( DISK_SIZE_BYTES / 512 ))
VMDK_BASENAME=$(basename "${VMDK}")
log "VMDK: virtual=${DISK_SIZE_GIB} GiB (declared to vCenter)  file=${VMDK_SIZE_BYTES} bytes (actual)"

# ── Step 5: OVF descriptor ─────────────────────────────────────────────────────
OVF_TEMPLATE="${EXTERNAL}/board/asbuiltreport-manager/asbuiltreport-manager.ovf.template"
OVF_OUT="${BINARIES_DIR}/${APPLIANCE_NAME}.ovf"
log "Rendering OVF descriptor..."
sed \
    -e "s|@@APPLIANCE_NAME@@|${APPLIANCE_NAME}|g" \
    -e "s|@@VERSION@@|${VERSION}|g" \
    -e "s|@@VMDK_FILENAME@@|${VMDK_BASENAME}|g" \
    -e "s|@@DISK_SIZE_BYTES@@|${DISK_SIZE_BYTES}|g" \
    -e "s|@@VMDK_SIZE_BYTES@@|${VMDK_SIZE_BYTES}|g" \
    -e "s|@@DISK_CAPACITY_SECTORS@@|${DISK_CAPACITY_SECTORS}|g" \
    -e "s|@@DISK_SIZE_GIB@@|${DISK_SIZE_GIB}|g" \
    "${OVF_TEMPLATE}" > "${OVF_OUT}"

# ── Step 6: Manifest ──────────────────────────────────────────────────────────
MF_OUT="${BINARIES_DIR}/${APPLIANCE_NAME}.mf"
OVF_SHA256=$(sha256sum "${OVF_OUT}" | awk '{print $1}')
VMDK_SHA256=$(sha256sum "${VMDK}"   | awk '{print $1}')
{
    echo "SHA256(${APPLIANCE_NAME}.ovf)= ${OVF_SHA256}"
    echo "SHA256(${VMDK_BASENAME})= ${VMDK_SHA256}"
} > "${MF_OUT}"

# ── Step 7: Package OVA ───────────────────────────────────────────────────────
OVA_OUT="${BINARIES_DIR}/${APPLIANCE_NAME}-v${VERSION}.ova"
log "Packaging OVA: ${OVA_OUT}"
rm -f "${OVA_OUT}"
cd "${BINARIES_DIR}"
# CRITICAL: --format=ustar prevents GNU tar extensions that break VMware's parser.
# --numeric-owner --owner=0 --group=0 prevents UID/GID strings confusing vCenter.
# Member order: ovf → mf → vmdk (OVF spec requires descriptor first).
tar --format=ustar \
    --numeric-owner \
    --owner=0 --group=0 \
    -cf "${OVA_OUT}" \
    "${APPLIANCE_NAME}.ovf" \
    "${APPLIANCE_NAME}.mf" \
    "${VMDK_BASENAME}"

OVA_SIZE_BYTES=$(stat -c %s "${OVA_OUT}")
[ "${OVA_SIZE_BYTES}" -gt "${VMDK_SIZE_BYTES}" ] \
    || die "OVA smaller than VMDK — packaging failed"

OVA_SHA256=$(sha256sum "${OVA_OUT}" | awk '{print $1}')
echo "${OVA_SHA256}  ${APPLIANCE_NAME}-v${VERSION}.ova" \
    > "${BINARIES_DIR}/${APPLIANCE_NAME}-v${VERSION}.ova.sha256"

log "OVA contents:"
tar -tvf "${OVA_OUT}"

log "────────────────────────────────────────────────────────────"
log " OVA:    ${OVA_OUT}"
log " Size:   $(du -sh "${OVA_OUT}" | cut -f1)"
log " SHA256: ${OVA_SHA256}"
log "────────────────────────────────────────────────────────────"
