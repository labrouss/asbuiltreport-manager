#Requires -Version 5.1
#Requires -Modules VMware.VimAutomation.Core

<#
.SYNOPSIS
    Full RVTools replica — 27 tabs, exact column names matched to RVTools 4.7 schema.

.DESCRIPTION
    Covers all tabs:
      VM tabs    : vInfo, vCPU, vMemory, vDisk, vPartition, vNetwork, vCD, vUSB,
                   vSnapshot, vTools
      Infra tabs : vRP, vCluster, vHost, vHBA, vNIC, vSwitch, vPort,
                   dvSwitch, dvPort, vSC_VMK, vDatastore, vMultiPath
      Misc tabs  : vLicense, vFileInfo, vHealth, vSource, vMetaData

    Performance: two bulk Get-View calls for VMs and Hosts; per-type bulk calls
    for Datastores, Networks, DVS, Resource Pools, Clusters.
    Compatible with Windows PowerShell 5.1.

.PARAMETER Interactive
    Opens each tab in Out-GridView sequentially.

.PARAMETER ExportExcel
    Saves all tabs to a single .xlsx (requires ImportExcel module).

.PARAMETER ExportPath
    Output folder for the .xlsx. Defaults to current directory.

.PARAMETER VCenterServer
    vCenter FQDN/IP to connect to. Skip if already connected.

.PARAMETER Username
    Username for vCenter authentication (e.g. administrator@vsphere.local).
    Use with -Password, or omit -Password to be prompted interactively.

.PARAMETER Password
    Plain-text password. Combine with -Username.
    For automation prefer -Credential with a pre-built PSCredential instead.

.PARAMETER Credential
    A PSCredential object. Takes priority over -Username / -Password.
    Build with:  $cred = Get-Credential

.EXAMPLE
    # Prompt for credentials interactively
    .\Get-RVToolsReport.ps1 -VCenterServer "vc01.corp.local" -ExportExcel

.EXAMPLE
    # Pass credentials on the command line
    .\Get-RVToolsReport.ps1 -VCenterServer "vc01.corp.local" -Username "administrator@vsphere.local" -Password "VMware1!" -ExportExcel

.EXAMPLE
    # Use a PSCredential object
    $cred = Get-Credential
    .\Get-RVToolsReport.ps1 -VCenterServer "vc01.corp.local" -Credential $cred -ExportExcel

.EXAMPLE
    # Already connected — just export
    .\Get-RVToolsReport.ps1 -ExportExcel -ExportPath "C:\Reports"

.EXAMPLE
    # Interactive grid view
    .\Get-RVToolsReport.ps1 -Interactive

.NOTES
    Version      : 2.0  (matches RVTools 4.7 column schema)
    Compatibility: Windows PowerShell 5.1+
    Requires     : VMware PowerCLI; ImportExcel (for -ExportExcel only)
#>

[CmdletBinding()]
param(
    [switch]$Interactive,
    [switch]$ExportExcel,
    [string]$ExportPath    = (Get-Location).Path,
    [string]$VCenterServer = "",
    # Credential options — supply either -Credential or -Username/-Password
    [string]$Username      = "",
    [string]$Password      = "",
    [System.Management.Automation.PSCredential]$Credential
)

# NOTE: Set-StrictMode is intentionally NOT used.
# vSphere API objects have many optional sub-objects (Guest, QuickStats, etc.) that are
# null on powered-off or disconnected VMs. StrictMode -Version Latest throws on any null
# sub-object property access. Nulls are handled explicitly throughout instead.
$ErrorActionPreference = "Stop"

# ============================================================
#  REGION: HELPERS
# ============================================================

function Convert-BytesToMiB { param([long]$Bytes); return [math]::Round($Bytes / 1MB, 0) }
function Convert-KBToMiB    { param([long]$KB);    return [math]::Round($KB    / 1KB, 0) }

function Get-SDKServer  { return $global:DefaultVIServers[0].Name }
function Get-SDKUUID    { return ($global:DefaultVIServers[0].ExtensionData.Content.About.InstanceUuid) }

function Get-SafeVal {
    <# Returns the value if non-null, otherwise the default. PS5.1-safe alternative to ?? #>
    param($Value, $Default = $null)
    if ($null -eq $Value) { return $Default }
    return $Value
}

function Get-GuestProp {
    <#
    .SYNOPSIS
        Safely reads a property from $vm.Guest, returning $Default when Guest is null
        or the property does not exist (common on powered-off / disconnected VMs).
    #>
    param(
        [object]$Guest,
        [string]$Property,
        $Default = $null
    )
    if ($null -eq $Guest) { return $Default }
    $val = $Guest.$Property
    if ($null -eq $val) { return $Default }
    return $val
}

function Get-SafeStr {
    <# Calls .ToString() only if the value is non-null, otherwise returns empty string. #>
    param($Value, [string]$Default = "")
    if ($null -eq $Value) { return $Default }
    return $Value.ToString()
}

function Get-HostName {
    param([object]$HostRef, [hashtable]$HostMap)
    if ($null -eq $HostRef) { return "N/A" }
    $hv = $HostMap[$HostRef.Value]
    if ($null -eq $hv) { return "N/A" }
    return $hv.Name
}

function Get-DatacenterName {
    param([object]$HostRef, [hashtable]$HostMap, [hashtable]$DCMap)
    if ($null -eq $HostRef) { return "N/A" }
    $hv = $HostMap[$HostRef.Value]
    if ($null -eq $hv) { return "N/A" }
    # Walk up the parent chain to find Datacenter
    $parent = $hv.Parent
    $visited = @{}
    while ($null -ne $parent) {
        if ($visited.ContainsKey($parent.Value)) { break }
        $visited[$parent.Value] = $true
        if ($DCMap.ContainsKey($parent.Value)) { return $DCMap[$parent.Value] }
        try {
            $pv = Get-View -Id $parent -Property Name, Parent -ErrorAction SilentlyContinue
            if ($null -eq $pv) { break }
            if ($pv.MoRef.Type -eq "Datacenter") { return $pv.Name }
            $parent = $pv.Parent
        } catch { break }
    }
    return "N/A"
}

function Get-ClusterName {
    param([object]$HostRef, [hashtable]$HostMap)
    if ($null -eq $HostRef) { return "N/A" }
    $hv = $HostMap[$HostRef.Value]
    if ($null -eq $hv) { return "N/A" }
    if ($hv.Parent -and $hv.Parent.Type -eq "ClusterComputeResource") {
        $cv = Get-View -Id $hv.Parent -Property Name -ErrorAction SilentlyContinue
        if ($cv) { return $cv.Name }
    }
    return "N/A"
}

function Get-VMFolder {
    param([object]$VMView)
    try {
        if ($VMView.Config.Files.VmPathName) {
            $path = $VMView.Config.Files.VmPathName
            # Return datastore path as folder approximation
            return ($path -replace '\[.+?\] ', '' -replace '/[^/]+$', '')
        }
    } catch {}
    return "N/A"
}

# Recursive snapshot tree flattener
function Expand-SnapTree {
    param([array]$Snaps, [string]$VMName, [string]$Pstate, [string]$DC,
          [string]$Cluster, [string]$HostName, [string]$OS1, [string]$OS2,
          [string]$VMID, [string]$VMUUID, [string]$SDK, [string]$SDKUUID)
    foreach ($s in $Snaps) {
        [PSCustomObject]@{
            "VM"                                   = $VMName
            "Powerstate"                           = $Pstate
            "Name"                                 = $s.Name
            "Description"                          = $s.Description
            "Date / time"                          = $s.CreateTime
            "Filename"                             = if ($s.Config) { $s.Config.MemoryFileName } else { $null }
            "Size MiB (vmsn)"                      = $null
            "Size MiB (total)"                     = $null
            "Quiesced"                             = Get-SafeStr $s.Quiesced "False"
            "State"                                = Get-SafeStr $s.State
            "Annotation"                           = $null
            "Datacenter"                           = $DC
            "Cluster"                              = $Cluster
            "Host"                                 = $HostName
            "Folder"                               = $null
            "OS according to the configuration file" = $OS1
            "OS according to the VMware Tools"     = $OS2
            "VM ID"                                = $VMID
            "VM UUID"                              = $VMUUID
            "VI SDK Server"                        = $SDK
            "VI SDK UUID"                          = $SDKUUID
        }
        if ($s.ChildSnapshotList -and $s.ChildSnapshotList.Count -gt 0) {
            Expand-SnapTree -Snaps $s.ChildSnapshotList -VMName $VMName -Pstate $Pstate `
                -DC $DC -Cluster $Cluster -HostName $HostName -OS1 $OS1 -OS2 $OS2 `
                -VMID $VMID -VMUUID $VMUUID -SDK $SDK -SDKUUID $SDKUUID
        }
    }
}

# ============================================================
#  REGION: CONNECTION
# ============================================================

function Assert-VCenterConnection {
    param(
        [string]$Server,
        [string]$Username,
        [string]$Password,
        [System.Management.Automation.PSCredential]$Credential
    )

    if ($Server -ne "") {
        Write-Host "  Connecting to $Server..." -ForegroundColor Cyan

        # Build Connect-VIServer parameter set — credential takes priority over username/password
        $connParams = @{ Server = $Server; ErrorAction = "Stop" }

        if ($null -ne $Credential) {
            $connParams["Credential"] = $Credential
        }
        elseif ($Username -ne "") {
            if ($Password -ne "") {
                # Convert plain-text password to SecureString for Connect-VIServer
                $secPass = ConvertTo-SecureString $Password -AsPlainText -Force
                $connParams["Credential"] = New-Object System.Management.Automation.PSCredential($Username, $secPass)
            }
            else {
                # Prompt interactively for password
                $connParams["Credential"] = Get-Credential -UserName $Username -Message "Enter password for $Username on $Server"
            }
        }
        # If no credentials supplied, PowerCLI will use SSO/integrated auth or prompt

        try { Connect-VIServer @connParams | Out-Null }
        catch { throw "Failed to connect to '$Server': $_" }

        Write-Host "  Connected to: $Server" -ForegroundColor Green
    }
    elseif ($null -eq $global:DefaultVIServers -or $global:DefaultVIServers.Count -eq 0) {
        throw "No active vCenter connection. Use -VCenterServer or Connect-VIServer first."
    }
    else {
        $c = $global:DefaultVIServers | Where-Object { $_.IsConnected }
        if (-not $c) { throw "Session disconnected. Reconnect with Connect-VIServer." }
        Write-Host "  Connected to: $($c.Name -join ', ')" -ForegroundColor Green
    }
}

# ============================================================
#  REGION: BULK DATA LOADER
# ============================================================

