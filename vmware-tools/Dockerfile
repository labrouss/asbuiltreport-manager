# vmware-tools — minimal glibc container with open-vm-tools
# Runs privileged with host PID namespace so VMware backdoor port access works.
FROM ubuntu:22.04

RUN apt-get update && \
    apt-get install -y --no-install-recommends open-vm-tools && \
    rm -rf /var/lib/apt/lists/*

CMD ["tail", "-f", "/dev/null"]
