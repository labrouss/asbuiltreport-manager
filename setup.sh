#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# AsBuiltReport Manager — Ubuntu Appliance Setup Script
# Run as: sudo bash setup.sh
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

[[ $EUID -ne 0 ]] && error "Run as root: sudo bash setup.sh"

info "Creating host directories..."
mkdir -p /var/www/reports /etc/asbuiltreport /var/lib/asbuiltreport/ps-modules
chmod 777 /var/www/reports
chmod 755 /etc/asbuiltreport /var/lib/asbuiltreport/ps-modules

info "Installing Docker & Compose plugin..."
if ! command -v docker &>/dev/null; then
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
    info "Docker installed ✓"
else
    info "Docker already present ✓"
fi

info "Enabling Docker service..."
systemctl enable --now docker

info "Building containers (this may take 10-20 min on first run)..."
warn "Worker image installs PowerShell, Veeam PS module, VMware PowerCLI and all AsBuiltReport modules."
warn "Subsequent builds use cached layers and are much faster."

docker compose build
docker compose up -d

info "Waiting for health checks (up to 120s)..."
sleep 15
docker compose ps

echo ""
echo -e "${GREEN}────────────────────────────────────────────────────${NC}"
echo -e "${GREEN}  AsBuiltReport Manager is running!${NC}"
echo -e "${GREEN}  UI:      http://$(hostname -I | awk '{print $1}'):3001${NC}"
echo -e "${GREEN}  Login:   admin / Admin@AsBuilt1!${NC}"
echo -e "${GREEN}           (change password on first login)${NC}"
echo -e "${GREEN}  Reports: /var/www/reports${NC}"
echo -e "${GREEN}  Configs: /etc/asbuiltreport${NC}"
echo -e "${GREEN}────────────────────────────────────────────────────${NC}"