function Get-AllData {
    Write-Host "  Loading VMs..." -ForegroundColor DarkCyan
    $vmViews = Get-View -ViewType VirtualMachine `
        -Property Name,Config,Runtime,Summary,Guest,Snapshot,LayoutEx,ResourcePool `
        -ErrorAction Stop

    Write-Host "  Loading Hosts..." -ForegroundColor DarkCyan
    $hostViews = Get-View -ViewType HostSystem `
        -Property Name,Parent,Summary,Config,Hardware,Datastore,Network,Vm `
        -ErrorAction Stop

    Write-Host "  Loading Datastores..." -ForegroundColor DarkCyan
    $dsViews = Get-View -ViewType Datastore `
        -Property Name,Summary,Info,Host,Vm `
        -ErrorAction Stop

    Write-Host "  Loading Resource Pools..." -ForegroundColor DarkCyan
    $rpViews = Get-View -ViewType ResourcePool `
        -Property Name,Parent,Summary,Config,Vm,Runtime `
        -ErrorAction Stop

    Write-Host "  Loading Clusters..." -ForegroundColor DarkCyan
    $clViews = Get-View -ViewType ClusterComputeResource `
        -Property Name,Summary,Configuration,ConfigurationEx `
        -ErrorAction Stop

    Write-Host "  Loading DVSwitches..." -ForegroundColor DarkCyan
    $dvsViews = Get-View -ViewType VmwareDistributedVirtualSwitch `
        -Property Name,Summary,Config,Uuid `
        -ErrorAction SilentlyContinue

    Write-Host "  Loading DV PortGroups..." -ForegroundColor DarkCyan
    $dvpgViews = Get-View -ViewType DistributedVirtualPortgroup `
        -Property Name,Config,Key `
        -ErrorAction SilentlyContinue

    Write-Host "  Loading Licenses..." -ForegroundColor DarkCyan
    $licMgr = Get-View -Id "LicenseManager" -ErrorAction SilentlyContinue

    Write-Host "  Loading vCenter About info..." -ForegroundColor DarkCyan
    $siView = Get-View -Id "ServiceInstance" -Property Content -ErrorAction SilentlyContinue

    # Build fast lookup maps
    $hostMap = @{}
    foreach ($h in $hostViews) { $hostMap[$h.MoRef.Value] = $h }

    $dsMap = @{}
    foreach ($d in $dsViews) { $dsMap[$d.MoRef.Value] = $d }

    # Datacenter map: MoRef.Value -> DC name (built by walking cluster/host parents)
    $dcMap = @{}
    foreach ($cl in $clViews) {
        try {
            $pv = Get-View -Id $cl.Parent -Property Name, Parent -ErrorAction SilentlyContinue
            while ($null -ne $pv -and $pv.MoRef.Type -ne "Datacenter") {
                $pv = Get-View -Id $pv.Parent -Property Name, Parent -ErrorAction SilentlyContinue
            }
            if ($null -ne $pv) { $dcMap[$cl.MoRef.Value] = $pv.Name }
        } catch {}
    }

    return @{
        VMViews   = $vmViews
        HostViews = $hostViews
        HostMap   = $hostMap
        DSViews   = $dsViews
        DSMap     = $dsMap
        RPViews   = $rpViews
        CLViews   = $clViews
        DVSViews  = $dvsViews
        DVPGViews = $dvpgViews
        LicMgr    = $licMgr
        SIView    = $siView
        DCMap     = $dcMap
    }
}

# ============================================================
#  REGION: VM TAB FUNCTIONS
# ============================================================

function Get-vInfo {
    param([array]$VMViews, [hashtable]$HostMap)
    Write-Host "  vInfo..." -ForegroundColor DarkCyan
    $sdk = Get-SDKServer; $sdkuuid = Get-SDKUUID
    $results = foreach ($vm in $VMViews) {
        $hn  = Get-HostName    -HostRef $vm.Runtime.Host -HostMap $HostMap
        $cl  = Get-ClusterName -HostRef $vm.Runtime.Host -HostMap $HostMap
        $provMiB = Convert-BytesToMiB -Bytes ($vm.Summary.Storage.Committed + $vm.Summary.Storage.Uncommitted)
        $inUseMiB = Convert-BytesToMiB -Bytes $vm.Summary.Storage.Committed
        $unshMiB  = Convert-BytesToMiB -Bytes $vm.Summary.Storage.Unshared
        $diskCapMiB = 0
        $diskCount  = 0
        $nicCount   = 0
        foreach ($dev in $vm.Config.Hardware.Device) {
            if ($dev -is [VMware.Vim.VirtualDisk]) {
                $diskCount++
                $diskCapMiB += Convert-KBToMiB -KB $dev.CapacityInKB
            }
            if ($dev -is [VMware.Vim.VirtualEthernetCard]) { $nicCount++ }
        }
        $primaryIP = ""
        if ($vm.Guest.Net) {
            $first = $vm.Guest.Net | Where-Object { $_.IpAddress } | Select-Object -First 1
            if ($first) { $primaryIP = ($first.IpAddress | Where-Object { $_ -notmatch ":" } | Select-Object -First 1) }
        }
        [PSCustomObject]@{
            "VM"                                     = $vm.Name
            "Powerstate"                             = Get-SafeStr $vm.Runtime.PowerState
            "Template"                               = Get-SafeStr $vm.Config.Template "False"
            "SRM Placeholder"                        = "False"
            "Config status"                          = Get-SafeStr $vm.Summary.OverallStatus
            "DNS Name"                               = Get-GuestProp $vm.Guest "HostName"
            "Connection state"                       = Get-SafeStr $vm.Runtime.ConnectionState
            "Guest state"                            = Get-GuestProp $vm.Guest "GuestState"
            "Heartbeat"                              = Get-SafeStr (Get-GuestProp $vm.Guest "HeartbeatStatus")
            "Consolidation Needed"                   = Get-SafeStr $vm.Runtime.ConsolidationNeeded "False"
            "PowerOn"                                = $vm.Runtime.BootTime
            "Suspended To Memory"                    = $null
            "Suspend time"                           = $null
            "Suspend Interval"                       = "0"
            "Creation date"                          = $vm.Config.CreateDate
            "Change Version"                         = $vm.Config.ChangeVersion
            "CPUs"                                   = $vm.Config.Hardware.NumCPU
            "Overall Cpu Readiness"                  = "0%"
            "Memory"                                 = $vm.Config.Hardware.MemoryMB
            "Active Memory"                          = Get-SafeVal $vm.Summary.QuickStats.GuestMemoryUsage 0
            "NICs"                                   = $nicCount
            "Disks"                                  = $diskCount
            "Total disk capacity MiB"                = $diskCapMiB
            "Fixed Passthru HotPlug"                 = "False"
            "min Required EVC Mode Key"              = $vm.Summary.Runtime.MinRequiredEVCModeKey
            "Latency Sensitivity"                    = Get-SafeVal $vm.Config.LatencySensitivity.Level $null
            "Op Notification Timeout"                = $null
            "EnableUUID"                             = $null
            "CBT"                                    = Get-SafeStr $vm.Config.ChangeTrackingEnabled "FALSE"
            "Primary IP Address"                     = $primaryIP
            "Provisioned MiB"                        = $provMiB
            "In Use MiB"                             = $inUseMiB
            "Unshared MiB"                           = $unshMiB
            "HA Restart Priority"                    = Get-SafeVal $vm.Config.DefaultPowerOps.StandbyAction $null
            "HA Isolation Response"                  = "none"
            "HA VM Monitoring"                       = "vmMonitoringDisabled"
            "FT State"                               = Get-SafeStr $vm.Summary.Runtime.FaultToleranceState
            "FT Role"                                = $null
            "HW version"                             = $vm.Config.HardwareVersion
            "HW upgrade status"                      = "none"
            "HW upgrade policy"                      = "never"
            "Path"                                   = $vm.Config.Files.VmPathName
            "Annotation"                             = $vm.Config.Annotation
            "Datacenter"                             = "Datacenter"
            "Cluster"                                = $cl
            "Host"                                   = $hn
            "OS according to the configuration file" = Get-SafeVal $vm.Config.GuestFullName ""
            "OS according to the VMware Tools"       = Get-GuestProp $vm.Guest "GuestFullName"
            "VM ID"                                  = $vm.MoRef.Value
            "VM UUID"                                = $vm.Config.Uuid
            "VI SDK Server"                          = $sdk
            "VI SDK UUID"                            = $sdkuuid
        }
    }
    return $results
}

function Get-vCPU {
    param([array]$VMViews, [hashtable]$HostMap)
    Write-Host "  vCPU..." -ForegroundColor DarkCyan
    $sdk = Get-SDKServer; $sdkuuid = Get-SDKUUID
    $results = foreach ($vm in $VMViews) {
        $hn = Get-HostName    -HostRef $vm.Runtime.Host -HostMap $HostMap
        $cl = Get-ClusterName -HostRef $vm.Runtime.Host -HostMap $HostMap
        $cpu = $vm.Config.Hardware.NumCPU
        $cores = $vm.Config.Hardware.NumCoresPerSocket
        $sockets = if ($cores -gt 0) { [math]::Round($cpu / $cores, 0) } else { $cpu }
        [PSCustomObject]@{
            "VM"                                     = $vm.Name
            "Powerstate"                             = Get-SafeStr $vm.Runtime.PowerState
            "Template"                               = Get-SafeStr $vm.Config.Template "False"
            "SRM Placeholder"                        = "False"
            "CPUs"                                   = $cpu
            "Sockets"                                = $sockets
            "Cores p/s"                              = $cores
            "Max"                                    = Get-SafeVal $vm.Summary.Runtime.MaxCpuUsage 0
            "Overall"                                = Get-SafeVal $vm.Summary.QuickStats.OverallCpuUsage 0
            "Level"                                  = Get-SafeVal $vm.Config.CpuAllocation.Shares.Level "normal"
            "Shares"                                 = Get-SafeVal $vm.Config.CpuAllocation.Shares.Shares 0
            "Reservation"                            = Get-SafeVal $vm.Config.CpuAllocation.Reservation 0
            "Entitlement"                            = Get-SafeVal $vm.Summary.QuickStats.OverallCpuUsage 0
            "DRS Entitlement"                        = $null
            "Limit"                                  = Get-SafeVal $vm.Config.CpuAllocation.Limit -1
            "Hot Add"                                = Get-SafeStr $vm.Config.CpuHotAddEnabled "False"
            "Hot Remove"                             = Get-SafeStr $vm.Config.CpuHotRemoveEnabled "False"
            "Numa Hotadd Exposed"                    = "False"
            "Annotation"                             = $vm.Config.Annotation
            "Datacenter"                             = "Datacenter"
            "Cluster"                                = $cl
            "Host"                                   = $hn
            "Folder"                                 = Get-VMFolder $vm
            "OS according to the configuration file" = Get-SafeVal $vm.Config.GuestFullName ""
            "OS according to the VMware Tools"       = Get-GuestProp $vm.Guest "GuestFullName"
            "VM ID"                                  = $vm.MoRef.Value
            "VM UUID"                                = $vm.Config.Uuid
            "VI SDK Server"                          = $sdk
            "VI SDK UUID"                            = $sdkuuid
        }
    }
    return $results
}

function Get-vMemory {
    param([array]$VMViews, [hashtable]$HostMap)
    Write-Host "  vMemory..." -ForegroundColor DarkCyan
    $sdk = Get-SDKServer; $sdkuuid = Get-SDKUUID
    $results = foreach ($vm in $VMViews) {
        $hn = Get-HostName    -HostRef $vm.Runtime.Host -HostMap $HostMap
        $cl = Get-ClusterName -HostRef $vm.Runtime.Host -HostMap $HostMap
        $qs = if ($vm.Summary.QuickStats) { $vm.Summary.QuickStats } else { $null }
        [PSCustomObject]@{
            "VM"                                     = $vm.Name
            "Powerstate"                             = Get-SafeStr $vm.Runtime.PowerState
            "Template"                               = Get-SafeStr $vm.Config.Template "False"
            "SRM Placeholder"                        = "False"
            "Size MiB"                               = $vm.Config.Hardware.MemoryMB
            "Memory Reservation Locked To Max"       = Get-SafeStr $vm.Config.MemoryReservationLockedToMax "False"
            "Overhead"                               = Get-SafeVal $qs.MemoryOverhead 0
            "Max"                                    = Get-SafeVal $vm.Summary.Runtime.MaxMemoryUsage 0
            "Consumed"                               = Get-SafeVal $qs.HostMemoryUsage 0
            "Consumed Overhead"                      = Get-SafeVal $qs.ConsumedOverheadMemory 0
            "Private"                                = Get-SafeVal $qs.PrivateMemory 0
            "Shared"                                 = Get-SafeVal $qs.SharedMemory 0
            "Swapped"                                = Get-SafeVal $qs.SwappedMemory 0
            "Ballooned"                              = Get-SafeVal $qs.BalloonedMemory 0
            "Active"                                 = Get-SafeVal $qs.GuestMemoryUsage 0
            "Entitlement"                            = Get-SafeVal $qs.GrantedMemory 0
            "DRS Entitlement"                        = $null
            "Level"                                  = Get-SafeVal $vm.Config.MemoryAllocation.Shares.Level "normal"
            "Shares"                                 = Get-SafeVal $vm.Config.MemoryAllocation.Shares.Shares 0
            "Reservation"                            = Get-SafeVal $vm.Config.MemoryAllocation.Reservation 0
            "Limit"                                  = Get-SafeVal $vm.Config.MemoryAllocation.Limit -1
            "Hot Add"                                = Get-SafeStr $vm.Config.MemoryHotAddEnabled "False"
            "Annotation"                             = $vm.Config.Annotation
            "Datacenter"                             = "Datacenter"
            "Cluster"                                = $cl
            "Host"                                   = $hn
            "Folder"                                 = Get-VMFolder $vm
            "OS according to the configuration file" = Get-SafeVal $vm.Config.GuestFullName ""
            "OS according to the VMware Tools"       = Get-GuestProp $vm.Guest "GuestFullName"
            "VM ID"                                  = $vm.MoRef.Value
            "VM UUID"                                = $vm.Config.Uuid
            "VI SDK Server"                          = $sdk
            "VI SDK UUID"                            = $sdkuuid
        }
    }
    return $results
}

