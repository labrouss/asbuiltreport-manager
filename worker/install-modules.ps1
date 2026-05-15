Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
$modules = @(
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
    'AsBuiltReport.System.Resources'
)
foreach ($m in $modules) {
    Write-Host "Installing $m..."
    Install-Module $m -Repository PSGallery -Force -Scope AllUsers -AcceptLicense -SkipPublisherCheck -AllowPrerelease
    Write-Host "Done: $m"
}
