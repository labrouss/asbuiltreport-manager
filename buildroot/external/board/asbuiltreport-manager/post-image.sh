#!/usr/bin/env bash
# =============================================================================
# post-image.sh — AsBuiltReport Manager OVA
#
# Runs after all Buildroot filesystem images are written.
# Mirrors san-manager post-image.sh pattern.
#
# Steps:
#   1. genimage  → raw GPT disk image  (asbuiltreport-manager.img)
#   2. qemu-img  → stream-optimised VMDK
#   3. Render OVF template → .ovf
#   4. SHA256 manifest → .mf
#   5. tar(ovf + mf + vmdk) → .ova
# =============================================================================
set -euo pipefail

BINARIES_DIR="${BINARIES_DIR:?}"
BUILD_DIR="${BUILD_DIR:?}"
EXTERNAL="${BR2_EXTERNAL_ASBUILTREPORT_MANAGER_PATH:?}"

APPLIANCE_NAME="asbuiltreport-manager"
VERSION="1.0.0"
OVA_OUT="${BINARIES_DIR}/${APPLIANCE_NAME}-v${VERSION}.ova"
GENIMAGE_CFG="${EXTERNAL}/board/asbuiltreport-manager/genimage.cfg"
OVF_TEMPLATE="${EXTERNAL}/board/asbuiltreport-manager/asbuiltreport-manager.ovf.template"

info()  { echo "[post-image] INFO:  $*"; }
warn()  { echo "[post-image] WARN:  $*" >&2; }
error() { echo "[post-image] ERROR: $*" >&2; exit 1; }

GENIMAGE_TMP="${BUILD_DIR}/genimage.tmp"
rm -rf "${GENIMAGE_TMP}"

# =============================================================================
# 0. Install our grub.cfg into the efi-part directory that Buildroot's
#    GRUB2 package created. This must happen before genimage runs so that
#    genimage finds the file when it builds boot.vfat.
#    Buildroot writes:  output/images/efi-part/EFI/BOOT/bootx64.efi
#                       output/images/efi-part/EFI/BOOT/grub.cfg  (default)
#    We overwrite the default grub.cfg with our own.
# =============================================================================
EFI_BOOT_DIR="${BINARIES_DIR}/efi-part/EFI/BOOT"
GRUB_CFG_SRC="${EXTERNAL}/board/asbuiltreport-manager/grub.cfg"

if [[ ! -d "${EFI_BOOT_DIR}" ]]; then
    error "GRUB2 EFI output directory not found: ${EFI_BOOT_DIR}"
    error "Ensure BR2_TARGET_GRUB2_X86_64_EFI=y is set in the defconfig."
fi

if [[ -f "${GRUB_CFG_SRC}" ]]; then
    info "Installing grub.cfg → ${EFI_BOOT_DIR}/grub.cfg"
    cp "${GRUB_CFG_SRC}" "${EFI_BOOT_DIR}/grub.cfg"
else
    warn "No custom grub.cfg found at ${GRUB_CFG_SRC} — using Buildroot default."
fi

info "EFI boot directory contents:"
ls -lh "${EFI_BOOT_DIR}/"

# =============================================================================
# 1. genimage → raw GPT disk image
# =============================================================================
info "Running genimage..."
# Buildroot exports TARGET_DIR to post-image.sh via the environment.
genimage \
    --rootpath   "${TARGET_DIR:-${BINARIES_DIR}/../target}" \
    --tmppath    "${GENIMAGE_TMP}" \
    --inputpath  "${BINARIES_DIR}" \
    --outputpath "${BINARIES_DIR}" \
    --config     "${GENIMAGE_CFG}"

RAW_IMG="${BINARIES_DIR}/${APPLIANCE_NAME}.img"
[[ -f "${RAW_IMG}" ]] || error "genimage did not produce ${RAW_IMG}"
info "Raw image: $(du -sh "${RAW_IMG}" | cut -f1)"

# =============================================================================
# 2. qemu-img → stream-optimised VMDK
# =============================================================================
VMDK="${BINARIES_DIR}/${APPLIANCE_NAME}-disk1.vmdk"
info "Converting to stream-optimised VMDK..."
qemu-img convert \
    -f raw \
    -O vmdk \
    -o subformat=streamOptimized,adapter_type=lsilogic \
    "${RAW_IMG}" \
    "${VMDK}"

DISK_SIZE_BYTES=$(qemu-img info --output=json "${VMDK}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['virtual-size'])")
DISK_SIZE_GIB=$(( DISK_SIZE_BYTES / 1073741824 ))
DISK_CAPACITY_SECTORS=$(( DISK_SIZE_BYTES / 512 ))
VMDK_SIZE_BYTES=$(stat -c %s "${VMDK}")
VMDK_BASENAME=$(basename "${VMDK}")

info "VMDK: virtual=${DISK_SIZE_GIB}GiB  file=${VMDK_SIZE_BYTES}B"

# =============================================================================
# 3. OVF descriptor
# =============================================================================
OVF_OUT="${BINARIES_DIR}/${APPLIANCE_NAME}.ovf"
info "Rendering OVF descriptor..."
sed \
    -e "s|@@APPLIANCE_NAME@@|${APPLIANCE_NAME}|g" \
    -e "s|@@VERSION@@|${VERSION}|g" \
    -e "s|@@VMDK_FILENAME@@|${VMDK_BASENAME}|g" \
    -e "s|@@DISK_CAPACITY_SECTORS@@|${DISK_CAPACITY_SECTORS}|g" \
    -e "s|@@VMDK_SIZE_BYTES@@|${VMDK_SIZE_BYTES}|g" \
    -e "s|@@DISK_SIZE_GIB@@|${DISK_SIZE_GIB}|g" \
    "${OVF_TEMPLATE}" > "${OVF_OUT}"

# =============================================================================
# 4. Manifest
# =============================================================================
MF_OUT="${BINARIES_DIR}/${APPLIANCE_NAME}.mf"
OVF_SHA256=$(sha256sum "${OVF_OUT}" | awk '{print $1}')
VMDK_SHA256=$(sha256sum "${VMDK}"   | awk '{print $1}')
{
    echo "SHA256(${APPLIANCE_NAME}.ovf)= ${OVF_SHA256}"
    echo "SHA256(${VMDK_BASENAME})= ${VMDK_SHA256}"
} > "${MF_OUT}"

# =============================================================================
# 5. Package OVA (OVF spec requires .ovf first in the tar)
# =============================================================================
info "Packaging OVA: ${OVA_OUT}"
cd "${BINARIES_DIR}"
tar -cf "${OVA_OUT}" \
    "${APPLIANCE_NAME}.ovf" \
    "${APPLIANCE_NAME}.mf" \
    "${VMDK_BASENAME}"

OVA_SHA256=$(sha256sum "${OVA_OUT}" | awk '{print $1}')
OVA_SIZE=$(du -sh "${OVA_OUT}" | cut -f1)
echo "${OVA_SHA256}  ${APPLIANCE_NAME}-v${VERSION}.ova" \
    > "${BINARIES_DIR}/${APPLIANCE_NAME}-v${VERSION}.ova.sha256"

info "────────────────────────────────────────────────────────"
info " OVA:    ${OVA_OUT}"
info " Size:   ${OVA_SIZE}"
info " SHA256: ${OVA_SHA256}"
info "────────────────────────────────────────────────────────"