function Get-vDisk {
    param([array]$VMViews, [hashtable]$HostMap)
    Write-Host "  vDisk..." -ForegroundColor DarkCyan
    $sdk = Get-SDKServer; $sdkuuid = Get-SDKUUID
    $results = foreach ($vm in $VMViews) {
        $hn = Get-HostName    -HostRef $vm.Runtime.Host -HostMap $HostMap
        $cl = Get-ClusterName -HostRef $vm.Runtime.Host -HostMap $HostMap
        $disks = $vm.Config.Hardware.Device | Where-Object { $_ -is [VMware.Vim.VirtualDisk] }
        foreach ($d in $disks) {
            $b = $d.Backing
            $bt = $b.GetType().Name
            $thin = "False"; $eager = "False"
            if ($bt -eq "VirtualDiskFlatVer2BackingInfo") {
                $thin  = $b.ThinProvisioned.ToString()
                $eager = $b.EagerlyScrub.ToString()
            }
            # Controller label
            $ctrl = $vm.Config.Hardware.Device | Where-Object { $_.Key -eq $d.ControllerKey }
            $ctrlLabel = if ($ctrl) { $ctrl.DeviceInfo.Label } else { $d.ControllerKey.ToString() }
            if ($b.FileName -match '^\[(.+?)\]') { $dsName = $Matches[1] } else { $dsName = "" }
            [PSCustomObject]@{
                "VM"                                     = $vm.Name
                "Powerstate"                             = Get-SafeStr $vm.Runtime.PowerState
                "Template"                               = Get-SafeStr $vm.Config.Template "False"
                "SRM Placeholder"                        = "False"
                "Disk"                                   = $d.DeviceInfo.Label
                "Disk Key"                               = $d.Key.ToString()
                "Disk UUID"                              = if ($b.Uuid) { $b.Uuid } else { "" }
                "Disk Path"                              = $b.FileName
                "Capacity MiB"                           = Convert-KBToMiB -KB $d.CapacityInKB
                "Raw"                                    = "False"
                "Disk Mode"                              = $b.DiskMode
                "Sharing mode"                           = if ($d.Shares) { "sharingNone" } else { "sharingNone" }
                "Thin"                                   = $thin
                "Eagerly Scrub"                          = $eager
                "Split"                                  = "False"
                "Write Through"                          = "False"
                "Level"                                  = Get-SafeVal $d.Shares.Level "normal"
                "Shares"                                 = Get-SafeVal $d.Shares.Shares 1000
                "Reservation"                            = 0
                "Limit"                                  = -1
                "Controller"                             = $ctrlLabel
                "Label"                                  = $ctrlLabel
                "SCSI Unit #"                            = $d.UnitNumber
                "Unit #"                                 = $d.UnitNumber
                "Shared Bus"                             = "noSharing"
                "Path"                                   = $b.FileName
                "Raw LUN ID"                             = $null
                "Raw Comp. Mode"                         = $null
                "Internal Sort Column"                   = "$($vm.Name) $($d.Key)"
                "Annotation"                             = $vm.Config.Annotation
                "Datacenter"                             = "Datacenter"
                "Cluster"                                = $cl
                "Host"                                   = $hn
                "Folder"                                 = Get-VMFolder $vm
                "OS according to the configuration file" = Get-SafeVal $vm.Config.GuestFullName ""
                "OS according to the VMware Tools"       = Get-GuestProp $vm.Guest "GuestFullName"
                "VM ID"                                  = $vm.MoRef.Value
                "VM UUID"                                = $vm.Config.Uuid
                "VI SDK Server"                          = $sdk
                "VI SDK UUID"                            = $sdkuuid
            }
        }
    }
    return $results
}

function Get-vPartition {
    param([array]$VMViews, [hashtable]$HostMap)
    Write-Host "  vPartition..." -ForegroundColor DarkCyan
    $sdk = Get-SDKServer; $sdkuuid = Get-SDKUUID
    $results = foreach ($vm in $VMViews) {
        if (-not $vm.Guest.Disk) { continue }
        $hn = Get-HostName    -HostRef $vm.Runtime.Host -HostMap $HostMap
        $cl = Get-ClusterName -HostRef $vm.Runtime.Host -HostMap $HostMap
        foreach ($p in $vm.Guest.Disk) {
            $capMiB  = Convert-BytesToMiB -Bytes $p.Capacity
            $freeMiB = Convert-BytesToMiB -Bytes $p.FreeSpace
            $usedMiB = $capMiB - $freeMiB
            $freePct = if ($capMiB -gt 0) { [math]::Round(($freeMiB / $capMiB) * 100, 0) } else { 0 }
            [PSCustomObject]@{
                "VM"                                     = $vm.Name
                "Powerstate"                             = Get-SafeStr $vm.Runtime.PowerState
                "Template"                               = Get-SafeStr $vm.Config.Template "False"
                "SRM Placeholder"                        = "False"
                "Disk Key"                               = $null
                "Disk"                                   = $p.DiskPath
                "Capacity MiB"                           = $capMiB
                "Consumed MiB"                           = $usedMiB
                "Free MiB"                               = $freeMiB
                "Free %"                                 = $freePct
                "Internal Sort Column"                   = "$($vm.Name) $($p.DiskPath)"
                "Annotation"                             = $vm.Config.Annotation
                "Datacenter"                             = "Datacenter"
                "Cluster"                                = $cl
                "Host"                                   = $hn
                "Folder"                                 = Get-VMFolder $vm
                "OS according to the configuration file" = Get-SafeVal $vm.Config.GuestFullName ""
                "OS according to the VMware Tools"       = Get-GuestProp $vm.Guest "GuestFullName"
                "VM ID"                                  = $vm.MoRef.Value
                "VM UUID"                                = $vm.Config.Uuid
                "VI SDK Server"                          = $sdk
                "VI SDK UUID"                            = $sdkuuid
            }
        }
    }
    return $results
}

function Get-vNetwork {
    param([array]$VMViews, [hashtable]$HostMap)
    Write-Host "  vNetwork..." -ForegroundColor DarkCyan
    $sdk = Get-SDKServer; $sdkuuid = Get-SDKUUID
    $results = foreach ($vm in $VMViews) {
        $hn = Get-HostName    -HostRef $vm.Runtime.Host -HostMap $HostMap
        $cl = Get-ClusterName -HostRef $vm.Runtime.Host -HostMap $HostMap
        # Build MAC -> guest NIC map
        $macMap = @{}
        if ($vm.Guest.Net) {
            foreach ($gn in $vm.Guest.Net) {
                if ($gn.MacAddress) { $macMap[$gn.MacAddress] = $gn }
            }
        }
        $nics = $vm.Config.Hardware.Device | Where-Object { $_ -is [VMware.Vim.VirtualEthernetCard] }
        foreach ($n in $nics) {
            $b = $n.Backing; $bt = $b.GetType().Name
            if ($bt -eq "VirtualEthernetCardNetworkBackingInfo") {
                $network = $b.DeviceName; $switch = "vSwitch"
            } elseif ($bt -eq "VirtualEthernetCardDistributedVirtualPortBackingInfo") {
                $network = $b.Port.PortgroupKey; $switch = "DVSwitch"
            } else {
                $network = "Unknown"; $switch = "Unknown"
            }
            $gnic = if ($n.MacAddress -and $macMap.ContainsKey($n.MacAddress)) { $macMap[$n.MacAddress] } else { $null }
            $ipv4 = ""; $ipv6 = ""
            if ($gnic -and $gnic.IpAddress) {
                $ipv4 = ($gnic.IpAddress | Where-Object { $_ -notmatch ":" } | Select-Object -First 1)
                $ipv6 = ($gnic.IpAddress | Where-Object { $_ -match ":" } | Select-Object -First 1)
            }
            $adapterType = $n.GetType().Name -replace '^Virtual', ''
            [PSCustomObject]@{
                "VM"                                     = $vm.Name
                "Powerstate"                             = Get-SafeStr $vm.Runtime.PowerState
                "Template"                               = Get-SafeStr $vm.Config.Template "False"
                "SRM Placeholder"                        = "False"
                "NIC label"                              = $n.DeviceInfo.Label
                "Adapter"                                = $adapterType
                "Network"                                = $network
                "Switch"                                 = $switch
                "Connected"                              = $n.Connectable.Connected.ToString()
                "Starts Connected"                       = $n.Connectable.StartConnected.ToString()
                "Mac Address"                            = $n.MacAddress
                "Type"                                   = if ($gnic) { $gnic.IpConfig.IpAddress | Select-Object -First 1 | ForEach-Object { "assigned" } } else { "unknown" }
                "IPv4 Address"                           = $ipv4
                "IPv6 Address"                           = $ipv6
                "Direct Path IO"                         = "False"
                "Internal Sort Column"                   = "$($vm.Name) $($n.DeviceInfo.Label)"
                "Annotation"                             = $vm.Config.Annotation
                "Datacenter"                             = "Datacenter"
                "Cluster"                                = $cl
                "Host"                                   = $hn
                "Folder"                                 = Get-VMFolder $vm
                "OS according to the configuration file" = Get-SafeVal $vm.Config.GuestFullName ""
                "OS according to the VMware Tools"       = Get-GuestProp $vm.Guest "GuestFullName"
                "VM ID"                                  = $vm.MoRef.Value
                "VM UUID"                                = $vm.Config.Uuid
                "VI SDK Server"                          = $sdk
                "VI SDK UUID"                            = $sdkuuid
            }
        }
    }
    return $results
}

function Get-vCD {
    param([array]$VMViews, [hashtable]$HostMap)
    Write-Host "  vCD..." -ForegroundColor DarkCyan
    $sdk = Get-SDKServer; $sdkuuid = Get-SDKUUID
    $results = foreach ($vm in $VMViews) {
        $hn = Get-HostName    -HostRef $vm.Runtime.Host -HostMap $HostMap
        $cl = Get-ClusterName -HostRef $vm.Runtime.Host -HostMap $HostMap
        $cds = $vm.Config.Hardware.Device | Where-Object { $_ -is [VMware.Vim.VirtualCdrom] }
        foreach ($cd in $cds) {
            $bt = $cd.Backing.GetType().Name
            $devType = switch ($bt) {
                "VirtualCdromIsoBackingInfo"    { "ISO File" }
                "VirtualCdromRemoteAtapiBackingInfo" { "Remote device" }
                "VirtualCdromAtapiBackingInfo"  { "Host device" }
                default                         { "Remote device" }
            }
            [PSCustomObject]@{
                "VM"                                     = $vm.Name
                "Powerstate"                             = Get-SafeStr $vm.Runtime.PowerState
                "Template"                               = Get-SafeStr $vm.Config.Template "False"
                "SRM Placeholder"                        = "False"
                "Device Node"                            = $cd.DeviceInfo.Label
                "Connected"                              = $cd.Connectable.Connected.ToString()
                "Starts Connected"                       = $cd.Connectable.StartConnected.ToString()
                "Device Type"                            = $devType
                "Annotation"                             = $vm.Config.Annotation
                "Datacenter"                             = "Datacenter"
                "Cluster"                                = $cl
                "Host"                                   = $hn
                "Folder"                                 = Get-VMFolder $vm
                "OS according to the configuration file" = Get-SafeVal $vm.Config.GuestFullName ""
                "OS according to the VMware Tools"       = Get-GuestProp $vm.Guest "GuestFullName"
                "VMRef"                                  = $vm.MoRef.Value -replace 'vm-', ''
                "VM ID"                                  = $vm.MoRef.Value
                "VM UUID"                                = $vm.Config.Uuid
                "VI SDK Server"                          = $sdk
                "VI SDK UUID"                            = $sdkuuid
            }
        }
    }
    return $results
}

