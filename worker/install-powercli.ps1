Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
Write-Host "Installing VMware PowerCLI (~500MB)..."
Install-Module VMware.PowerCLI -Repository PSGallery -Force -Scope AllUsers -AcceptLicense -SkipPublisherCheck
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope AllUsers | Out-Null
Set-PowerCLIConfiguration -ParticipateInCEIP $false -Confirm:$false -Scope AllUsers | Out-Null
Write-Host "PowerCLI installed."
