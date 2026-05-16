#!/bin/sh
# abr-network-config.sh — network configuration helper
# Usage:
#   abr-network-config.sh dhcp
#   abr-network-config.sh static <IP/PREFIX> <GATEWAY> [DNS...]

NETCFG="/etc/network/config"

case "$1" in
  dhcp)
    echo "NETWORK_MODE=dhcp" > "$NETCFG"
    /etc/init.d/S10network restart
    echo "DHCP configured."
    ;;
  static)
    IP_CIDR="$2"
    GATEWAY="$3"
    shift 3
    DNS_SERVERS="${*:-8.8.8.8}"
    [ -n "$IP_CIDR" ] || { echo "Usage: $0 static <IP/PREFIX> <GW> [DNS...]"; exit 1; }
    cat > "$NETCFG" <<EOF
NETWORK_MODE=static
IP_CIDR="$IP_CIDR"
GATEWAY="$GATEWAY"
DNS_SERVERS="$DNS_SERVERS"
EOF
    /etc/init.d/S10network restart
    echo "Static IP configured: $IP_CIDR"
    ;;
  *)
    echo "Usage: $0 {dhcp|static <IP/PREFIX> <GW> [DNS...]}"
    exit 1
    ;;
esac