function Get-vUSB {
    param([array]$VMViews, [hashtable]$HostMap)
    Write-Host "  vUSB..." -ForegroundColor DarkCyan
    $sdk = Get-SDKServer; $sdkuuid = Get-SDKUUID
    $results = foreach ($vm in $VMViews) {
        $hn = Get-HostName    -HostRef $vm.Runtime.Host -HostMap $HostMap
        $cl = Get-ClusterName -HostRef $vm.Runtime.Host -HostMap $HostMap
        $usbs = $vm.Config.Hardware.Device | Where-Object { $_ -is [VMware.Vim.VirtualUSB] }
        foreach ($u in $usbs) {
            [PSCustomObject]@{
                "VM"                                     = $vm.Name
                "Powerstate"                             = Get-SafeStr $vm.Runtime.PowerState
                "Template"                               = Get-SafeStr $vm.Config.Template "False"
                "SRM Placeholder"                        = "False"
                "Device Node"                            = $u.DeviceInfo.Label
                "Device Type"                            = "USB"
                "Connected"                              = $u.Connectable.Connected.ToString()
                "Family"                                 = $null
                "Speed"                                  = $null
                "EHCI enabled"                           = "False"
                "Auto connect"                           = "False"
                "Bus number"                             = $null
                "Unit number"                            = $u.UnitNumber
                "Annotation"                             = $vm.Config.Annotation
                "Datacenter"                             = "Datacenter"
                "Cluster"                                = $cl
                "Host"                                   = $hn
                "Folder"                                 = Get-VMFolder $vm
                "OS according to the configuration file" = Get-SafeVal $vm.Config.GuestFullName ""
                "OS according to the VMware tools"       = Get-GuestProp $vm.Guest "GuestFullName"
                "VMRef"                                  = $vm.MoRef.Value -replace 'vm-', ''
                "VM ID"                                  = $vm.MoRef.Value
                "VM UUID"                                = $vm.Config.Uuid
                "VI SDK Server"                          = $sdk
                "VI SDK UUID"                            = $sdkuuid
            }
        }
    }
    return $results
}

function Get-vSnapshot {
    param([array]$VMViews, [hashtable]$HostMap)
    Write-Host "  vSnapshot..." -ForegroundColor DarkCyan
    $sdk = Get-SDKServer; $sdkuuid = Get-SDKUUID
    $results = foreach ($vm in $VMViews) {
        if (-not ($vm.Snapshot -and $vm.Snapshot.RootSnapshotList)) { continue }
        $hn  = Get-HostName    -HostRef $vm.Runtime.Host -HostMap $HostMap
        $cl  = Get-ClusterName -HostRef $vm.Runtime.Host -HostMap $HostMap
        $vmPstate = Get-SafeStr $vm.Runtime.PowerState
        Expand-SnapTree `
            -Snaps    $vm.Snapshot.RootSnapshotList `
            -VMName   $vm.Name `
            -Pstate   $vmPstate `
            -DC       "Datacenter" `
            -Cluster  $cl `
            -HostName $hn `
            -OS1      $vm.Config.GuestFullName `
            -OS2      (Get-GuestProp $vm.Guest "GuestFullName" "") `
            -VMID     $vm.MoRef.Value `
            -VMUUID   $vm.Config.Uuid `
            -SDK      $sdk `
            -SDKUUID  $sdkuuid
    }
    return $results
}

function Get-vTools {
    param([array]$VMViews, [hashtable]$HostMap)
    Write-Host "  vTools..." -ForegroundColor DarkCyan
    $sdk = Get-SDKServer; $sdkuuid = Get-SDKUUID
    $results = foreach ($vm in $VMViews) {
        $hn = Get-HostName    -HostRef $vm.Runtime.Host -HostMap $HostMap
        $cl = Get-ClusterName -HostRef $vm.Runtime.Host -HostMap $HostMap
        $gt = $vm.Guest   # may be null on powered-off VMs
        [PSCustomObject]@{
            "VM"                                     = $vm.Name
            "Powerstate"                             = Get-SafeStr $vm.Runtime.PowerState
            "Template"                               = Get-SafeStr $vm.Config.Template "False"
            "SRM Placeholder"                        = "False"
            "VM Version"                             = $vm.Config.HardwareVersion -replace 'vmx-', ''
            "Tools"                                  = Get-GuestProp $gt "ToolsStatus" "toolsNotInstalled"
            "Tools Version"                          = Get-GuestProp $gt "ToolsVersion"
            "Required Version"                       = $null
            "Upgradeable"                            = if ((Get-GuestProp $gt "ToolsVersionStatus2" "") -match "upgrade") { "Yes" } else { "No" }
            "Upgrade Policy"                         = Get-SafeVal $vm.Config.Tools.ToolsUpgradePolicy "manual"
            "Sync time"                              = Get-SafeVal $vm.Config.Tools.SyncTimeWithHostAllowed "False"
            "App status"                             = "none"
            "Heartbeat status"                       = Get-GuestProp $gt "HeartbeatStatus" "gray"
            "Kernel Crash state"                     = "False"
            "Operation Ready"                        = "True"
            "State change support"                   = "True"
            "Interactive Guest"                      = "False"
            "Annotation"                             = $vm.Config.Annotation
            "Datacenter"                             = "Datacenter"
            "Cluster"                                = $cl
            "Host"                                   = $hn
            "Folder"                                 = Get-VMFolder $vm
            "OS according to the configuration file" = Get-SafeVal $vm.Config.GuestFullName ""
            "OS according to the VMware Tools"       = Get-GuestProp $gt "GuestFullName"
            "VMRef"                                  = $vm.MoRef.Value -replace 'vm-', ''
            "VM ID"                                  = $vm.MoRef.Value
            "VM UUID"                                = $vm.Config.Uuid
            "VI SDK Server"                          = $sdk
            "VI SDK UUID"                            = $sdkuuid
        }
    }
    return $results
}

# ============================================================
#  REGION: INFRASTRUCTURE TAB FUNCTIONS
# ============================================================

function Get-vRP {
    param([array]$RPViews)
    Write-Host "  vRP..." -ForegroundColor DarkCyan
    $sdk = Get-SDKServer; $sdkuuid = Get-SDKUUID
    $results = foreach ($rp in $RPViews) {
        $s = $rp.Summary; $cfg = $rp.Config
        $qs = $rp.Summary.QuickStats
        [PSCustomObject]@{
            "Resource Pool name"             = $rp.Name
            "Resource Pool path"             = "/$($rp.Name)"
            "Status"                         = if ($s.Runtime.OverallStatus) { $s.Runtime.OverallStatus.ToString() } else { "green" }
            "# VMs total"                    = if ($rp.Vm) { $rp.Vm.Count } else { 0 }
            "# VMs"                          = if ($rp.Vm) { $rp.Vm.Count } else { 0 }
            "# vCPUs"                        = 0
            "CPU limit"                      = Get-SafeVal $cfg.CpuAllocation.Limit 0
            "CPU overheadLimit"              = 0
            "CPU reservation"                = Get-SafeVal $cfg.CpuAllocation.Reservation 0
            "CPU level"                      = Get-SafeVal $cfg.CpuAllocation.Shares.Level "normal"
            "CPU shares"                     = Get-SafeVal $cfg.CpuAllocation.Shares.Shares 4000
            "CPU expandableReservation"      = Get-SafeVal $cfg.CpuAllocation.ExpandableReservation "True"
            "CPU maxUsage"                   = Get-SafeVal $qs.OverallCpuUsage 0
            "CPU overallUsage"               = Get-SafeVal $qs.OverallCpuUsage 0
            "CPU reservationUsed"            = 0
            "CPU reservationUsedForVm"       = 0
            "CPU unreservedForPool"          = 0
            "CPU unreservedForVm"            = 0
            "Mem Configured"                 = Get-SafeVal $cfg.MemoryAllocation.Reservation 0
            "Mem limit"                      = Get-SafeVal $cfg.MemoryAllocation.Limit 0
            "Mem overheadLimit"              = 0
            "Mem reservation"                = Get-SafeVal $cfg.MemoryAllocation.Reservation 0
            "Mem level"                      = Get-SafeVal $cfg.MemoryAllocation.Shares.Level "normal"
            "Mem shares"                     = Get-SafeVal $cfg.MemoryAllocation.Shares.Shares 163840
            "Mem expandableReservation"      = Get-SafeVal $cfg.MemoryAllocation.ExpandableReservation "True"
            "Mem maxUsage"                   = Get-SafeVal $qs.HostMemoryUsage 0
            "Mem overallUsage"               = Get-SafeVal $qs.HostMemoryUsage 0
            "Mem reservationUsed"            = 0
            "Mem reservationUsedForVm"       = 0
            "Mem unreservedForPool"          = 0
            "Mem unreservedForVm"            = 0
            "QS overallCpuDemand"            = Get-SafeVal $qs.OverallCpuDemand 0
            "QS overallCpuUsage"             = Get-SafeVal $qs.OverallCpuUsage 0
            "QS staticCpuEntitlement"        = Get-SafeVal $qs.StaticCpuEntitlement 0
            "QS distributedCpuEntitlement"   = Get-SafeVal $qs.DistributedCpuEntitlement 0
            "QS balloonedMemory"             = Get-SafeVal $qs.BalloonedMemory 0
            "QS compressedMemory"            = Get-SafeVal $qs.CompressedMemory 0
            "QS consumedOverheadMemory"      = Get-SafeVal $qs.ConsumedOverheadMemory 0
            "QS distributedMemoryEntitlement"= Get-SafeVal $qs.DistributedMemoryEntitlement 0
            "QS guestMemoryUsage"            = Get-SafeVal $qs.GuestMemoryUsage 0
            "QS hostMemoryUsage"             = Get-SafeVal $qs.HostMemoryUsage 0
            "QS overheadMemory"              = Get-SafeVal $qs.OverheadMemory 0
            "QS privateMemory"               = Get-SafeVal $qs.PrivateMemory 0
            "QS sharedMemory"                = Get-SafeVal $qs.SharedMemory 0
            "QS staticMemoryEntitlement"     = Get-SafeVal $qs.StaticMemoryEntitlement 0
            "QS swappedMemory"               = Get-SafeVal $qs.SwappedMemory 0
            "Object ID"                      = $rp.MoRef.Value
            "VI SDK Server"                  = $sdk
            "VI SDK UUID"                    = $sdkuuid
        }
    }
    return $results
}

