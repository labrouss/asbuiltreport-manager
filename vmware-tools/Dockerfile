# vmware-tools — open-vm-tools container for OVF guestinfo access
# Runs privileged with host PID namespace for VMware backdoor access.
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        open-vm-tools \
        xmlstarlet \
        bash && \
    rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
