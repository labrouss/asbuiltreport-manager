#!/bin/bash
# =============================================================================
# abr-console.sh — AsBuiltReport Manager Management Console
#
# A whiptail-based TUI displayed on tty1.
# Provides:
#   - Service status overview
#   - IP address display
#   - Start / Stop / Restart containers
#   - View container logs
#   - Network configuration (static IP or DHCP)
#   - System reboot / shutdown
# =============================================================================

COMPOSE_DIR="/etc/docker/compose/asbuiltreport-manager"
NETWORKD_DIR="/etc/systemd/network"
TITLE="AsBuiltReport Manager Console"
VERSION="1.0.0"

# ── Helpers ──────────────────────────────────────────────────────────────────
get_ip() {
    ip -4 addr show scope global 2>/dev/null \
        | grep -oP '(?<=inet )\d+\.\d+\.\d+\.\d+/\d+' | head -1 \
        || echo "No IP assigned"
}

get_hostname() {
    hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "unknown"
}

container_status() {
    local name="$1"
    local status
    status=$(docker inspect --format '{{.State.Status}} ({{.State.Health.Status}})' \
             "${name}" 2>/dev/null || echo "not found")
    echo "${status}"
}

app_status()    { container_status "asbuiltreport-app"; }
worker_status() { container_status "asbuiltreport-worker"; }

# ── Screens ───────────────────────────────────────────────────────────────────

screen_status() {
    local ip hostname app worker uptime_str
    ip=$(get_ip)
    hostname=$(get_hostname)
    app=$(app_status)
    worker=$(worker_status)
    uptime_str=$(uptime -p 2>/dev/null || uptime)

    whiptail --title "${TITLE}" --msgbox \
"Hostname : ${hostname}
IP Address: ${ip}
Web UI    : http://$(echo "${ip}" | cut -d/ -f1):3001

Containers:
  abr-app    : ${app}
  abr-worker : ${worker}

System Uptime: ${uptime_str}" \
    20 68
}

screen_network() {
    CHOICE=$(whiptail --title "Network Configuration" --menu \
        "Choose a network configuration method:" 15 60 3 \
        "1" "Configure DHCP" \
        "2" "Configure Static IP" \
        "3" "Show current network config" \
        3>&1 1>&2 2>&3) || return

    case "${CHOICE}" in
        1)
            if whiptail --title "DHCP" --yesno \
                "Switch to DHCP and restart networking?\nThis will remove any static IP configuration." \
                10 60; then
                cat > "${NETWORKD_DIR}/10-eth.network" <<EOF
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
                systemctl restart systemd-networkd
                sleep 2
                whiptail --title "DHCP Applied" --msgbox \
                    "DHCP configured.\n\nNew IP: $(get_ip)" 10 50
            fi
            ;;
        2)
            IP=$(whiptail --title "Static IP" --inputbox \
                "Enter IP address in CIDR notation:\n(e.g. 192.168.1.50/24)" 10 50 "" \
                3>&1 1>&2 2>&3) || return
            GW=$(whiptail --title "Gateway" --inputbox \
                "Enter default gateway:" 10 50 "" \
                3>&1 1>&2 2>&3) || return
            DNS=$(whiptail --title "DNS Servers" --inputbox \
                "Enter DNS server(s), space-separated:\n(e.g. 8.8.8.8 8.8.4.4)" 10 60 "8.8.8.8 8.8.4.4" \
                3>&1 1>&2 2>&3) || return

            DNS_LINES=""
            for dns in ${DNS}; do
                DNS_LINES="${DNS_LINES}DNS=${dns}\n"
            done

            cat > "${NETWORKD_DIR}/10-eth.network" <<EOF
[Match]
Name=en* eth*

[Network]
Address=${IP}
Gateway=${GW}
$(printf "%b" "${DNS_LINES}")
LinkLocalAddressing=no
EOF
            systemctl restart systemd-networkd
            sleep 2
            whiptail --title "Static IP Applied" --msgbox \
                "Static IP configured.\n\nIP: ${IP}\nGW: ${GW}" 10 50
            ;;
        3)
            whiptail --title "Current Network Config" --msgbox \
                "$(cat "${NETWORKD_DIR}/10-eth.network" 2>/dev/null || echo 'No config file found')" \
                22 68
            ;;
    esac
}

screen_containers() {
    CHOICE=$(whiptail --title "Container Management" --menu \
        "Container operations:" 15 60 5 \
        "1" "Start stack (docker compose up -d)" \
        "2" "Stop stack (docker compose down)" \
        "3" "Restart stack" \
        "4" "View app logs (last 50 lines)" \
        "5" "View worker logs (last 50 lines)" \
        3>&1 1>&2 2>&3) || return

    cd "${COMPOSE_DIR}"
    case "${CHOICE}" in
        1)
            docker compose up -d --remove-orphans 2>&1 | tail -20
            whiptail --title "Done" --msgbox "Stack started." 8 40
            ;;
        2)
            docker compose down 2>&1 | tail -10
            whiptail --title "Done" --msgbox "Stack stopped." 8 40
            ;;
        3)
            docker compose down 2>&1 | tail -10
            docker compose up -d --remove-orphans 2>&1 | tail -20
            whiptail --title "Done" --msgbox "Stack restarted." 8 40
            ;;
        4)
            whiptail --title "abr-app logs" --scrolltext --msgbox \
                "$(docker compose logs --tail=50 app 2>&1)" 24 88
            ;;
        5)
            whiptail --title "abr-worker logs" --scrolltext --msgbox \
                "$(docker compose logs --tail=50 worker 2>&1)" 24 88
            ;;
    esac
}

screen_system() {
    CHOICE=$(whiptail --title "System" --menu \
        "System operations:" 12 50 3 \
        "1" "Reboot appliance" \
        "2" "Shutdown appliance" \
        "3" "Open bash shell (root)" \
        3>&1 1>&2 2>&3) || return

    case "${CHOICE}" in
        1)
            whiptail --title "Reboot" --yesno "Reboot the appliance now?" 8 40 && reboot
            ;;
        2)
            whiptail --title "Shutdown" --yesno "Shutdown the appliance now?" 8 40 && poweroff
            ;;
        3)
            clear
            echo "Type 'exit' to return to the management console."
            bash --login
            ;;
    esac
}

# ── Main loop ─────────────────────────────────────────────────────────────────
while true; do
    clear
    MAIN=$(whiptail --title "${TITLE} v${VERSION}" --menu \
        "IP: $(get_ip)   Host: $(get_hostname)\n\nSelect an option:" \
        18 64 5 \
        "1" "Service Status" \
        "2" "Container Management" \
        "3" "Network Configuration" \
        "4" "System" \
        "5" "Exit to shell" \
        3>&1 1>&2 2>&3) || break

    case "${MAIN}" in
        1) screen_status ;;
        2) screen_containers ;;
        3) screen_network ;;
        4) screen_system ;;
        5) break ;;
    esac
done

clear
echo "AsBuiltReport Manager Management Console — exited."
echo "Run 'abr-console' to return to the console."
exec bash --login
