#!/usr/bin/env bash
# =============================================================================
# post-image.sh — AsBuiltReport Manager OVA
#
# Steps:
#   0. Install grub.cfg into efi-part/
#   1. genimage   → raw GPT disk image (.img)
#   2. qemu-img   → monolithic flat VMDK  (NOT stream-optimised)
#   3. Render OVF → .ovf  (disk sizes taken from the flat VMDK)
#   4. SHA256 manifest → .mf
#   5. tar(ovf + mf + vmdk) → .ova
#
# VMDK format choice — ESXi compatibility matrix:
#   streamOptimized  → transport-only; ESXi cannot attach/clone directly.
#                      Requires ovftool to convert after import. AVOID.
#   monolithicFlat   → single flat .vmdk + descriptor file; ESXi attaches
#                      natively but OVA packaging requires both files. AVOID.
#   monolithicSparse → single self-contained .vmdk; ESXi attaches natively,
#                      ovftool-compatible, accepted by vCenter OVF import. USE.
#
# We use monolithicSparse (subformat=monolithicSparse in qemu-img).
# vCenter accepts this for OVF import and ESXi can attach/clone it directly.
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
# 0. Install our grub.cfg into the efi-part/ directory
# =============================================================================
EFI_BOOT_DIR="${BINARIES_DIR}/efi-part/EFI/BOOT"
GRUB_CFG_SRC="${EXTERNAL}/board/asbuiltreport-manager/grub.cfg"

[[ -d "${EFI_BOOT_DIR}" ]] \
    || error "GRUB2 EFI output dir not found: ${EFI_BOOT_DIR}"

if [[ -f "${GRUB_CFG_SRC}" ]]; then
    cp "${GRUB_CFG_SRC}" "${EFI_BOOT_DIR}/grub.cfg"
    info "grub.cfg installed → ${EFI_BOOT_DIR}/grub.cfg"
else
    warn "No custom grub.cfg — using Buildroot default."
fi
ls -lh "${EFI_BOOT_DIR}/"

# =============================================================================
# 1. genimage → raw GPT disk image
# =============================================================================
info "Running genimage..."
genimage \
    --rootpath   "${TARGET_DIR:-${BINARIES_DIR}/../target}" \
    --tmppath    "${GENIMAGE_TMP}" \
    --inputpath  "${BINARIES_DIR}" \
    --outputpath "${BINARIES_DIR}" \
    --config     "${GENIMAGE_CFG}"

RAW_IMG="${BINARIES_DIR}/${APPLIANCE_NAME}.img"
[[ -f "${RAW_IMG}" ]] || error "genimage did not produce ${RAW_IMG}"
RAW_SIZE_BYTES=$(stat -c %s "${RAW_IMG}")
info "Raw image: $(du -sh "${RAW_IMG}" | cut -f1)  (${RAW_SIZE_BYTES} bytes)"

# =============================================================================
# 2. qemu-img → monolithicSparse VMDK
#
# monolithicSparse is a single self-contained VMDK file that:
#   - vCenter accepts for OVF/OVA import  (unlike streamOptimized which
#     vCenter's transfer layer often rejects for large disks)
#   - ESXi can attach and clone directly  (unlike streamOptimized)
#   - Is sparse so only allocated blocks occupy space on the datastore
#
# adapter_type=lsilogic matches the SCSI controller declared in the OVF.
# hwversion=8 is the minimum that vSphere 6.x/7.x/8.x all accept.
# =============================================================================
VMDK="${BINARIES_DIR}/${APPLIANCE_NAME}-disk1.vmdk"
info "Converting raw → monolithicSparse VMDK..."
qemu-img convert \
    -f raw \
    -O vmdk \
    -o subformat=monolithicSparse,adapter_type=lsilogic,hwversion=17 \
    "${RAW_IMG}" \
    "${VMDK}"

# Verify the VMDK was written completely
[[ -f "${VMDK}" ]] || error "qemu-img did not produce ${VMDK}"

VMDK_SIZE_BYTES=$(stat -c %s "${VMDK}")
[[ "${VMDK_SIZE_BYTES}" -gt 0 ]] || error "VMDK is empty — conversion failed"

# Read virtual size from the raw image (not the VMDK — avoids sparse confusion)
DISK_SIZE_BYTES=${RAW_SIZE_BYTES}
DISK_SIZE_GIB=$(( DISK_SIZE_BYTES / 1073741824 ))
DISK_CAPACITY_SECTORS=$(( DISK_SIZE_BYTES / 512 ))
VMDK_BASENAME=$(basename "${VMDK}")

info "VMDK: virtual=${DISK_SIZE_GIB} GiB  sectors=${DISK_CAPACITY_SECTORS}  file=${VMDK_SIZE_BYTES} bytes"

# Sanity check: virtual size must be at least what genimage was asked for
EXPECTED_MIN_GIB=39
if [[ "${DISK_SIZE_GIB}" -lt "${EXPECTED_MIN_GIB}" ]]; then
    error "VMDK virtual size (${DISK_SIZE_GIB} GiB) is smaller than expected (${EXPECTED_MIN_GIB} GiB). Conversion may have failed."
fi

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
# 5. Package OVA
#
# OVF spec (DSP0243): the OVF descriptor file MUST be the first file in the
# tar archive. Use --format=ustar (POSIX tar, no GNU extensions) for maximum
# compatibility with vCenter's OVA parser.
# =============================================================================
info "Packaging OVA: ${OVA_OUT}"
rm -f "${OVA_OUT}"
cd "${BINARIES_DIR}"
tar \
    --format=ustar \
    -cf "${OVA_OUT}" \
    "${APPLIANCE_NAME}.ovf" \
    "${APPLIANCE_NAME}.mf" \
    "${VMDK_BASENAME}"

# Verify the OVA tar is not empty and the VMDK is inside
OVA_SIZE_BYTES=$(stat -c %s "${OVA_OUT}")
[[ "${OVA_SIZE_BYTES}" -gt "${VMDK_SIZE_BYTES}" ]] \
    || error "OVA (${OVA_SIZE_BYTES} bytes) is smaller than the VMDK (${VMDK_SIZE_BYTES} bytes) — packaging failed."

info "OVA contents:"
tar -tvf "${OVA_OUT}"

OVA_SHA256=$(sha256sum "${OVA_OUT}" | awk '{print $1}')
OVA_SIZE=$(du -sh "${OVA_OUT}" | cut -f1)
echo "${OVA_SHA256}  ${APPLIANCE_NAME}-v${VERSION}.ova" \
    > "${BINARIES_DIR}/${APPLIANCE_NAME}-v${VERSION}.ova.sha256"

info "────────────────────────────────────────────────────────────"
info " OVA:    ${OVA_OUT}"
info " Size:   ${OVA_SIZE}"
info " SHA256: ${OVA_SHA256}"
info "────────────────────────────────────────────────────────────"
