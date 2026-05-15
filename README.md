# AsBuiltReport Manager

Enterprise-grade web GUI for managing, configuring, executing and scheduling [AsBuiltReport](https://www.asbuiltreport.com/) PowerShell modules.

Two deployment modes are supported from the same repository:

| Mode | How | Best for |
|------|-----|----------|
| **Docker** | Clone repo, run `sudo bash setup.sh` | Linux servers, home labs, CI runners |
| **VMware OVA** | Download `.ova`, deploy to vCenter/ESXi | Production, air-gapped, enterprise |

---

## Docker Mode — Quick Start

```bash
git clone <repo> asbuiltreport-manager
cd asbuiltreport-manager
sudo bash setup.sh
```

Open **http://\<host-ip\>:3001**

**Default credentials:** `admin` / `Admin@AsBuilt1!`
You will be forced to change the password on first login.

---

## VMware OVA Appliance — Quick Start

1. Download the latest `.ova` from the [Releases](../../releases) page
2. In vCenter: **Actions → Deploy OVF Template**, select the `.ova`
3. Fill in the OVF properties at deploy time:
   - **Hostname** (e.g. `abr.company.local`)
   - **IP Address** in CIDR notation (e.g. `192.168.1.50/24`) — leave blank for DHCP
   - **Gateway** and **DNS servers**
   - **Root password**
4. Power on — the stack starts automatically in ~2 minutes
5. Open **http://\<vm-ip\>:3001**

**VM specs:** 4 vCPU · 8 GB RAM · 40 GB disk · VMXNET3

> The OVA is built with Buildroot. Both Docker images are baked in — no internet required after deployment.

---

## Architecture

```
Browser (React + Tailwind)
    │  HTTP / WebSocket :3001
    ▼
app container  (node:20-slim)
  • Express REST API  /api/*
  • WebSocket live log streaming
  • JWT authentication + TOTP 2FA
  • Report scheduler (30s tick)
  • Serves React SPA + /reports/*
    │  HTTP :8080 (internal)
    ▼
worker container  (rockylinux:9)
  • PowerShell 7
  • Veeam.Backup.PowerShell (Linux)
  • VMware PowerCLI
  • All AsBuiltReport modules
  • Custom HPE OneView report script
    │  Bind mounts
    ▼
Host directories
  /var/www/reports          ← generated HTML/Word reports
  /etc/asbuiltreport        ← module configs + users.json
  /var/lib/asbuiltreport    ← cached PS modules
```

---

## Supported Modules

| Module | Category | Notes |
|--------|----------|-------|
| VMware vSphere | VMware | PowerCLI |
| VMware ESXi | VMware | PowerCLI |
| VMware Horizon | VMware | PowerCLI |
| Veeam VBR | Backup | Requires Veeam PS for Linux |
| Zerto ZVM | DR | REST API |
| HPE OneView | Compute | Custom script, auto version detect |
| NetApp ONTAP | Storage | |
| Pure Storage FlashArray | Storage | |
| Nutanix Prism Element | HCI | |
| Fortinet FortiGate | Security | |
| Aruba ClearPass | Networking | |
| Dell EMC VxRail | HCI | |
| Microsoft Azure | Cloud | |
| Microsoft Intune | Microsoft | |
| Microsoft Entra ID | Microsoft | |
| System Resources | System | Cross-platform |

---

## Key Features

- **Dashboard** — report stats, 7-day activity chart, module breakdown, recent jobs, scheduled jobs
- **Module Registry** — install/update modules from PSGallery, one-click configure & run
- **Config Builder** — dynamic form for each module (connection, report settings, company branding, output formats)
- **Execution Console** — real-time streaming terminal output via WebSocket
- **Report Gallery** — grouped by module or date, quick-open, clear empty/all
- **Scheduler** — hourly/daily/weekly/monthly automated reports
- **Authentication** — JWT sessions, PBKDF2 password hashing, TOTP 2FA (Google Authenticator compatible)
- **User Management** — admin can add/delete users, assign roles, reset passwords

---

## Docker Commands

```bash
# Start (first time — takes 10-20 min)
docker compose up -d --build

# Rebuild app only (after frontend/backend changes)
docker compose build --build-arg CACHEBUST=$(date +%s) app
docker compose up -d app

# Rebuild worker only (after PS module changes)
docker compose build --no-cache worker
docker compose up -d worker

# Hot-copy backend changes (no rebuild)
docker cp backend/src/server.js asbuiltreport-app:/app/backend/src/server.js
docker restart asbuiltreport-app

# Hot-copy worker script changes (no rebuild)
docker cp worker/worker.ps1 asbuiltreport-worker:/app/worker.ps1
docker restart asbuiltreport-worker

# View logs
docker logs -f asbuiltreport-app
docker logs -f asbuiltreport-worker

# Shell into worker
docker exec -it asbuiltreport-worker pwsh
```

### Makefile shortcuts

```bash
make up              # docker compose up -d (creates host dirs first)
make down            # docker compose down
make rebuild         # --no-cache rebuild of all images, then up
make rebuild-app     # rebuild app image only, then up app
make rebuild-worker  # rebuild worker image only, then up worker
make deploy-backend  # hot-copy backend/src/* and restart app
make deploy-worker   # hot-copy worker/*.ps1 and restart worker
make logs            # tail all logs
make shell-app       # sh into app container
make shell-worker    # pwsh into worker container
make status          # container health + recent app logs
make reset           # ⚠ wipe all data and start fresh
```

---

## Persistent Volumes

| Host Path | Purpose |
|-----------|---------|
| `/var/www/reports` | Generated HTML/PDF/Word reports |
| `/etc/asbuiltreport` | Module configs, users.json, schedules.json |
| `/var/lib/asbuiltreport/ps-modules` | Cached PowerShell modules |

All data survives container restarts and rebuilds.

---

## OVA Build (from source)

The OVA is built with [Buildroot](https://buildroot.org). The `buildroot/` directory
contains a `BR2_EXTERNAL` tree with defconfig, rootfs overlay, systemd units,
first-boot scripts, and the OVF descriptor template.

### Prerequisites (Ubuntu 22.04)

```bash
sudo apt-get install -y \
    build-essential git curl python3 \
    libncurses-dev bison flex gawk \
    cpio rsync bc file unzip \
    qemu-utils mtools dosfstools e2fsprogs

# genimage — not in Ubuntu apt, build from source:
sudo apt-get install -y autoconf automake libtool pkg-config libconfuse-dev
git clone --depth=1 https://github.com/pengutronix/genimage.git
cd genimage && ./autogen.sh && ./configure && make -j$(nproc) && sudo make install
```

### Build steps

```bash
# 1. Save Docker images as tarballs (baked into the OVA)
make prepare-images       # both images (~40 min first run, cached after)
# or individually:
make prepare-app          # ~2 min
make prepare-worker       # ~40 min

# 2. Configure Buildroot (downloads Buildroot source automatically)
make defconfig

# 3. Build the OVA
make ova-build            # ~1-2 hours → output/images/asbuiltreport-manager-v*.ova
```

### OVA first-boot sequence

```
systemd starts
  ├── asbuiltreport-ovf-init   reads guestinfo.* → sets hostname + network + password
  ├── docker + containerd
  ├── asbuiltreport-first-boot  docker load *.tar.gz → docker compose up -d  (once only)
  ├── asbuiltreport-manager     keeps compose up on every subsequent boot
  └── asbuiltreport-console     whiptail management TUI on tty1
```

### OVF properties (set at deploy time in vCenter)

| Property | Key | Default |
|----------|-----|---------|
| Hostname | `guestinfo.hostname` | `asbuiltreport-manager` |
| IP Address (CIDR) | `guestinfo.ipaddress` | *(blank = DHCP)* |
| Default Gateway | `guestinfo.gateway` | *(blank)* |
| DNS Servers | `guestinfo.dns` | `8.8.8.8 8.8.4.4` |
| Root Password | `guestinfo.password` | *(blank = key-only)* |
| SSH Authorised Key | `guestinfo.ssh_authorized_key` | *(blank)* |

---

## API Reference

| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| POST | `/api/auth/login` | — | Username + password |
| POST | `/api/auth/totp` | partial | Verify TOTP code |
| GET | `/api/auth/me` | ✓ | Current user info |
| POST | `/api/auth/change-password` | ✓ | Change own password |
| POST | `/api/auth/setup-2fa` | ✓ | Generate TOTP secret + QR |
| POST | `/api/auth/verify-2fa` | ✓ | Enable 2FA |
| GET | `/api/modules` | ✓ | List all modules + install status |
| POST | `/api/modules/:id/install` | ✓ | Install from PSGallery |
| GET/POST | `/api/modules/:id/config` | ✓ | Get/save module config |
| POST | `/api/reports/run` | ✓ | Run report (streams via WS) |
| GET | `/api/reports` | ✓ | List report jobs |
| DELETE | `/api/reports/:jobId` | ✓ | Delete report job |
| GET/POST | `/api/schedules` | ✓ | List/create schedules |
| PUT/DELETE | `/api/schedules/:id` | ✓ | Update/delete schedule |
| GET | `/api/users` | admin | List users |
| POST | `/api/users` | admin | Create user |
| DELETE | `/api/users/:username` | admin | Delete user |
| GET | `/api/health/dependencies` | ✓ | Check worker dependencies |

---

## Security

- Passwords: PBKDF2-SHA512, 310,000 iterations, 32-byte salt
- Sessions: HS256 JWT, 8-hour expiry, server-side secret
- 2FA: RFC 6238 TOTP, SHA-1, 30s window, ±1 drift tolerance
- Password policy: 12+ chars, upper, lower, number, symbol
- All API routes require valid JWT except `/api/auth/login` and `/api/auth/totp`
