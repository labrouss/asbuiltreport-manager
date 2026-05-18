# AsBuiltReport Manager

Enterprise-grade web GUI for managing, configuring, executing and scheduling [AsBuiltReport](https://www.asbuiltreport.com/) PowerShell modules — deployed as two Docker containers on a Linux host.

---

## Quick Start

```bash
git clone <repo> asbuiltreport-manager
cd asbuiltreport-manager
sudo bash setup.sh
```

Open **http://\<host-ip\>:3001**

**Default credentials:** `admin` / `Admin@AsBuilt1!`  
You will be forced to change the password on first login.

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

---

## Persistent Volumes

| Host Path | Purpose |
|-----------|---------|
| `/var/www/reports` | Generated HTML/PDF/Word reports |
| `/etc/asbuiltreport` | Module configs, users.json, schedules.json |
| `/var/lib/asbuiltreport/ps-modules` | Cached PowerShell modules |

All data survives container restarts and rebuilds.

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
