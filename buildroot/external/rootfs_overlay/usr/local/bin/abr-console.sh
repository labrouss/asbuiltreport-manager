#!/bin/sh
# =============================================================================
# abr-console.sh — AsBuiltReport Manager Management Console
# whiptail TUI on tty1. Uses busybox init (S-script style).
# =============================================================================

COMPOSE_DIR="/etc/docker/compose/asbuiltreport-manager"
TITLE="AsBuiltReport Manager Console"
VERSION="1.0.0"

get_ip() {
  ip -4 addr show scope global 2>/dev/null \
    | grep -oE 'inet [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' \
    | head -1 | cut -d' ' -f2 || echo "No IP assigned"
}

get_hostname() { hostname 2>/dev/null || echo "unknown"; }

container_status() {
  docker inspect --format '{{.State.Status}} (health: {{.State.Health.Status}})' \
    "$1" 2>/dev/null || echo "not found"
}

screen_status() {
  IP=$(get_ip)
  HOST=$(get_hostname)
  APP=$(container_status asbuiltreport-app)
  WORKER=$(container_status asbuiltreport-worker)
  UPTIME=$(uptime 2>/dev/null)
  whiptail --title "$TITLE" --msgbox \
"Hostname : $HOST
IP       : $IP
Web UI   : http://$(echo $IP | cut -d/ -f1):3001

Containers:
  app    : $APP
  worker : $WORKER

$UPTIME" 20 68
}

screen_network() {
  CHOICE=$(whiptail --title "Network Configuration" --menu \
    "Choose a network configuration method:" 15 60 3 \
    "1" "Configure DHCP" \
    "2" "Configure Static IP" \
    "3" "Show current config" \
    3>&1 1>&2 2>&3) || return

  case "$CHOICE" in
    1)
      whiptail --title "DHCP" --yesno \
        "Switch to DHCP and restart networking?" 8 50 || return
      echo "NETWORK_MODE=dhcp" > /etc/network/config
      /etc/init.d/S10network restart
      whiptail --title "DHCP Applied" --msgbox \
        "DHCP configured.\n\nNew IP: $(get_ip)" 10 50
      ;;
    2)
      IP=$(whiptail --title "Static IP" --inputbox \
        "Enter IP in CIDR notation (e.g. 192.168.1.50/24):" \
        10 60 "" 3>&1 1>&2 2>&3) || return
      GW=$(whiptail --title "Gateway" --inputbox \
        "Enter default gateway:" 8 50 "" 3>&1 1>&2 2>&3) || return
      DNS=$(whiptail --title "DNS" --inputbox \
        "Enter DNS servers (space-separated):" \
        8 60 "8.8.8.8 8.8.4.4" 3>&1 1>&2 2>&3) || return
      cat > /etc/network/config <<EOF
NETWORK_MODE=static
IP_CIDR="$IP"
GATEWAY="$GW"
DNS_SERVERS="$DNS"
EOF
      /etc/init.d/S10network restart
      whiptail --title "Static IP Applied" --msgbox \
        "Static IP configured.\n\nIP: $IP\nGW: $GW" 10 50
      ;;
    3)
      whiptail --title "Current Config" --msgbox \
        "$(cat /etc/network/config 2>/dev/null || echo 'No config found')" 14 60
      ;;
  esac
}

screen_containers() {
  CHOICE=$(whiptail --title "Container Management" --menu \
    "Container operations:" 15 60 5 \
    "1" "Start stack" \
    "2" "Stop stack" \
    "3" "Restart stack" \
    "4" "View app logs (last 50 lines)" \
    "5" "View worker logs (last 50 lines)" \
    3>&1 1>&2 2>&3) || return

  cd "$COMPOSE_DIR" || return
  case "$CHOICE" in
    1) docker compose up -d --remove-orphans
       whiptail --title "Done" --msgbox "Stack started." 8 40 ;;
    2) docker compose down
       whiptail --title "Done" --msgbox "Stack stopped." 8 40 ;;
    3) docker compose down && docker compose up -d --remove-orphans
       whiptail --title "Done" --msgbox "Stack restarted." 8 40 ;;
    4) whiptail --title "app logs" --scrolltext --msgbox \
         "$(docker compose logs --tail=50 app 2>&1)" 24 88 ;;
    5) whiptail --title "worker logs" --scrolltext --msgbox \
         "$(docker compose logs --tail=50 worker 2>&1)" 24 88 ;;
  esac
}

screen_system() {
  CHOICE=$(whiptail --title "System" --menu \
    "System operations:" 12 50 3 \
    "1" "Reboot appliance" \
    "2" "Shutdown appliance" \
    "3" "Open shell (root)" \
    3>&1 1>&2 2>&3) || return

  case "$CHOICE" in
    1) whiptail --title "Reboot" --yesno "Reboot now?" 8 40 && reboot ;;
    2) whiptail --title "Shutdown" --yesno "Shutdown now?" 8 40 && poweroff ;;
    3) clear; echo "Type 'exit' to return to console."; sh --login ;;
  esac
}

# ── Main loop ─────────────────────────────────────────────────────────────────
while true; do
  clear
  MAIN=$(whiptail --title "$TITLE v$VERSION" --menu \
    "IP: $(get_ip)   Host: $(get_hostname)\n\nSelect an option:" \
    18 64 5 \
    "1" "Service Status" \
    "2" "Container Management" \
    "3" "Network Configuration" \
    "4" "System" \
    "5" "Exit to shell" \
    3>&1 1>&2 2>&3) || break

  case "$MAIN" in
    1) screen_status ;;
    2) screen_containers ;;
    3) screen_network ;;
    4) screen_system ;;
    5) break ;;
  esac
done

clear
echo "AsBuiltReport Manager Console — exited."
exec sh --login
