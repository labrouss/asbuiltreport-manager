# vmware-tools — minimal container with open-vm-tools for guestinfo access
# Runs vmtoolsd heartbeat and exposes vmware-rpctool via Unix socket proxy.
FROM ubuntu:22.04

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        open-vm-tools \
        socat \
        netcat-openbsd && \
    rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
