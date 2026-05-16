#!/bin/sh
# abr-first-boot.sh — legacy entry point, now a thin wrapper.
# The real work is done by /etc/init.d/S40asbuiltreport at boot.
exec /etc/init.d/S40asbuiltreport start
