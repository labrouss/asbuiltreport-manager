#!/bin/bash
# Start vmtoolsd daemon — required for vmtoolsd --cmd to work
vmtoolsd &
VMTOOLS_PID=$!

# Give it a moment to connect to the hypervisor
sleep 2

echo "vmtoolsd started (pid $VMTOOLS_PID)"
echo "VMware tools version: $(vmtoolsd --version 2>/dev/null || echo 'unknown')"

# Keep container alive
wait $VMTOOLS_PID
