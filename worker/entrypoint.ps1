#!/usr/bin/env pwsh
Write-Host "[Worker] Bootstrapping..." -ForegroundColor Cyan

Write-Host "  Configuring PSGallery..." -ForegroundColor Yellow
try {
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop
    Write-Host "  ✓ PSGallery trusted" -ForegroundColor Green
} catch {
    Write-Host "  ✗ PSGallery setup failed: $_" -ForegroundColor Red
}

# Linux-compatible AsBuiltReport modules
$Modules = @(
    'VCF.PowerCLI'
    'AsBuiltReport.Core'
    'AsBuiltReport.VMware.vSphere'
    'AsBuiltReport.VMware.ESXi'
    'AsBuiltReport.VMware.Horizon'
    'AsBuiltReport.Veeam.VBR'
    'AsBuiltReport.NetApp.ONTAP'
    'AsBuiltReport.PureStorage.FlashArray'
    'AsBuiltReport.Nutanix.PrismElement'
    'AsBuiltReport.Fortinet.FortiGate'
    'AsBuiltReport.Aruba.ClearPass'
    'AsBuiltReport.Zerto.ZVM'
    'AsBuiltReport.DellEMC.VxRail'
    'AsBuiltReport.Microsoft.Azure'
    'AsBuiltReport.Microsoft.Intune'
    'AsBuiltReport.Microsoft.EntraID'
    'AsBuiltReport.Microsoft.SharePoint'
    'AsBuiltReport.Microsoft.ExchangeOnline'
    'AsBuiltReport.Microsoft.Purview'
    'AsBuiltReport.System.Resources'
)

foreach ($Module in $Modules) {
    if (Get-Module -ListAvailable -Name $Module -ErrorAction SilentlyContinue) {
        Write-Host "  ✓ $Module already present" -ForegroundColor Green
    } else {
        Write-Host "  Installing $Module..." -ForegroundColor Yellow
        try {
            Install-Module -Name $Module -Repository PSGallery -Force -Scope AllUsers `
                -SkipPublisherCheck -AcceptLicense -AllowPrerelease -ErrorAction Stop
            Write-Host "  ✓ $Module installed" -ForegroundColor Green
        } catch {
            Write-Host "  ✗ Failed: ${Module}: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

Write-Host "[Worker] Starting HTTP listener..." -ForegroundColor Cyan
& /app/worker.ps1