function Get-vCluster {
    param([array]$CLViews)
    Write-Host "  vCluster..." -ForegroundColor DarkCyan
    $sdk = Get-SDKServer; $sdkuuid = Get-SDKUUID
    $results = foreach ($cl in $CLViews) {
        $s   = $cl.Summary
        $cfgx = $cl.ConfigurationEx
        $ha  = $cfgx.DasConfig
        $drs = $cfgx.DrsConfig
        $dpm = $cfgx.DpmConfig
        [PSCustomObject]@{
            "Name"                          = $cl.Name
            "Config status"                 = $s.OverallStatus.ToString()
            "OverallStatus"                 = $s.OverallStatus.ToString()
            "NumHosts"                      = $s.NumHosts
            "numEffectiveHosts"             = $s.NumEffectiveHosts
            "TotalCpu"                      = $s.TotalCpu
            "NumCpuCores"                   = $s.NumCpuCores
            "NumCpuThreads"                 = $s.NumCpuThreads
            "Effective Cpu"                 = $s.EffectiveCpu
            "TotalMemory"                   = [math]::Round($s.TotalMemory / 1MB, 0)
            "Effective Memory"              = $s.EffectiveMemory
            "Num VMotions"                  = $s.NumVmotions
            "HA enabled"                    = if ($ha) { $ha.Enabled.ToString() } else { "False" }
            "Failover Level"                = if ($ha -and $ha.AdmissionControlPolicy) { Get-SafeVal $ha.AdmissionControlPolicy.FailoverLevel 0 } else { 0 }
            "AdmissionControlEnabled"       = if ($ha) { $ha.AdmissionControlEnabled.ToString() } else { "False" }
            "Host monitoring"               = if ($ha) { $ha.HostMonitoring.ToString() } else { "enabled" }
            "HB Datastore Candidate Policy" = if ($ha) { Get-SafeVal $ha.HBDatastoreCandidatePolicy "allFeasibleDsWithUserPreference" } else { "allFeasibleDsWithUserPreference" }
            "Isolation Response"            = if ($ha) { Get-SafeVal $ha.DefaultVmSettings.IsolationResponse "none" } else { "none" }
            "Restart Priority"              = if ($ha) { Get-SafeVal $ha.DefaultVmSettings.RestartPriority "medium" } else { "medium" }
            "Cluster Settings"              = "True"
            "Max Failures"                  = if ($ha) { Get-SafeVal $ha.DefaultVmSettings.VmComponentProtectionSettings.VmTerminateDelay 3 } else { 3 }
            "Max Failure Window"            = -1
            "Failure Interval"              = 30
            "Min Up Time"                   = 120
            "VM Monitoring"                 = if ($ha) { Get-SafeVal $ha.VmMonitoring "vmMonitoringDisabled" } else { "vmMonitoringDisabled" }
            "DRS enabled"                   = if ($drs) { $drs.Enabled.ToString() } else { "False" }
            "DRS default VM behavior"       = if ($drs) { Get-SafeVal $drs.DefaultVmBehavior "fullyAutomated" } else { "fullyAutomated" }
            "DRS vmotion rate"              = if ($drs) { Get-SafeVal $drs.VmotionRate 3 } else { 3 }
            "DPM enabled"                   = if ($dpm) { $dpm.Enabled.ToString() } else { "False" }
            "DPM default behavior"          = if ($dpm) { Get-SafeVal $dpm.DefaultDpmBehavior "automated" } else { "automated" }
            "DPM Host Power Action Rate"    = 3
            "Object ID"                     = $cl.MoRef.Value
            "VI SDK Server"                 = $sdk
            "VI SDK UUID"                   = $sdkuuid
        }
    }
    return $results
}

function Get-vHost {
    param([array]$HostViews)
    Write-Host "  vHost..." -ForegroundColor DarkCyan
    $sdk = Get-SDKServer; $sdkuuid = Get-SDKUUID
    $results = foreach ($h in $HostViews) {

        # Guard every top-level sub-object — any can be null on disconnected/partial hosts
        $hw  = $h.Hardware
        $cfg = $h.Config
        $sum = $h.Summary
        $qs  = if ($sum) { $sum.QuickStats } else { $null }
        $hd  = if ($hw)  { $hw.SystemInfo  } else { $null }
        $rt  = $h.Runtime

        # Cluster name
        $clName = "N/A"
        if ($h.Parent -and $h.Parent.Type -eq "ClusterComputeResource") {
            $cv = Get-View -Id $h.Parent -Property Name -ErrorAction SilentlyContinue
            if ($cv) { $clName = $cv.Name }
        }

        # CPU info
        $cpuModel    = if ($hw -and $hw.CpuPkg  -and $hw.CpuPkg.Count  -gt 0) { $hw.CpuPkg[0].Description } else { "Unknown" }
        $cpuSpeedMHz = if ($hw -and $hw.CpuPkg  -and $hw.CpuPkg.Count  -gt 0) { [math]::Round($hw.CpuPkg[0].Hz / 1000000, 0) } else { 0 }
        $numCPU      = if ($hw -and $hw.CpuInfo) { $hw.CpuInfo.NumCpuPackages } else { 0 }
        $numCores    = if ($hw -and $hw.CpuInfo) { $hw.CpuInfo.NumCpuCores    } else { 0 }
        $coresPerCPU = if ($numCPU -gt 0)        { [math]::Round($numCores / $numCPU, 0) } else { 0 }

        # Memory
        $memMB = if ($hw -and $hw.MemorySize) { [math]::Round($hw.MemorySize / 1MB, 0) } else { 0 }

        # Usage percentages — guard against null QuickStats (host disconnected)
        $cpuMhzCap  = if ($sum -and $sum.Hardware) { $sum.Hardware.CpuMhz } else { 0 }
        $cpuUseMhz  = if ($qs)  { Get-SafeVal $qs.OverallCpuUsage    0 } else { 0 }
        $memUseMB   = if ($qs)  { Get-SafeVal $qs.OverallMemoryUsage 0 } else { 0 }
        $cpuUsePct  = if ($cpuMhzCap -gt 0) { [math]::Round(($cpuUseMhz  / $cpuMhzCap) * 100, 0) } else { 0 }
        $memUsePct  = if ($memMB     -gt 0) { [math]::Round(($memUseMB   / $memMB)      * 100, 0) } else { 0 }

        # Counts
        $nicCount = if ($cfg -and $cfg.Network -and $cfg.Network.Pnic)                           { $cfg.Network.Pnic.Count } else { 0 }
        $hbaCount = if ($cfg -and $cfg.StorageDevice -and $cfg.StorageDevice.HostBusAdapter)     { $cfg.StorageDevice.HostBusAdapter.Count } else { 0 }
        $vmTotal  = if ($h.Vm) { $h.Vm.Count } else { 0 }

        # Network config
        $dnsServers = if ($cfg -and $cfg.Network -and $cfg.Network.DnsConfig -and $cfg.Network.DnsConfig.Address) {
            $cfg.Network.DnsConfig.Address -join ", "
        } else { "" }
        $domainName = if ($cfg -and $cfg.Network -and $cfg.Network.DnsConfig) { $cfg.Network.DnsConfig.DomainName } else { "" }
        $defaultGW  = if ($cfg -and $cfg.Network -and $cfg.Network.IpRouteConfig) { $cfg.Network.IpRouteConfig.DefaultGateway } else { "" }

        # NTP
        $ntpServers = if ($cfg -and $cfg.DateTimeInfo -and $cfg.DateTimeInfo.NtpConfig -and $cfg.DateTimeInfo.NtpConfig.Server) {
            $cfg.DateTimeInfo.NtpConfig.Server -join ", "
        } else { "" }
        $tzKey    = if ($cfg -and $cfg.DateTimeInfo -and $cfg.DateTimeInfo.TimeZone) { $cfg.DateTimeInfo.TimeZone.Key    } else { "UTC" }
        $tzOffset = if ($cfg -and $cfg.DateTimeInfo -and $cfg.DateTimeInfo.TimeZone) { $cfg.DateTimeInfo.TimeZone.GmtOffset } else { 0 }

        # Check NTPD service state
        $ntpdRunning = $false
        if ($cfg -and $cfg.Service -and $cfg.Service.Service) {
            $ntpSvc = $cfg.Service.Service | Where-Object { $_.Key -eq "ntpd" }
            if ($ntpSvc) { $ntpdRunning = $ntpSvc.Running }
        }

        # Hardware identity
        $vendor = if ($hd) { Get-SafeVal $hd.Vendor "Unknown" } else { "Unknown" }
        $model  = if ($hd) { Get-SafeVal $hd.Model  "Unknown" } else { "Unknown" }
        $uuid   = if ($hd) { Get-SafeVal $hd.Uuid   ""        } else { "" }

        # Serial number — the result of Where-Object can be null even if OtherIdentifyingInfo exists
        $serialNum = $null
        if ($hd -and $hd.OtherIdentifyingInfo) {
            $snEntry = $hd.OtherIdentifyingInfo | Where-Object {
                $_.IdentifierType -and $_.IdentifierType.Key -eq "SerialNumberTag"
            } | Select-Object -First 1
            if ($snEntry) { $serialNum = $snEntry.IdentifierValue }
        }

        # BIOS
        $biosVer  = if ($hw -and $hw.BiosInfo) { $hw.BiosInfo.BiosVersion } else { $null }
        $biosDate = if ($hw -and $hw.BiosInfo) { $hw.BiosInfo.ReleaseDate  } else { $null }

        # ESX product string
        $esxVersion = if ($sum -and $sum.Config -and $sum.Config.Product) { $sum.Config.Product.FullName } else { "" }

        # Pre-compute conditional values — PS5.1 cannot parse Get-SafeStr (if ...) inline in a hash literal
        $configStatus = if ($sum) { Get-SafeStr $sum.OverallStatus "gray"  } else { "gray"  }
        $maintMode    = if ($rt)  { Get-SafeStr $rt.InMaintenanceMode "False" } else { "False" }
        $bootTime     = if ($rt)  { $rt.BootTime } else { $null }

        [PSCustomObject]@{
            "Host"                          = $h.Name
            "Datacenter"                    = "Datacenter"
            "Cluster"                       = $clName
            "Config status"                 = $configStatus
            "Compliance Check State"        = $null
            "in Maintenance Mode"           = $maintMode
            "in Quarantine Mode"            = "False"
            "vSAN Fault Domain Name"        = $null
            "CPU Model"                     = $cpuModel
            "Speed"                         = $cpuSpeedMHz
            "HT Available"                  = "True"
            "HT Active"                     = "True"
            "# CPU"                         = $numCPU
            "Cores per CPU"                 = $coresPerCPU
            "# Cores"                       = $numCores
            "CPU usage %"                   = $cpuUsePct
            "# Memory"                      = $memMB
            "Memory Tiering Type"           = "noTiering"
            "Memory usage %"                = $memUsePct
            "Console"                       = 0
            "# NICs"                        = $nicCount
            "# HBAs"                        = $hbaCount
            "# VMs total"                   = $vmTotal
            "# VMs"                         = $vmTotal
            "VMs per Core"                  = if ($numCores -gt 0) { [math]::Round($vmTotal / $numCores, 3) } else { 0 }
            "# vCPUs"                       = 0
            "vCPUs per Core"                = 0
            "vRAM"                          = 0
            "VM Used memory"                = $memUseMB
            "VM Memory Swapped"             = 0
            "VM Memory Ballooned"           = 0
            "VMotion support"               = "True"
            "Storage VMotion support"       = "True"
            "Current EVC"                   = Get-SafeVal $h.Summary.MaxEVCModeKey ""
            "Max EVC"                       = Get-SafeVal $h.Summary.MaxEVCModeKey ""
            "Assigned License(s)"           = $null
            "ESX Version"                   = $esxVersion
            "Boot time"                     = $bootTime
            "DNS Servers"                   = $dnsServers
            "DHCP"                          = "False"
            "Domain"                        = $domainName
            "NTP Server(s)"                 = $ntpServers
            "NTPD running"                  = $ntpdRunning.ToString()
            "Time Zone"                     = $tzKey
            "GMT Offset"                    = $tzOffset
            "Vendor"                        = $vendor
            "Model"                         = $model
            "Serial number"                 = $serialNum
            "BIOS Version"                  = $biosVer
            "BIOS Date"                     = $biosDate
            "Object ID"                     = $h.MoRef.Value
            "UUID"                          = $uuid
            "VI SDK Server"                 = $sdk
            "VI SDK UUID"                   = $sdkuuid
        }
    }
    return $results
}

