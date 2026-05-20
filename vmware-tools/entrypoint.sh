#!/bin/sh
set -e

# Start vmtoolsd in background — maintains VMware heartbeat and guestinfo channel
vmtoolsd --background /var/run/vmtoolsd.pid 2>/dev/null || true

# Keep container alive
exec tail -f /dev/null
