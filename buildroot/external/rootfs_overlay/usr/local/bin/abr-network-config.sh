#!/bin/bash
# =============================================================================
# abr-network-config.sh — Network configuration helper
#
# Can be called:
#   abr-network-config dhcp
#   abr-network-config static <ip-cidr> <gateway> [dns...]
#
# Used by both the OVF init script and the management console.
# =============================================================================
set -euo pipefail

NETWORKD_DIR="/etc/systemd/network"
NETWORK_FILE="${NETWORKD_DIR}/10-eth.network"

usage() {
    echo "Usage:"
    echo "  abr-network-config dhcp"
    echo "  abr-network-config static <IP/PREFIX> <GATEWAY> [DNS1 DNS2 ...]"
    exit 1
}

MODE="${1:-}"

case "${MODE}" in
    dhcp)
        mkdir -p "${NETWORKD_DIR}"
        cat > "${NETWORK_FILE}" <<'EOF'
[Match]
Name=en* eth*

[Network]
DHCP=yes
IPv6AcceptRA=no

[DHCP]
UseDNS=yes
UseDomains=yes
SendHostname=yes
EOF
        echo "DHCP configuration written to ${NETWORK_FILE}"
        ;;

    static)
        IP_CIDR="${2:-}"
        GATEWAY="${3:-}"
        shift 3 || true
        DNS_SERVERS=("${@:-8.8.8.8}")

        [[ -n "${IP_CIDR}" ]] || usage
        [[ -n "${GATEWAY}" ]] || usage

        mkdir -p "${NETWORKD_DIR}"
        {
            echo "[Match]"
            echo "Name=en* eth*"
            echo ""
            echo "[Network]"
            echo "Address=${IP_CIDR}"
            echo "Gateway=${GATEWAY}"
            for dns in "${DNS_SERVERS[@]}"; do
                echo "DNS=${dns}"
            done
            echo "LinkLocalAddressing=no"
        } > "${NETWORK_FILE}"
        echo "Static IP configuration written to ${NETWORK_FILE}"
        ;;

    *)
        usage
        ;;
esac

# Reload systemd-networkd if it's running
if systemctl is-active --quiet systemd-networkd; then
    systemctl restart systemd-networkd
    echo "systemd-networkd restarted."
fi