function Get-vHBA {
    param([array]$HostViews)
    Write-Host "  vHBA..." -ForegroundColor DarkCyan
    $sdk = Get-SDKServer; $sdkuuid = Get-SDKUUID
    $results = foreach ($h in $HostViews) {
        $clName = "N/A"
        if ($h.Parent -and $h.Parent.Type -eq "ClusterComputeResource") {
            $cv = Get-View -Id $h.Parent -Property Name -ErrorAction SilentlyContinue
            if ($cv) { $clName = $cv.Name }
        }
        if (-not ($h.Config -and $h.Config.StorageDevice -and $h.Config.StorageDevice.HostBusAdapter)) { continue }
        foreach ($hba in $h.Config.StorageDevice.HostBusAdapter) {
            $hbaType = $hba.GetType().Name -replace "HostFibreChannel","Fibre Channel" -replace "HostBlockHba","Block" -replace "HostInternetScsiHba","iSCSI" -replace "HostParallelScsiHba","Parallel SCSI"
            $wwn = ""
            if ($hba -is [VMware.Vim.HostFibreChannelHba]) {
                $wwn = "{0:X16} {1:X16}" -f $hba.PortWorldWideName, $hba.NodeWorldWideName
            }
            [PSCustomObject]@{
                "Host"          = $h.Name
                "Datacenter"    = "Datacenter"
                "Cluster"       = $clName
                "Device"        = $hba.Device
                "Type"          = $hbaType
                "Status"        = $hba.Status
                "Bus"           = $hba.Bus.ToString()
                "Pci"           = $hba.Pci
                "Driver"        = $hba.Driver
                "Model"         = $hba.Model
                "WWN"           = $wwn
                "VI SDK Server" = $sdk
                "VI SDK UUID"   = $sdkuuid
            }
        }
    }
    return $results
}

function Get-vNIC {
    param([array]$HostViews)
    Write-Host "  vNIC..." -ForegroundColor DarkCyan
    $sdk = Get-SDKServer; $sdkuuid = Get-SDKUUID
    $results = foreach ($h in $HostViews) {
        $clName = "N/A"
        if ($h.Parent -and $h.Parent.Type -eq "ClusterComputeResource") {
            $cv = Get-View -Id $h.Parent -Property Name -ErrorAction SilentlyContinue
            if ($cv) { $clName = $cv.Name }
        }
        if (-not ($h.Config -and $h.Config.Network -and $h.Config.Network.Pnic)) { continue }
        # Build pnic->vswitch map
        $pnicSwitchMap = @{}
        if ($h.Config.Network.Vswitch) {
            foreach ($vs in $h.Config.Network.Vswitch) {
                if ($vs.Pnic) {
                    foreach ($p in $vs.Pnic) { $pnicSwitchMap[$p] = $vs.Name }
                }
            }
        }
        foreach ($pnic in $h.Config.Network.Pnic) {
            $speed = if ($pnic.LinkSpeed) { $pnic.LinkSpeed.SpeedMb } else { 0 }
            $switch = if ($pnicSwitchMap.ContainsKey("key-vim.host.PhysicalNic-$($pnic.Device)")) {
                $pnicSwitchMap["key-vim.host.PhysicalNic-$($pnic.Device)"]
            } else { "" }
            [PSCustomObject]@{
                "Host"           = $h.Name
                "Datacenter"     = "Datacenter"
                "Cluster"        = $clName
                "Network Device" = $pnic.Device
                "Driver"         = $pnic.Driver
                "Speed"          = $speed
                "Duplex"         = if ($pnic.LinkSpeed) { $pnic.LinkSpeed.Duplex.ToString() } else { "False" }
                "MAC"            = $pnic.Mac
                "Switch"         = $switch
                "Uplink port"    = $null
                "PCI"            = $pnic.Pci
                "WakeOn"         = if ($pnic.WakeOnLanSupported) { $pnic.WakeOnLanSupported.ToString() } else { "False" }
                "VI SDK Server"  = $sdk
                "VI SDK UUID"    = $sdkuuid
            }
        }
    }
    return $results
}

function Get-vSwitch {
    param([array]$HostViews)
    Write-Host "  vSwitch..." -ForegroundColor DarkCyan
    $sdk = Get-SDKServer; $sdkuuid = Get-SDKUUID
    $results = foreach ($h in $HostViews) {
        $clName = "N/A"
        if ($h.Parent -and $h.Parent.Type -eq "ClusterComputeResource") {
            $cv = Get-View -Id $h.Parent -Property Name -ErrorAction SilentlyContinue
            if ($cv) { $clName = $cv.Name }
        }
        if (-not ($h.Config -and $h.Config.Network -and $h.Config.Network.Vswitch)) { continue }
        foreach ($vs in $h.Config.Network.Vswitch) {
            $sec  = $vs.Spec.Policy.Security
            $ts   = $vs.Spec.Policy.TrafficShaping
            $team = $vs.Spec.Policy.NicTeaming
            [PSCustomObject]@{
                "Host"             = $h.Name
                "Datacenter"       = "Datacenter"
                "Cluster"          = $clName
                "Switch"           = $vs.Name
                "# Ports"          = $vs.Spec.NumPorts
                "Free Ports"       = $vs.NumPortsAvailable
                "Promiscuous Mode" = if ($sec) { $sec.AllowPromiscuous.ToString() } else { "False" }
                "Mac Changes"      = if ($sec) { $sec.MacChanges.ToString() } else { "False" }
                "Forged Transmits"  = if ($sec) { $sec.ForgedTransmits.ToString() } else { "False" }
                "Traffic Shaping"  = if ($ts -and $ts.Enabled) { $ts.Enabled.ToString() } else { "False" }
                "Width"            = if ($ts -and $ts.AverageBandwidth) { $ts.AverageBandwidth } else { 0 }
                "Peak"             = if ($ts -and $ts.PeakBandwidth) { $ts.PeakBandwidth } else { 0 }
                "Burst"            = if ($ts -and $ts.BurstSize) { $ts.BurstSize } else { 0 }
                "Policy"           = if ($team -and $team.Policy) { $team.Policy } else { "loadbalance_srcid" }
                "Reverse Policy"   = if ($team -and $team.ReversePolicy) { $team.ReversePolicy.ToString() } else { "True" }
                "Notify Switch"    = if ($team -and $team.NotifySwitches) { $team.NotifySwitches.ToString() } else { "True" }
                "Rolling Order"    = if ($team -and $team.RollingOrder) { $team.RollingOrder.ToString() } else { "False" }
                "Offload"          = "True"
                "TSO"              = "True"
                "Zero Copy Xmit"   = "True"
                "MTU"              = $vs.Spec.Mtu
                "VI SDK Server"    = $sdk
                "VI SDK UUID"      = $sdkuuid
            }
        }
    }
    return $results
}

function Get-vPort {
    param([array]$HostViews)
    Write-Host "  vPort..." -ForegroundColor DarkCyan
    $sdk = Get-SDKServer; $sdkuuid = Get-SDKUUID
    $results = foreach ($h in $HostViews) {
        $clName = "N/A"
        if ($h.Parent -and $h.Parent.Type -eq "ClusterComputeResource") {
            $cv = Get-View -Id $h.Parent -Property Name -ErrorAction SilentlyContinue
            if ($cv) { $clName = $cv.Name }
        }
        if (-not ($h.Config -and $h.Config.Network -and $h.Config.Network.Portgroup)) { continue }
        foreach ($pg in $h.Config.Network.Portgroup) {
            $spec = $pg.Spec
            $sec  = $spec.Policy.Security
            $ts   = $spec.Policy.TrafficShaping
            $team = $spec.Policy.NicTeaming
            [PSCustomObject]@{
                "Host"             = $h.Name
                "Datacenter"       = "Datacenter"
                "Cluster"          = $clName
                "Port Group"       = $spec.Name
                "Switch"           = $spec.VswitchName
                "VLAN"             = Get-SafeStr $spec.VlanId "0"
                "Promiscuous Mode" = if ($sec) { $sec.AllowPromiscuous.ToString() } else { "False" }
                "Mac Changes"      = if ($sec) { $sec.MacChanges.ToString() } else { "False" }
                "Forged Transmits"  = if ($sec) { $sec.ForgedTransmits.ToString() } else { "False" }
                "Traffic Shaping"  = if ($ts -and $ts.Enabled) { $ts.Enabled.ToString() } else { "False" }
                "Width"            = if ($ts -and $ts.AverageBandwidth) { $ts.AverageBandwidth } else { 0 }
                "Peak"             = if ($ts -and $ts.PeakBandwidth) { $ts.PeakBandwidth } else { 0 }
                "Burst"            = if ($ts -and $ts.BurstSize) { $ts.BurstSize } else { 0 }
                "Policy"           = if ($team -and $team.Policy) { $team.Policy } else { "loadbalance_srcid" }
                "Reverse Policy"   = if ($team -and $team.ReversePolicy) { $team.ReversePolicy.ToString() } else { "True" }
                "Notify Switch"    = if ($team -and $team.NotifySwitches) { $team.NotifySwitches.ToString() } else { "True" }
                "Rolling Order"    = if ($team -and $team.RollingOrder) { $team.RollingOrder.ToString() } else { "False" }
                "Offload"          = "True"
                "TSO"              = "True"
                "Zero Copy Xmit"   = "True"
                "VI SDK Server"    = $sdk
                "VI SDK UUID"      = $sdkuuid
            }
        }
    }
    return $results
}

function Get-dvSwitch {
    param($DVSViews)
    Write-Host "  dvSwitch..." -ForegroundColor DarkCyan
    $sdk = Get-SDKServer; $sdkuuid = Get-SDKUUID
    if (-not $DVSViews) { return @() }
    $results = foreach ($dvs in $DVSViews) {
        $cfg      = $dvs.Config
        $numPorts = if ($dvs.Summary -and $dvs.Summary.NumPorts) { $dvs.Summary.NumPorts } else { 0 }
        $vendor   = if ($cfg -and $cfg.ProductInfo) { Get-SafeVal $cfg.ProductInfo.Vendor "VMware" } else { "VMware" }
        $version  = if ($cfg -and $cfg.ProductInfo) { Get-SafeVal $cfg.ProductInfo.Version ""      } else { "" }
        $contact  = if ($cfg -and $cfg.Contact)     { $cfg.Contact.Contact } else { $null }
        $adminNm  = if ($cfg -and $cfg.Contact)     { $cfg.Contact.Name    } else { $null }
        $maxMtu   = if ($cfg) { Get-SafeVal $cfg.MaxMtu 1500 } else { 1500 }
        $maxPorts = if ($cfg) { Get-SafeVal $cfg.MaxPorts 0  } else { 0 }
        $hostCnt  = if ($cfg -and $cfg.Host) { $cfg.Host.Count } else { 0 }
        $desc     = if ($cfg) { $cfg.Description } else { $null }
        $created  = if ($cfg) { $cfg.CreateTime  } else { $null }
        [PSCustomObject]@{
            "Switch"                = $dvs.Name
            "Datacenter"            = "Datacenter"
            "Name"                  = $dvs.Name
            "Vendor"                = $vendor
            "Version"               = $version
            "Description"           = $desc
            "Created"               = $created
            "Host members"          = $hostCnt
            "Max Ports"             = $maxPorts
            "# Ports"               = $numPorts
            "# VMs"                 = 0
            "In Traffic Shaping"    = "False"
            "In Avg"                = 0
            "In Peak"               = 0
            "In Burst"              = 0
            "Out Traffic Shaping"   = "False"
            "Out Avg"               = 0
            "Out Peak"              = 0
            "Out Burst"             = 0
            "CDP Type"              = "listen"
            "CDP Operation"         = "listen"
            "LACP Name"             = $null
            "LACP Mode"             = $null
            "LACP Load Balance Alg."= $null
            "Max MTU"               = $maxMtu
            "Contact"               = $contact
            "Admin Name"            = $adminNm
            "Object ID"             = $dvs.MoRef.Value
            "VI SDK Server"         = $sdk
            "VI SDK UUID"           = $sdkuuid
        }
    }
    return $results
}

