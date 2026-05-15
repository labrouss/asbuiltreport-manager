#!/usr/bin/env pwsh
# Custom HPE OneView As-Built Report
param(
    [string]$Target,
    [string]$Username,
    [string]$Password,
    [string]$OutputPath,
    [string]$JobId,
    [string]$ApplianceVersion = "auto"
)
$ErrorActionPreference = 'Stop'
function Write-Log { param([string]$Msg) Write-Output "[ $(Get-Date -Format 'HH:mm:ss:fff') ] [ Document ] - $Msg" }

Write-Log "HPE OneView As-Built Report starting — Target: $Target"

# ── Auto-detect OneView version via unauthenticated REST call ─────────────────
if ($ApplianceVersion -eq "auto") {
    Write-Log "Auto-detecting HPE OneView appliance version..."
    try {
        # /rest/version returns { currentVersion, minimumVersion, maximumVersion }
        $VersionUri = "https://$Target/rest/version"
        $Response = Invoke-RestMethod -Uri $VersionUri -Method GET `
            -SkipCertificateCheck -ErrorAction Stop
        Write-Log "Version response: $($Response | ConvertTo-Json -Compress)"

        # Try both property names (varies by OneView release)
        $MaxApiVersion = if ($Response.maximumVersion) { [int]$Response.maximumVersion }
                         elseif ($Response.currentVersion) { [int]$Response.currentVersion }
                         else { 0 }
        Write-Log "Appliance max API version: $MaxApiVersion"

        # Map API version to HPEOneView PS module — ONLY versions that exist on PSGallery:
        # 600, 610, 800, 830, 850, 900, 910, 1000
        # API version list: https://github.com/HewlettPackard/POSH-HPEOneView/wiki
        $ApplianceVersion = switch ($true) {
            ($MaxApiVersion -ge 7600) { "1000"; break } # OV 10.x
            ($MaxApiVersion -ge 7200) { "910";  break } # OV 9.10
            ($MaxApiVersion -ge 7000) { "900";  break } # OV 9.0
            ($MaxApiVersion -ge 6600) { "850";  break } # OV 8.50
            ($MaxApiVersion -ge 6400) { "830";  break } # OV 8.30
            ($MaxApiVersion -ge 6200) { "800";  break } # OV 8.0
            ($MaxApiVersion -ge 4000) { "610";  break } # OV 6.10
            ($MaxApiVersion -ge 3800) { "600";  break } # OV 6.0
            default {
                Write-Log "API version $MaxApiVersion predates PSGallery modules — using HPEOneView.600"
                "600"
            }
        }
        Write-Log "Selected HPEOneView module version: $ApplianceVersion"
    } catch {
        Write-Log "Could not auto-detect version: $_"
        Write-Log "Defaulting to HPEOneView.1000"
        $ApplianceVersion = "1000"
    }
}

$ModuleName = "HPEOneView.$ApplianceVersion"
if (-not (Get-Module -ListAvailable -Name $ModuleName -ErrorAction SilentlyContinue)) {
    Write-Log "Installing $ModuleName from PSGallery..."
    Install-Module -Name $ModuleName -Repository PSGallery -Force -Scope AllUsers -AcceptLicense -SkipPublisherCheck
    Write-Log "$ModuleName installed."
}
Import-Module $ModuleName -Force
Write-Log "Loaded $ModuleName"

# Suppress SSL cert errors (common in lab environments)
try { [HPEOneView.PKI.SslValidation]::IgnoreCertErrors = $true } catch {}

Write-Log "Connecting to $Target..."
$SecPass = ConvertTo-SecureString $Password -AsPlainText -Force
Connect-OVMgmt -Hostname $Target -Credential (New-Object System.Management.Automation.PSCredential($Username, $SecPass)) | Out-Null
Write-Log "Connected to HPE OneView $ApplianceVersion"

# Wrap each collection in try/catch — some resource types may not exist on all OneView configs
Write-Log "Collecting server hardware..."
$Servers = try { @(Get-OVServer | Sort-Object name) } catch { Write-Log "Note: $($_.Exception.Message)"; @() }
Write-Log "Found $($Servers.Count) servers"

Write-Log "Collecting server profiles..."
$Profiles = try { @(Get-OVServerProfile | Sort-Object name) } catch { Write-Log "Note: $($_.Exception.Message)"; @() }
Write-Log "Found $($Profiles.Count) profiles"

Write-Log "Collecting server profile templates..."
$Templates = try { @(Get-OVServerProfileTemplate | Sort-Object name) } catch { Write-Log "Note: $($_.Exception.Message)"; @() }
Write-Log "Found $($Templates.Count) templates"

Write-Log "Collecting networks..."
$Networks = try { @(Get-OVNetwork | Sort-Object name) } catch { Write-Log "Note: $($_.Exception.Message)"; @() }
Write-Log "Found $($Networks.Count) networks"

Write-Log "Collecting enclosures (c-Class)..."
$Enclosures = try { @(Get-OVEnclosure | Sort-Object name) } catch { Write-Log "Note: Get-OVEnclosure not supported on this appliance (may use Synergy frames)"; @() }
Write-Log "Found $($Enclosures.Count) enclosures"

Write-Log "Collecting Synergy frames..."
$Frames = try { @(Get-OVEnclosureGroup | Sort-Object name) } catch { Write-Log "Note: $($_.Exception.Message)"; @() }
Write-Log "Found $($Frames.Count) enclosure groups"

Write-Log "Collecting logical enclosures..."
$LogicalEnclosures = try { @(Get-OVLogicalEnclosure | Sort-Object name) } catch { Write-Log "Note: $($_.Exception.Message)"; @() }
Write-Log "Found $($LogicalEnclosures.Count) logical enclosures"

Write-Log "Collecting storage systems..."
$Storage = try { @(Get-OVStorageSystem | Sort-Object name) } catch { Write-Log "Note: $($_.Exception.Message)"; @() }
Write-Log "Found $($Storage.Count) storage systems"

Write-Log "Collecting firmware baselines..."
$Firmware = try { @(Get-OVBaseline | Sort-Object Version) } catch { Write-Log "Note: $($_.Exception.Message)"; @() }
Write-Log "Found $($Firmware.Count) firmware baselines" 

function Badge { param([string]$S)
    $c = if ($S -match 'OK|Normal|Running') {'ok'} elseif ($S -match 'Warning') {'warn'} elseif ($S -match 'Critical|Error') {'err'} else {'info'}
    "<span class='badge $c'>$S</span>"
}
function E { param($V) if ($null -eq $V -or "$V" -eq '') { '<em>N/A</em>' } else { [System.Web.HttpUtility]::HtmlEncode("$V") } }

$GenDate = Get-Date -Format "dd MMM yyyy HH:mm"

$SrvRows = $Servers | ForEach-Object {
    $pw  = if ($_.powerState -eq 'On') {"<span class='badge ok'>On</span>"} else {"<span class='badge info'>Off</span>"}
    $mem = if ($_.memoryMb) { "$([math]::Round($_.memoryMb/1024)) GB" } else { 'N/A' }
    $cpu = if ($_.processorCount) { "$($_.processorCount) x $($_.processorCoreCount)-core" } else { 'N/A' }
    "<tr><td>$(E $_.name)</td><td>$(E $_.model)</td><td>$(E $_.serialNumber)</td><td>$pw</td><td>$(Badge $_.status)</td><td>$cpu</td><td>$mem</td></tr>"
}
$ProfRows = $Profiles | ForEach-Object {
    "<tr><td>$(E $_.name)</td><td>$(E $_.serverHardwareName)</td><td>$(E $_.serverHardwareTypeName)</td><td>$(Badge $_.status)</td><td>$(try{$_.connectionSettings.connections.Count}catch{0})</td></tr>"
}
$NetRows = $Networks | ForEach-Object {
    $t = if ($_.category -match 'ethernet') { 'Ethernet' } elseif ($_.category -match 'fc') { 'Fibre Channel' } else { $_.category }
    "<tr><td>$(E $_.name)</td><td>$t</td><td>$(E $_.vlanId)</td><td>$(Badge $_.status)</td></tr>"
}
$EncRows = $Enclosures | ForEach-Object {
    "<tr><td>$(E $_.name)</td><td>$(E $_.enclosureModel)</td><td>$(E $_.serialNumber)</td><td>$(Badge $_.status)</td></tr>"
}
$FrameRows = $Frames | ForEach-Object {
    "<tr><td>$(E $_.name)</td><td>$(E $_.enclosureTypeUri)</td><td>$(Badge $_.status)</td></tr>"
}
$LERows = $LogicalEnclosures | ForEach-Object {
    "<tr><td>$(E $_.name)</td><td>$(E $_.enclosureGroupName)</td><td>$(Badge $_.status)</td></tr>"
}
$FwRows = $Firmware | ForEach-Object {
    "<tr><td>$(E $_.name)</td><td>$(E $_.version)</td><td>$(E $_.releaseDate)</td><td>$(E ([math]::Round($_.fileSize/1MB,1))) MB</td></tr>"
}
$StorRows = $Storage | ForEach-Object {
    "<tr><td>$(E $_.name)</td><td>$(E $_.model)</td><td>$(E $_.serialNumber)</td><td>$(Badge $_.status)</td></tr>"
}
$TplRows = $Templates | ForEach-Object {
    "<tr><td>$(E $_.name)</td><td>$(E $_.serverHardwareTypeName)</td><td>$(Badge $_.status)</td></tr>"
}

$Html = @"
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">
<title>HPE OneView — $Target</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}body{font-family:'Segoe UI',Arial,sans-serif;font-size:13px;color:#1a1a1a;background:#f4f4f4}
.page{max-width:1200px;margin:0 auto;padding:24px}
.cover{background:linear-gradient(135deg,#00b5e2 0%,#005c8a 100%);color:#fff;border-radius:12px;padding:40px;margin-bottom:20px}
.cover h1{font-size:30px;font-weight:300}.cover .sub{opacity:.75;margin-top:4px}
.meta{display:grid;grid-template-columns:repeat(4,1fr);gap:12px;margin-top:24px}
.meta-item{background:rgba(255,255,255,.15);border-radius:8px;padding:14px}
.meta-item label{font-size:10px;text-transform:uppercase;letter-spacing:.1em;opacity:.7;display:block}
.meta-item .v{font-size:22px;font-weight:700;margin-top:4px}
.card{background:#fff;border:1px solid #ddd;border-radius:8px;margin-bottom:16px;overflow:hidden}
.sh{background:#f0f4f8;border-bottom:1px solid #e0e0e0;padding:10px 16px;font-size:11px;font-weight:700;text-transform:uppercase;letter-spacing:.1em;color:#333}
table{width:100%;border-collapse:collapse}
th{background:#f7f9fb;padding:8px 12px;text-align:left;font-size:11px;font-weight:600;text-transform:uppercase;letter-spacing:.06em;color:#555;border-bottom:2px solid #e0e0e0}
td{padding:8px 12px;border-bottom:1px solid #f0f0f0;vertical-align:middle}tr:last-child td{border-bottom:none}tr:hover td{background:#fafbff}
.badge{display:inline-block;padding:2px 8px;border-radius:20px;font-size:10px;font-weight:600}
.ok{background:#e6f4ea;color:#1e8e3e}.warn{background:#fef7e0;color:#b06000}.err{background:#fce8e6;color:#c5221f}.info{background:#e8f0fe;color:#1a73e8}
.footer{text-align:center;color:#999;font-size:11px;padding:20px 0}
em{color:#bbb;font-style:italic}
</style></head><body><div class="page">
<div class="cover">
  <div style="font-size:11px;opacity:.6;text-transform:uppercase;letter-spacing:.1em">As-Built Documentation</div>
  <h1>HPE OneView</h1>
  <div class="sub">$Target &nbsp;·&nbsp; Module v9.10 &nbsp;·&nbsp; API v$MaxApiVersion</div>
  <div class="meta">
    <div class="meta-item"><label>Generated</label><div class="v" style="font-size:13px">$GenDate</div></div>
    <div class="meta-item"><label>Server Hardware</label><div class="v">$($Servers.Count)</div></div>
    <div class="meta-item"><label>Server Profiles</label><div class="v">$($Profiles.Count)</div></div>
    <div class="meta-item"><label>Networks</label><div class="v">$($Networks.Count)</div></div>
    <div class="meta-item"><label>Storage Systems</label><div class="v">$($Storage.Count)</div></div>
    <div class="meta-item"><label>Firmware Baselines</label><div class="v">$($Firmware.Count)</div></div>
    <div class="meta-item"><label>Enclosure Groups</label><div class="v">$($Frames.Count)</div></div>
    <div class="meta-item"><label>Logical Enclosures</label><div class="v">$($LogicalEnclosures.Count)</div></div>
  </div>
</div>
<div class="card"><div class="sh">🖥️ Server Hardware</div><table>
<tr><th>Name</th><th>Model</th><th>Serial</th><th>Power</th><th>Status</th><th>CPU</th><th>Memory</th></tr>
$($SrvRows -join "`n")</table></div>
<div class="card"><div class="sh">📋 Server Profiles ($($Profiles.Count))</div><table>
<tr><th>Profile Name</th><th>Assigned Hardware</th><th>Hardware Type</th><th>Status</th><th>Connections</th></tr>
$($ProfRows -join "`n")</table></div>
<div class="card"><div class="sh">📋 Profile Templates ($($Templates.Count))</div><table>
<tr><th>Template Name</th><th>Hardware Type</th><th>Status</th></tr>
$($TplRows -join "`n")</table></div>
<div class="card"><div class="sh">🌐 Networks ($($Networks.Count))</div><table>
<tr><th>Name</th><th>Type</th><th>VLAN ID</th><th>Status</th></tr>
$($NetRows -join "`n")</table></div>
$(if ($Enclosures.Count -gt 0) {
"<div class='card'><div class='sh'>🏗️ Enclosures ($($Enclosures.Count))</div><table>
<tr><th>Name</th><th>Model</th><th>Serial</th><th>Status</th></tr>
$($EncRows -join "`n")</table></div>"
})
$(if ($Frames.Count -gt 0) {
"<div class='card'><div class='sh'>🏗️ Enclosure Groups ($($Frames.Count))</div><table>
<tr><th>Name</th><th>Enclosure Type</th><th>Status</th></tr>
$($FrameRows -join "`n")</table></div>"
})
$(if ($LogicalEnclosures.Count -gt 0) {
"<div class='card'><div class='sh'>🏗️ Logical Enclosures ($($LogicalEnclosures.Count))</div><table>
<tr><th>Name</th><th>Enclosure Group</th><th>Status</th></tr>
$($LERows -join "`n")</table></div>"
})
$(if ($Storage.Count -gt 0) {
"<div class='card'><div class='sh'>💾 Storage Systems ($($Storage.Count))</div><table>
<tr><th>Name</th><th>Model</th><th>Serial</th><th>Status</th></tr>
$($StorRows -join "`n")</table></div>"
})
$(if ($Firmware.Count -gt 0) {
"<div class='card'><div class='sh'>📦 Firmware Baselines ($($Firmware.Count))</div><table>
<tr><th>Name</th><th>Version</th><th>Release Date</th><th>Size</th></tr>
$($FwRows -join "`n")</table></div>"
})
<div class="footer">Generated by AsBuiltReport Manager &nbsp;·&nbsp; $GenDate &nbsp;·&nbsp; HPE OneView $Target</div>
</div></body></html>
"@

if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
$OutFile = Join-Path $OutputPath "HPEOneView.$(Get-Date -Format 'yyyy-MM-dd_HHmm').html"
$Html | Set-Content -Path $OutFile -Encoding UTF8
Write-Log "Report saved to $OutFile"
Disconnect-OVMgmt -ErrorAction SilentlyContinue | Out-Null
Write-Output "::DONE::$JobId"
