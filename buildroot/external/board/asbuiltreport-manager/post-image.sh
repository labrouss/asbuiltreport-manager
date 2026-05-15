#!/usr/bin/env bash
# =============================================================================
# post-image.sh — AsBuiltReport Manager OVA
#
# Called by Buildroot after all filesystem images have been generated.
# This script:
#   1. Runs genimage to create the final disk VMDK
#   2. Converts the raw image to VMDK (stream-optimised, VMware-compatible)
#   3. Generates the OVF descriptor from a template
#   4. Packages everything into a .ova file (tar)
#
# Requires on build host: genimage, qemu-img, tar
# =============================================================================
set -euo pipefail

BINARIES_DIR="${BINARIES_DIR:?not set}"
BUILD_DIR="${BUILD_DIR:?not set}"
EXTERNAL="${BR2_EXTERNAL_ASBUILTREPORT_MANAGER_PATH:?not set}"

APPLIANCE_NAME="asbuiltreport-manager"
VERSION="1.0.0"
OVA_OUT="${BINARIES_DIR}/${APPLIANCE_NAME}-v${VERSION}.ova"
GENIMAGE_CFG="${EXTERNAL}/board/asbuiltreport-manager/genimage.cfg"
OVF_TEMPLATE="${EXTERNAL}/board/asbuiltreport-manager/asbuiltreport-manager.ovf.template"

info()  { echo "[post-image] INFO:  $*"; }
error() { echo "[post-image] ERROR: $*" >&2; exit 1; }

GENIMAGE_TMP="${BUILD_DIR}/genimage.tmp"
rm -rf "${GENIMAGE_TMP}"

# =============================================================================
# 1. Generate raw disk image via genimage
# =============================================================================
info "Running genimage…"
genimage \
    --rootpath   "${TARGET_DIR}" \
    --tmppath    "${GENIMAGE_TMP}" \
    --inputpath  "${BINARIES_DIR}" \
    --outputpath "${BINARIES_DIR}" \
    --config     "${GENIMAGE_CFG}"

RAW_IMG="${BINARIES_DIR}/${APPLIANCE_NAME}.img"
[[ -f "${RAW_IMG}" ]] || error "genimage did not produce ${RAW_IMG}"

# =============================================================================
# 2. Convert raw → VMDK (stream-optimised, compatible with ESXi / Workstation)
# =============================================================================
VMDK="${BINARIES_DIR}/${APPLIANCE_NAME}-disk1.vmdk"
info "Converting disk image to VMDK (stream-optimised)…"
qemu-img convert \
    -f raw \
    -O vmdk \
    -o subformat=streamOptimized,adapter_type=lsilogic,compat6 \
    "${RAW_IMG}" \
    "${VMDK}"

DISK_SIZE_BYTES=$(qemu-img info --output=json "${VMDK}" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d['virtual-size'])")
DISK_SIZE_GIB=$(( DISK_SIZE_BYTES / 1073741824 ))
DISK_CAPACITY_SECTORS=$(( DISK_SIZE_BYTES / 512 ))
VMDK_SIZE_BYTES=$(stat -c %s "${VMDK}")

info "VMDK: virtual=${DISK_SIZE_GIB} GiB  file=${VMDK_SIZE_BYTES} bytes"

# =============================================================================
# 3. Generate OVF descriptor from template
# =============================================================================
OVF_OUT="${BINARIES_DIR}/${APPLIANCE_NAME}.ovf"
VMDK_BASENAME=$(basename "${VMDK}")

# Compute SHA256 for the manifest
VMDK_SHA256=$(sha256sum "${VMDK}" | awk '{print $1}')
OVF_SHA256=""   # computed after OVF is rendered

info "Rendering OVF descriptor…"
sed \
    -e "s|@@APPLIANCE_NAME@@|${APPLIANCE_NAME}|g" \
    -e "s|@@VERSION@@|${VERSION}|g" \
    -e "s|@@VMDK_FILENAME@@|${VMDK_BASENAME}|g" \
    -e "s|@@DISK_CAPACITY_SECTORS@@|${DISK_CAPACITY_SECTORS}|g" \
    -e "s|@@VMDK_SIZE_BYTES@@|${VMDK_SIZE_BYTES}|g" \
    -e "s|@@DISK_SIZE_GIB@@|${DISK_SIZE_GIB}|g" \
    "${OVF_TEMPLATE}" > "${OVF_OUT}"

OVF_SHA256=$(sha256sum "${OVF_OUT}" | awk '{print $1}')

# =============================================================================
# 4. Write manifest (.mf)
# =============================================================================
MF_OUT="${BINARIES_DIR}/${APPLIANCE_NAME}.mf"
{
    echo "SHA256(${APPLIANCE_NAME}.ovf)= ${OVF_SHA256}"
    echo "SHA256(${VMDK_BASENAME})= ${VMDK_SHA256}"
} > "${MF_OUT}"

# =============================================================================
# 5. Package OVA (tar, OVF first as required by the spec)
# =============================================================================
info "Packaging OVA: ${OVA_OUT}"
cd "${BINARIES_DIR}"
tar -cf "${OVA_OUT}" \
    "${APPLIANCE_NAME}.ovf" \
    "${APPLIANCE_NAME}.mf" \
    "${VMDK_BASENAME}"

OVA_SIZE=$(du -sh "${OVA_OUT}" | cut -f1)
OVA_SHA256=$(sha256sum "${OVA_OUT}" | awk '{print $1}')

info "────────────────────────────────────────────────────────"
info " OVA ready: ${OVA_OUT}"
info " Size:      ${OVA_SIZE}"
info " SHA256:    ${OVA_SHA256}"
info "────────────────────────────────────────────────────────"

# Write checksum file next to the OVA
echo "${OVA_SHA256}  ${APPLIANCE_NAME}-v${VERSION}.ova" \
    > "${BINARIES_DIR}/${APPLIANCE_NAME}-v${VERSION}.ova.sha256"