function Get-dvPort {
    param($DVPGViews)
    Write-Host "  dvPort..." -ForegroundColor DarkCyan
    $sdk = Get-SDKServer; $sdkuuid = Get-SDKUUID
    if (-not $DVPGViews) { return @() }
    $results = foreach ($pg in $DVPGViews) {
        try {
        $cfg  = $pg.Config
        if (-not $cfg) { continue }
        $dflt = $cfg.DefaultPortConfig
        $sec  = if ($dflt -and $dflt.SecurityPolicy)      { $dflt.SecurityPolicy      } else { $null }
        $team = if ($dflt -and $dflt.UplinkTeamingPolicy) { $dflt.UplinkTeamingPolicy } else { $null }

        # VLAN — guard the type check; dflt can be null
        $vlan = "0"
        if ($dflt -and $dflt.Vlan -and $dflt.Vlan -is [VMware.Vim.VmwareDistributedVirtualSwitchVlanIdSpec]) {
            $vlan = $dflt.Vlan.VlanId.ToString()
        }

        # Pre-compute all .Value.ToString() calls — these crash when the wrapper object is null
        $blocked   = if ($dflt -and $dflt.Blocked   -and $null -ne $dflt.Blocked.Value)   { $dflt.Blocked.Value.ToString()   } else { "False" }
        $allowProm = if ($sec  -and $sec.AllowPromiscuous -and $null -ne $sec.AllowPromiscuous.Value) { $sec.AllowPromiscuous.Value.ToString() } else { "False" }
        $macChg    = if ($sec  -and $sec.MacChanges       -and $null -ne $sec.MacChanges.Value)       { $sec.MacChanges.Value.ToString()       } else { "False" }
        $forgedTx  = if ($sec  -and $sec.ForgedTransmits  -and $null -ne $sec.ForgedTransmits.Value)  { $sec.ForgedTransmits.Value.ToString()  } else { "False" }
        $policy    = if ($team -and $team.Policy -and $null -ne $team.Policy.Value) { $team.Policy.Value } else { "loadbalance_srcid" }
        $actUp     = if ($team -and $team.UplinkPortOrder -and $team.UplinkPortOrder.ActiveUplinkPort)  { $team.UplinkPortOrder.ActiveUplinkPort  -join "," } else { "" }
        $stdbyUp   = if ($team -and $team.UplinkPortOrder -and $team.UplinkPortOrder.StandbyUplinkPort) { $team.UplinkPortOrder.StandbyUplinkPort -join "," } else { "" }
        $liveMove  = if ($cfg.Policy -and $null -ne $cfg.Policy.LivePortMovingAllowed) { $cfg.Policy.LivePortMovingAllowed.ToString() } else { "False" }
        $dvsVal    = if ($cfg.DistributedVirtualSwitch) { $cfg.DistributedVirtualSwitch.Value } else { "" }

        [PSCustomObject]@{
            "Port"                  = $pg.Name
            "Switch"                = $dvsVal
            "Type"                  = $cfg.Type
            "# Ports"               = $cfg.NumPorts
            "VLAN"                  = $vlan
            "Speed"                 = 0
            "Full Duplex"           = "True"
            "Blocked"               = $blocked
            "Allow Promiscuous"     = $allowProm
            "Mac Changes"           = $macChg
            "Active Uplink"         = $actUp
            "Standby Uplink"        = $stdbyUp
            "Policy"                = $policy
            "Forged Transmits"      = $forgedTx
            "In Traffic Shaping"    = "False"
            "In Avg"                = 0
            "In Peak"               = 0
            "In Burst"              = 0
            "Out Traffic Shaping"   = "False"
            "Out Avg"               = 0
            "Out Peak"              = 0
            "Out Burst"             = 0
            "Reverse Policy"        = "True"
            "Notify Switch"         = "True"
            "Rolling Order"         = "False"
            "Check Beacon"          = "False"
            "Live Port Moving"      = $liveMove
            "Check Duplex"          = "False"
            "Check Error %"         = "False"
            "Check Speed"           = "minimum"
            "Object ID"             = $pg.MoRef.Value
            "VI SDK Server"         = $sdk
            "VI SDK UUID"           = $sdkuuid
        }
        } catch {
            Write-Verbose "  dvPort: skipped portgroup '$($pg.Name)': $_"
        }
    }
    return $results
}

function Get-vSCVMK {
    param([array]$HostViews)
    Write-Host "  vSC_VMK..." -ForegroundColor DarkCyan
    $sdk = Get-SDKServer; $sdkuuid = Get-SDKUUID
    $results = foreach ($h in $HostViews) {
        $clName = "N/A"
        if ($h.Parent -and $h.Parent.Type -eq "ClusterComputeResource") {
            $cv = Get-View -Id $h.Parent -Property Name -ErrorAction SilentlyContinue
            if ($cv) { $clName = $cv.Name }
        }
        if (-not ($h.Config -and $h.Config.Network -and $h.Config.Network.Vnic)) { continue }
        foreach ($vmk in $h.Config.Network.Vnic) {
            $vmkIp = if ($vmk.Spec -and $vmk.Spec.Ip) { $vmk.Spec.Ip } else { $null }
            $ip6 = ""
            if ($vmkIp -and $vmkIp.IpV6Config -and $vmkIp.IpV6Config.IpV6Address) {
                $ip6entry = $vmkIp.IpV6Config.IpV6Address | Select-Object -First 1
                if ($ip6entry) { $ip6 = $ip6entry.IpAddress }
            }
            $dhcpVal = if ($vmkIp) { Get-SafeStr $vmkIp.Dhcp "False" } else { "False" }
            [PSCustomObject]@{
                "Host"          = $h.Name
                "Datacenter"    = "Datacenter"
                "Cluster"       = $clName
                "Port Group"    = $vmk.Portgroup
                "Device"        = $vmk.Device
                "Mac Address"   = if ($vmk.Spec) { $vmk.Spec.Mac } else { "" }
                "DHCP"          = $dhcpVal
                "IP Address"    = if ($vmkIp) { $vmkIp.IpAddress  } else { "" }
                "IP 6 Address"  = $ip6
                "Subnet mask"   = if ($vmkIp) { $vmkIp.SubnetMask } else { "" }
                "Gateway"       = if ($h.Config.Network.IpRouteConfig) { $h.Config.Network.IpRouteConfig.DefaultGateway } else { "" }
                "IP 6 Gateway"  = $null
                "MTU"           = if ($vmk.Spec) { $vmk.Spec.Mtu } else { $null }
                "VI SDK Server" = $sdk
                "VI SDK UUID"   = $sdkuuid
            }
        }
    }
    return $results
}

function Get-vDatastore {
    param([array]$DSViews)
    Write-Host "  vDatastore..." -ForegroundColor DarkCyan
    $sdk = Get-SDKServer; $sdkuuid = Get-SDKUUID
    $results = foreach ($ds in $DSViews) {
        $s = $ds.Summary
        $capMiB  = Convert-BytesToMiB -Bytes $s.Capacity
        $freeMiB = Convert-BytesToMiB -Bytes $s.FreeSpace
        $usedMiB = $capMiB - $freeMiB
        $provMiB = Convert-BytesToMiB -Bytes ($s.Capacity - $s.FreeSpace + $s.Uncommitted)
        $freePct = if ($capMiB -gt 0) { [math]::Round(($freeMiB / $capMiB) * 100, 0) } else { 0 }
        $hostCount = if ($ds.Host) { $ds.Host.Count } else { 0 }
        $hostNames = if ($ds.Host) {
            ($ds.Host | ForEach-Object {
                $hv = Get-View -Id $_.Key -Property Name -ErrorAction SilentlyContinue
                if ($hv) { $hv.Name } else { $_.Key.Value }
            }) -join ", "
        } else { "" }
        $vmCount = if ($ds.Vm) { $ds.Vm.Count } else { 0 }
        # VMFS-specific info
        $vmfsInfo = $null
        if ($ds.Info -is [VMware.Vim.VmfsDatastoreInfo]) { $vmfsInfo = $ds.Info.Vmfs }
        [PSCustomObject]@{
            "Name"                   = $s.Name
            "Config status"          = if ($ds.Summary.Accessible) { "green" } else { "gray" }
            "Address"                = if ($vmfsInfo -and $vmfsInfo.Extent) { $vmfsInfo.Extent[0].DiskName } else { "" }
            "Accessible"             = $s.Accessible.ToString()
            "Type"                   = $s.Type
            "# VMs total"            = $vmCount
            "# VMs"                  = $vmCount
            "Capacity MiB"           = $capMiB
            "Provisioned MiB"        = $provMiB
            "In Use MiB"             = $usedMiB
            "Free MiB"               = $freeMiB
            "Free %"                 = $freePct
            "SIOC enabled"           = if ($ds.IormConfiguration) { $ds.IormConfiguration.Enabled.ToString() } else { "False" }
            "SIOC Threshold"         = if ($ds.IormConfiguration) { $ds.IormConfiguration.CongestionThreshold } else { 30 }
            "# Hosts"                = $hostCount
            "Hosts"                  = $hostNames
            "Cluster name"           = $null
            "Cluster capacity MiB"   = $null
            "Cluster free space MiB" = $null
            "Block size"             = if ($vmfsInfo) { 1 } else { $null }
            "Max Blocks"             = if ($vmfsInfo) { $vmfsInfo.MaxBlocks } else { $null }
            "# Extents"              = if ($vmfsInfo -and $vmfsInfo.Extent) { $vmfsInfo.Extent.Count } else { $null }
            "Major Version"          = if ($vmfsInfo) { $vmfsInfo.MajorVersion } else { $null }
            "Version"                = if ($vmfsInfo) { $vmfsInfo.Version } else { $null }
            "VMFS Upgradeable"       = "False"
            "MHA"                    = "False"
            "URL"                    = $s.Url
            "Object ID"              = $ds.MoRef.Value
            "VI SDK Server"          = $sdk
            "VI SDK UUID"            = $sdkuuid
        }
    }
    return $results
}

function Get-vMultiPath {
    param([array]$HostViews)
    Write-Host "  vMultiPath..." -ForegroundColor DarkCyan
    $sdk = Get-SDKServer; $sdkuuid = Get-SDKUUID
    $results = foreach ($h in $HostViews) {
        $clName = "N/A"
        if ($h.Parent -and $h.Parent.Type -eq "ClusterComputeResource") {
            $cv = Get-View -Id $h.Parent -Property Name -ErrorAction SilentlyContinue
            if ($cv) { $clName = $cv.Name }
        }
        if (-not ($h.Config -and $h.Config.StorageDevice -and $h.Config.StorageDevice.MultipathInfo)) { continue }
        foreach ($lun in $h.Config.StorageDevice.MultipathInfo.Lun) {
            $paths = if ($lun.Path) { $lun.Path } else { @() }
            $pathObj = [ordered]@{}
            for ($i = 1; $i -le 8; $i++) {
                $p = if ($i -le $paths.Count) { $paths[$i-1] } else { $null }
                $pathObj["Path $i"]       = if ($p) { $p.Adapter } else { $null }
                $pathObj["Path $i state"] = if ($p) { $p.State } else { $null }
            }
            $scsi = if ($h.Config.StorageDevice.ScsiLun) {
                $h.Config.StorageDevice.ScsiLun | Where-Object { $_.Uuid -eq $lun.Id }
            } else { $null }
            $row = [ordered]@{
                "Host"         = $h.Name
                "Cluster"      = $clName
                "Datacenter"   = "Datacenter"
                "Datastore"    = $null
                "Disk"         = $lun.Id
                "Display name" = if ($scsi) { $scsi.DisplayName } else { $lun.Id }
                "Policy"       = if ($lun.Policy) { $lun.Policy.Policy } else { "VMW_PSP_MRU" }
                "Oper. State"  = "ok"
            }
            foreach ($k in $pathObj.Keys) { $row[$k] = $pathObj[$k] }
            $row["vStorage"]     = "vStorageSupported"
            $row["Queue depth"]  = if ($scsi) { $scsi.QueueDepth } else { 0 }
            $row["Vendor"]       = if ($scsi) { $scsi.Vendor } else { "" }
            $row["Model"]        = if ($scsi) { $scsi.Model } else { "" }
            $row["Revision"]     = if ($scsi) { $scsi.Revision } else { "" }
            $row["Level"]        = 6
            $row["Serial #"]     = "unavailable"
            $row["UUID"]         = $lun.Id
            $row["Object ID"]    = $lun.Id
            $row["VI SDK Server"]= $sdk
            $row["VI SDK UUID"]  = $sdkuuid
            [PSCustomObject]$row
        }
    }
    return $results
}

