#!/bin/bash
# =============================================================================
# abr-ovf-init.sh — OVF Property Initialisation
#
# Reads guestinfo.* variables injected by VMware at deploy-time, then:
#   - Sets the hostname
#   - Writes a systemd-networkd .network file (static or DHCP)
#   - Sets the root password
#   - Installs the SSH authorised key
#   - Marks itself done so it never runs again
#
# VMware provides OVF properties via VMware Tools as:
#   /sys/class/dmi/id/product_serial  (not used)
#   vmware-rpctool "info-get guestinfo.<key>"
#
# Fallback: if vmware-rpctool is absent (VirtualBox / KVM), the script
# reads from a plain-text /media/cdrom/ovf-env.xml (ISO transport).
# =============================================================================
set -euo pipefail

SENTINEL="/var/lib/asbuiltreport/.ovf-init-done"
NETWORKD_DIR="/etc/systemd/network"
LOG_TAG="abr-ovf-init"

log()  { echo "${LOG_TAG}: $*"; logger -t "${LOG_TAG}" "$*"; }
warn() { echo "${LOG_TAG}: WARN: $*" >&2; logger -p user.warning -t "${LOG_TAG}" "$*"; }

# ── Read a guestinfo property ────────────────────────────────────────────────
get_guestinfo() {
    local key="$1"
    local value=""

    # Method 1: vmware-rpctool (VMware Tools / open-vm-tools)
    if command -v vmware-rpctool &>/dev/null; then
        value=$(vmware-rpctool "info-get guestinfo.${key}" 2>/dev/null || true)
    fi

    # Method 2: VMware backdoor via /proc/acpi/dsdt is not reliable;
    # use the OVF XML transport as fallback (ISO mounted at /media/cdrom)
    if [[ -z "${value}" ]] && [[ -f /media/cdrom/ovf-env.xml ]]; then
        value=$(grep -oP "(?<=key=\"${key}\" value=\")[^\"]*" \
                    /media/cdrom/ovf-env.xml 2>/dev/null || true)
        # Also try the oe:value variant
        if [[ -z "${value}" ]]; then
            value=$(python3 -c "
import xml.etree.ElementTree as ET, sys
tree = ET.parse('/media/cdrom/ovf-env.xml')
ns = {'oe': 'http://schemas.dmtf.org/ovf/environment/1'}
for p in tree.findall('.//oe:Property', ns):
    if p.get('{http://schemas.dmtf.org/ovf/environment/1}key') == '${key}':
        print(p.get('{http://schemas.dmtf.org/ovf/environment/1}value', ''))
" 2>/dev/null || true)
        fi
    fi

    echo "${value:-}"
}

# =============================================================================
# 1. Hostname
# =============================================================================
HOSTNAME=$(get_guestinfo hostname)
HOSTNAME="${HOSTNAME:-asbuiltreport-manager}"
# Sanitise
HOSTNAME=$(echo "${HOSTNAME}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9.-]/-/g')

log "Setting hostname: ${HOSTNAME}"
echo "${HOSTNAME}" > /etc/hostname
hostname "${HOSTNAME}"

# /etc/hosts update
if ! grep -q "127.0.1.1" /etc/hosts; then
    echo "127.0.1.1  ${HOSTNAME}" >> /etc/hosts
else
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${HOSTNAME}/" /etc/hosts
fi

# =============================================================================
# 2. Network configuration (systemd-networkd)
# =============================================================================
IP_CIDR=$(get_guestinfo ipaddress)
GATEWAY=$(get_guestinfo gateway)
DNS_SERVERS=$(get_guestinfo dns)
DNS_SERVERS="${DNS_SERVERS:-8.8.8.8 8.8.4.4}"

mkdir -p "${NETWORKD_DIR}"

if [[ -n "${IP_CIDR}" ]]; then
    log "Configuring static IP: ${IP_CIDR}  GW: ${GATEWAY}  DNS: ${DNS_SERVERS}"

    # Convert space-separated DNS to DNS= lines
    DNS_LINES=""
    for dns in ${DNS_SERVERS}; do
        DNS_LINES="${DNS_LINES}DNS=${dns}\n"
    done

    cat > "${NETWORKD_DIR}/10-eth.network" <<EOF
[Match]
Name=en* eth*

[Network]
Address=${IP_CIDR}
Gateway=${GATEWAY}
$(printf "%b" "${DNS_LINES}")
LinkLocalAddressing=no

[DHCP]
UseDNS=no
EOF

else
    log "No static IP provided — configuring DHCP"
    cat > "${NETWORKD_DIR}/10-eth.network" <<EOF
[Match]
Name=en* eth*

[Network]
DHCP=yes
DNS=
IPv6AcceptRA=no

[DHCP]
UseDNS=yes
UseDomains=yes
SendHostname=yes
Hostname=${HOSTNAME}
EOF
fi

# =============================================================================
# 3. Root password
# =============================================================================
ROOT_PASS=$(get_guestinfo password)
if [[ -n "${ROOT_PASS}" ]]; then
    log "Setting root password from OVF property"
    echo "root:${ROOT_PASS}" | chpasswd
else
    log "No root password in OVF properties — locking root password, SSH key auth only"
    passwd -l root 2>/dev/null || true
fi

# =============================================================================
# 4. SSH authorised key
# =============================================================================
SSH_KEY=$(get_guestinfo ssh_authorized_key)
if [[ -n "${SSH_KEY}" ]]; then
    log "Installing SSH authorised key for root"
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    echo "${SSH_KEY}" >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
fi

# Ensure sshd host keys exist
if [[ ! -f /etc/ssh/ssh_host_ed25519_key ]]; then
    log "Generating SSH host keys"
    ssh-keygen -A
fi

# =============================================================================
# 5. Write sentinel
# =============================================================================
mkdir -p "$(dirname "${SENTINEL}")"
touch "${SENTINEL}"
log "OVF initialisation complete."
