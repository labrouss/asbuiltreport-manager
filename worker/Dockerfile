# Rocky Linux 9 — required for Veeam.Backup.PowerShell module
FROM rockylinux:9

LABEL maintainer="AsBuiltReport Manager"
LABEL description="PowerShell worker - Rocky Linux 9 + Veeam + VMware PowerCLI"

# System deps
RUN dnf install -y -q epel-release && \
    dnf update -y -q && \
    dnf install -y -q ca-certificates graphviz tar gzip wget && \
    dnf clean all

# Pandoc from GitHub
RUN curl-minimal -fsSL https://github.com/jgm/pandoc/releases/download/3.2/pandoc-3.2-linux-amd64.tar.gz \
    | tar -xzf - --strip-components=2 -C /usr/local/bin pandoc-3.2/bin/pandoc || true

# PowerShell 7 + ASP.NET Core 8
RUN wget -q https://packages.microsoft.com/config/rhel/9/packages-microsoft-prod.rpm \
        -O /tmp/ms-prod.rpm && \
    dnf install -y /tmp/ms-prod.rpm && \
    dnf install -y powershell aspnetcore-runtime-8.0 && \
    rm /tmp/ms-prod.rpm && \
    dnf clean all

# Veeam PowerShell module for Linux
RUN dnf install -y \
    https://repository.veeam.com/rocky/9.2/vbr/13.0/optional/x86_64/veeam-optional-release-latest-13.0.1.2067-1.x86_64.rpm && \
    dnf install -y veeam-powershell && \
    dnf clean all

# VMware PowerCLI — use a script file to avoid shell escaping issues with backticks
COPY install-powercli.ps1 /tmp/install-powercli.ps1
RUN pwsh -NonInteractive -File /tmp/install-powercli.ps1 && rm /tmp/install-powercli.ps1

# AsBuiltReport modules
COPY install-modules.ps1 /tmp/install-modules.ps1
RUN pwsh -NonInteractive -File /tmp/install-modules.ps1 && rm /tmp/install-modules.ps1

# Validate Veeam module
RUN pwsh -NonInteractive -Command \
    "Import-Module /opt/veeam/powershell/Veeam.Backup.PowerShell/Veeam.Backup.PowerShell.psd1 -Force; Write-Host 'Veeam PS module OK'"

WORKDIR /app
COPY entrypoint.ps1 ./entrypoint.ps1
COPY worker.ps1     ./worker.ps1
COPY reports/       ./reports/

EXPOSE 8080
ENTRYPOINT ["pwsh", "-File", "/app/entrypoint.ps1"]