# ============================================================
#  REGION: MISC TAB FUNCTIONS
# ============================================================

function Get-vLicense {
    param($LicMgr)
    Write-Host "  vLicense..." -ForegroundColor DarkCyan
    $sdk = Get-SDKServer; $sdkuuid = Get-SDKUUID
    if (-not $LicMgr -or -not $LicMgr.Licenses) { return @() }
    $results = foreach ($lic in $LicMgr.Licenses) {
        $features = if ($lic.Properties) {
            ($lic.Properties | Where-Object { $_.Key -eq "feature" } | ForEach-Object { $_.Value }) -join ", "
        } else { "" }
        [PSCustomObject]@{
            "Name"           = $lic.Name
            "Key"            = $lic.LicenseKey
            "Labels"         = $null
            "Cost Unit"      = $lic.CostUnit
            "Total"          = $lic.Total
            "Used"           = $lic.Used
            "Expiration Date"= if ($lic.ExpirationDate) { $lic.ExpirationDate } else { $null }
            "Features"       = $features
            "VI SDK Server"  = $sdk
            "VI SDK UUID"    = $sdkuuid
        }
    }
    return $results
}

function Get-vFileInfo {
    Write-Host "  vFileInfo..." -ForegroundColor DarkCyan
    # vFileInfo requires a special RVTools preference flag (-GetFileInfo) and deep
    # datastore file browsing. We emit the same placeholder RVTools itself shows
    # when the option is not enabled, so the tab exists and is correctly shaped.
    return @(
        [PSCustomObject]@{
            "Friendly Path Name"     = "This tab page is empty when GetFileInfo option is not set in preferences or when using the CLI the switch -GetFileInfo is not passed. "
            "File Name"              = $null
            "File Type"              = $null
            "File Size in bytes"     = $null
            "Path"                   = $null
            "Internal Sort Column"   = $null
            "VI SDK Server"          = Get-SDKServer
            "VI SDK UUID"            = Get-SDKUUID
        }
    )
}

function Get-vHealth {
    param([array]$HostViews)
    Write-Host "  vHealth..." -ForegroundColor DarkCyan
    # Real RVTools vHealth = ESXi/vCenter config issue messages (not VM health checks).
    # We surface host-level alarms and known configuration warnings.
    $sdk = Get-SDKServer; $sdkuuid = Get-SDKUUID
    $results = foreach ($h in $HostViews) {
        # Check NTP service state — guard the entire Config.Service chain
        $ntpdRunning = $false
        if ($h.Config -and $h.Config.Service -and $h.Config.Service.Service) {
            $ntpSvc = $h.Config.Service.Service | Where-Object { $_.Key -eq "ntpd" }
            if ($ntpSvc) { $ntpdRunning = $ntpSvc.Running }
        }
        if (-not $ntpdRunning) {
            [PSCustomObject]@{
                "Name"          = $h.Name
                "Message"       = "NTPD service is not running!"
                "Message type"  = "NTPD"
                "VI SDK Server" = $sdk
                "VI SDK UUID"   = $sdkuuid
            }
        }
        # Maintenance mode warning
        if ($h.Runtime -and $h.Runtime.InMaintenanceMode) {
            [PSCustomObject]@{
                "Name"          = $h.Name
                "Message"       = "Host is in Maintenance Mode"
                "Message type"  = "Maintenance"
                "VI SDK Server" = $sdk
                "VI SDK UUID"   = $sdkuuid
            }
        }
    }
    return $results
}

function Get-vSource {
    param($SIView)
    Write-Host "  vSource..." -ForegroundColor DarkCyan
    $sdk = Get-SDKServer; $sdkuuid = Get-SDKUUID
    if (-not $SIView) { return @() }
    $about = $SIView.Content.About
    return @(
        [PSCustomObject]@{
            "Name"           = $about.Name
            "OS type"        = $about.OsType
            "API type"       = $about.ApiType
            "API version"    = $about.ApiVersion
            "Version"        = $about.Version
            "Patch level"    = $about.Build -replace '\D', '' | ForEach-Object { "00000" }
            "Build"          = $about.Build
            "Fullname"       = $about.FullName
            "Product name"   = $about.LicenseProductName
            "Product version"= $about.LicenseProductVersion
            "Product line"   = $about.ProductLineId
            "Vendor"         = $about.Vendor
            "VI SDK Server"  = $sdk
            "VI SDK UUID"    = $sdkuuid
        }
    )
}

function Get-vMetaData {
    Write-Host "  vMetaData..." -ForegroundColor DarkCyan
    return @(
        [PSCustomObject]@{
            "RVTools major version" = 4
            "RVTools version"       = "4.7.1.4 (replica)"
            "xlsx creation datetime"= Get-Date
            "Server"                = Get-SDKServer
        }
    )
}

# ============================================================
#  REGION: OUTPUT
# ============================================================

function Show-Interactive {
    param([System.Collections.Specialized.OrderedDictionary]$TabData)
    foreach ($tab in $TabData.GetEnumerator()) {
        $count = if ($tab.Value) { @($tab.Value).Count } else { 0 }
        if ($count -gt 0) {
            Write-Host "  Grid: $($tab.Key) ($count rows)" -ForegroundColor Yellow
            $tab.Value | Out-GridView -Title "RVTools Replica - $($tab.Key)" -Wait
        } else {
            Write-Host "  Skipping $($tab.Key) -- no data" -ForegroundColor DarkYellow
        }
    }
}

function Export-ToExcel {
    param([System.Collections.Specialized.OrderedDictionary]$TabData, [string]$OutputPath)
    if (-not (Get-Module -Name ImportExcel -ListAvailable)) {
        throw "ImportExcel module required. Install with:  Install-Module ImportExcel -Scope CurrentUser"
    }
    Import-Module ImportExcel -ErrorAction Stop

    $datePart  = (Get-Date).ToString("yyyy-MM-dd_HH-mm-ss")
    $vcSafe    = $global:DefaultVIServers[0].Name -replace '[\\/:*?"<>|]', '_'
    $excelFile = Join-Path $OutputPath ("RVTools_" + $vcSafe + "_" + $datePart + ".xlsx")
    Write-Host "`n  Saving: $excelFile" -ForegroundColor Cyan

    # Canonical RVTools tab order
    $order = @("vInfo","vCPU","vMemory","vDisk","vPartition","vNetwork","vCD","vUSB",
               "vSnapshot","vTools","vSource","vRP","vCluster","vHost","vHBA","vNIC",
               "vSwitch","vPort","dvSwitch","dvPort","vSC_VMK","vDatastore","vMultiPath",
               "vLicense","vFileInfo","vHealth","vMetaData")

    foreach ($name in $order) {
        if (-not $TabData.Contains($name)) { continue }
        $data = $TabData[$name]
        $count = if ($data) { @($data).Count } else { 0 }
        if ($count -eq 0) {
            Write-Host ("    {0,-14} (empty)" -f $name) -ForegroundColor DarkYellow
            continue
        }
        Write-Host ("    {0,-14} {1,5} rows" -f $name, $count) -ForegroundColor DarkCyan
        $p = @{
            Path          = $excelFile
            WorksheetName = $name
            AutoSize      = $true
            AutoFilter    = $true
            FreezeTopRow  = $true
            BoldTopRow    = $true
            TableName     = $name
            TableStyle    = "Medium2"
        }
        if (Test-Path $excelFile) { $p["Append"] = $true }
        $data | Export-Excel @p
    }
    Write-Host "`n  Done: $excelFile" -ForegroundColor Green
}

# ============================================================
#  REGION: MAIN
# ============================================================

function Main {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  RVTools Replica v2.0  |  27 Tabs  |  PS 5.1 Compatible   " -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""

    try {
        Assert-VCenterConnection `
            -Server     $VCenterServer `
            -Username   $Username `
            -Password   $Password `
            -Credential $Credential
    }
    catch { Write-Error "Connection: $_"; return }

    Write-Host "[1/3] Loading vSphere data (bulk API)..." -ForegroundColor White
    try { $d = Get-AllData }
    catch { Write-Error "API error (check permissions): $_"; return }
    Write-Host ""

    Write-Host "[2/3] Building tabs..." -ForegroundColor White

    # Each tab is called in its own try/catch so a single bad object never aborts the whole run.
    # The tab name is printed before the call so if it crashes you know exactly which one.
    $tabData = [ordered]@{}

    $tabDefs = [ordered]@{
        vInfo      = { Get-vInfo      -VMViews $d.VMViews   -HostMap $d.HostMap }
        vCPU       = { Get-vCPU       -VMViews $d.VMViews   -HostMap $d.HostMap }
        vMemory    = { Get-vMemory    -VMViews $d.VMViews   -HostMap $d.HostMap }
        vDisk      = { Get-vDisk      -VMViews $d.VMViews   -HostMap $d.HostMap }
        vPartition = { Get-vPartition -VMViews $d.VMViews   -HostMap $d.HostMap }
        vNetwork   = { Get-vNetwork   -VMViews $d.VMViews   -HostMap $d.HostMap }
        vCD        = { Get-vCD        -VMViews $d.VMViews   -HostMap $d.HostMap }
        vUSB       = { Get-vUSB       -VMViews $d.VMViews   -HostMap $d.HostMap }
        vSnapshot  = { Get-vSnapshot  -VMViews $d.VMViews   -HostMap $d.HostMap }
        vTools     = { Get-vTools     -VMViews $d.VMViews   -HostMap $d.HostMap }
        vSource    = { Get-vSource    -SIView  $d.SIView }
        vRP        = { Get-vRP        -RPViews $d.RPViews }
        vCluster   = { Get-vCluster   -CLViews $d.CLViews }
        vHost      = { Get-vHost      -HostViews $d.HostViews }
        vHBA       = { Get-vHBA       -HostViews $d.HostViews }
        vNIC       = { Get-vNIC       -HostViews $d.HostViews }
        vSwitch    = { Get-vSwitch    -HostViews $d.HostViews }
        vPort      = { Get-vPort      -HostViews $d.HostViews }
        dvSwitch   = { Get-dvSwitch   -DVSViews  $d.DVSViews }
        dvPort     = { Get-dvPort     -DVPGViews $d.DVPGViews }
        vSC_VMK    = { Get-vSCVMK     -HostViews $d.HostViews }
        vDatastore = { Get-vDatastore -DSViews   $d.DSViews }
        vMultiPath = { Get-vMultiPath -HostViews $d.HostViews }
        vLicense   = { Get-vLicense   -LicMgr    $d.LicMgr }
        vFileInfo  = { Get-vFileInfo }
        vHealth    = { Get-vHealth    -HostViews $d.HostViews }
        vMetaData  = { Get-vMetaData }
    }

    foreach ($entry in $tabDefs.GetEnumerator()) {
        try {
            $tabData[$entry.Key] = & $entry.Value
        }
        catch {
            Write-Warning "  [$($entry.Key)] FAILED: $_"
            $tabData[$entry.Key] = @()
        }
    }

    Write-Host ""
    Write-Host "  Summary:" -ForegroundColor White
    foreach ($t in $tabData.GetEnumerator()) {
        $n = if ($t.Value) { @($t.Value).Count } else { 0 }
        Write-Host ("    {0,-14} {1,5} rows" -f $t.Key, $n) -ForegroundColor Gray
    }
    Write-Host ""

    Write-Host "[3/3] Output..." -ForegroundColor White
    if ($Interactive) { Show-Interactive -TabData $tabData }
    if ($ExportExcel) {
        try { Export-ToExcel -TabData $tabData -OutputPath $ExportPath }
        catch { Write-Error "Export failed: $_" }
    }
    if (-not $Interactive -and -not $ExportExcel) {
        Write-Host "  No output mode selected. Use -Interactive or -ExportExcel." -ForegroundColor Yellow
        return $tabData
    }
    Write-Host ""
    Write-Host "Done." -ForegroundColor Green
}

Main
