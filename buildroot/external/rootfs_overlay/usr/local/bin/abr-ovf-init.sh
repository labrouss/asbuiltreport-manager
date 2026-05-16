#!/bin/sh
# abr-ovf-init.sh — legacy entry point, now a thin wrapper
# The real work is done by /etc/init.d/S05ovf-init at boot.
# This script exists only for manual re-runs from the console.
exec /etc/init.d/S05ovf-init start
