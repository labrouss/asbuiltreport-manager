#!/usr/bin/env pwsh
# AsBuiltReport Worker - HTTP listener

$Port = 8080
$Listener = [System.Net.HttpListener]::new()
$Listener.Prefixes.Add("http://+:$Port/")
$Listener.Start()
Write-Host "[Worker] Listening on :$Port"

# ── Helpers ───────────────────────────────────────────────────────────────────
function Send-Json {
    param($Context, $Obj, [int]$Code = 200)
    $Body  = $Obj | ConvertTo-Json -Depth 10 -Compress -AsArray:$false
    $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $Context.Response.StatusCode      = $Code
    $Context.Response.ContentType     = 'application/json'
    $Context.Response.ContentLength64 = $Bytes.Length
    $Context.Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
    $Context.Response.OutputStream.Close()
    $Context.Response.Close()
}

function Read-Body {
    param($Context)
    $Reader = [System.IO.StreamReader]::new($Context.Request.InputStream)
    return $Reader.ReadToEnd() | ConvertFrom-Json
}

function Send-Stream {
    param($Context, [ScriptBlock]$Action)
    $Context.Response.StatusCode  = 200
    $Context.Response.ContentType = 'text/plain; charset=utf-8'
    $Context.Response.SendChunked = $true
    $Writer = [System.IO.StreamWriter]::new(
        $Context.Response.OutputStream,
        [System.Text.Encoding]::UTF8
    )
    $Writer.AutoFlush = $true
    try   { & $Action $Writer }
    catch { $Writer.WriteLine("ERROR: $_") }
    finally {
        try { $Writer.Flush(); $Writer.Close() } catch {}
        try { $Context.Response.Close() }         catch {}
    }
}

# ── Main loop ─────────────────────────────────────────────────────────────────
while ($Listener.IsListening) {
    try {
        $Context = $Listener.GetContext()
        $Method  = $Context.Request.HttpMethod
        $RawPath = $Context.Request.Url.AbsolutePath
        $ReqPath = $RawPath.TrimEnd('/')
        if ($ReqPath -eq '') { $ReqPath = '/' }
        Write-Host "[Worker] $Method $ReqPath"

        switch ($ReqPath) {

            '/health' {
                $GvVer = try {
                    $raw = (& dot -V 2>&1 | Out-String).Trim()
                    if ($raw -match '(\d+\.\d+\.\d+)') { $Matches[1] } else { $raw }
                } catch { $null }
                $PdVer = try {
                    $raw = (& pandoc --version 2>&1 | Select-Object -First 1 | Out-String).Trim()
                    $raw -replace '^pandoc\s+',''
                } catch { $null }
                Send-Json $Context @{
                    status   = 'ok'
                    pwsh     = $PSVersionTable.PSVersion.ToString()
                    graphviz = $GvVer
                    pandoc   = $PdVer
                }
            }

            '/installed-modules' {
                $Installed = Get-Module -ListAvailable -Name 'AsBuiltReport.*' |
                    Group-Object Name |
                    ForEach-Object { $_.Group | Sort-Object Version -Descending | Select-Object -First 1 }
                $ModuleList = @($Installed | ForEach-Object { $_.Name -replace '^AsBuiltReport\.', '' })
                $Versions   = @{}
                foreach ($m in $Installed) {
                    $key = $m.Name -replace '^AsBuiltReport\.', ''
                    $Versions[$key] = $m.Version.ToString()
                }
                # HPE OneView uses a custom script — report it as installed if the script exists
                if (Test-Path '/app/reports/Invoke-HPEOneViewReport.ps1') {
                    $ModuleList += 'HPE.OneView'
                    $Versions['HPE.OneView'] = 'custom'
                }
                # RVTools replica script
                if (Test-Path '/app/reports/Get-RVToolsReport.ps1') {
                    $ModuleList += 'VMware.RVTools'
                    $Versions['VMware.RVTools'] = 'v2.0'
                }
                # Force $ModuleList to always serialize as JSON array, even if 0 or 1 element
                Send-Json $Context @{ modules = [array]$ModuleList; versions = $Versions }
            }

            '/install' {
                $Payload  = Read-Body $Context
                $ModuleId = $Payload.moduleId

                # Custom scripts — no PSGallery install needed
                if ($ModuleId -eq 'HPE.OneView' -or $ModuleId -eq 'VMware.RVTools') {
                    Send-Stream $Context {
                        param($Writer)
                        $scriptMap = @{ 'HPE.OneView' = 'Invoke-HPEOneViewReport.ps1'; 'VMware.RVTools' = 'Get-RVToolsReport.ps1' }
                        $scriptFile = "/app/reports/$($scriptMap[$ModuleId])"
                        if (Test-Path $scriptFile) {
                            $Writer.WriteLine("$ModuleId uses a custom built-in script — no install needed.")
                            $Writer.WriteLine("SUCCESS: $ModuleId is ready to use.")
                        } else {
                            $Writer.WriteLine("ERROR: Script not found at $scriptFile")
                        }
                    }
                } elseif ($false) { # placeholder to maintain elseif chain
                    Send-Stream $Context {
                        param($Writer)
                        $Writer.WriteLine("HPE OneView uses the HPEOneView.{version} library directly.")
                        $Writer.WriteLine("It installs automatically on first report run.")
                        $Writer.WriteLine("SUCCESS: No pre-install needed for HPE.OneView.")
                    }
                } else {
                    $ModuleName = "AsBuiltReport.$ModuleId"
                    Send-Stream $Context {
                        param($Writer)
                        $Writer.WriteLine("Installing $ModuleName from PSGallery...")
                        try {
                            # Ensure PowerShellGet is up to date (required for -AllowPrerelease)
                            $PsgVer = (Get-Module -ListAvailable PowerShellGet | Sort-Object Version -Descending | Select-Object -First 1).Version
                            if ($PsgVer -lt [Version]'2.0.0') {
                                $Writer.WriteLine("Updating PowerShellGet...")
                                Install-Module PowerShellGet -Force -AllowClobber -Scope AllUsers | Out-Null
                                Import-Module PowerShellGet -Force
                            }
                            Install-Module -Name $ModuleName -Repository PSGallery `
                                -Force -Scope AllUsers -AcceptLicense -AllowPrerelease -AllowClobber -ErrorAction Stop *>&1 |
                                ForEach-Object { $Writer.WriteLine($_.ToString()) }
                            $Writer.WriteLine("SUCCESS: $ModuleName installed.")
                        } catch {
                            $Writer.WriteLine("ERROR: $($_.Exception.Message)")
                        }
                    }
                }
            }

            '/run-report' {
                $Payload    = Read-Body $Context
                $ModuleId   = $Payload.moduleId
                $Target     = ($Payload.target).Trim()
                $Username   = $Payload.credentials.username
                $Password   = $Payload.credentials.password
                $Formats    = ($Payload.formats -join ',')
                $OutputPath = $Payload.outputPath
                $JobId      = $Payload.jobId
                $ConfigPath = "/etc/asbuiltreport/$ModuleId/AsBuiltReport.json"

                Write-Host "[Worker] Job $JobId | $ModuleId -> $Target | formats: $Formats"

                Send-Stream $Context {
                    param($Writer)
                    $Writer.WriteLine("VERBOSE: Starting job $JobId")
                    $Writer.WriteLine("VERBOSE: Module  = AsBuiltReport.$ModuleId")
                    $Writer.WriteLine("VERBOSE: Target  = $Target")
                    $Writer.WriteLine("VERBOSE: Formats = $Formats")
                    $Writer.WriteLine("VERBOSE: Output  = $OutputPath")

                    try {
                        # Install VCF.PowerCLI if running ESXi report (requires it instead of VMware.PowerCLI)
                        if ($ModuleId -eq 'VMware.ESXi') {
                            if (-not (Get-Module -ListAvailable -Name 'VCF.PowerCLI' -ErrorAction SilentlyContinue)) {
                                $Writer.WriteLine("VERBOSE: Installing VCF.PowerCLI (required for VMware.ESXi module)...")
                                Install-Module -Name 'VCF.PowerCLI' -Repository PSGallery -Force -Scope AllUsers -AcceptLicense -SkipPublisherCheck -ErrorAction Stop
                                $Writer.WriteLine("VERBOSE: VCF.PowerCLI installed.")
                            }
                            Import-Module VCF.PowerCLI -Force -ErrorAction SilentlyContinue
                        }

                        # Explicitly import Veeam PS module (required on Linux)
                        $VeeamModule = '/opt/veeam/powershell/Veeam.Backup.PowerShell/Veeam.Backup.PowerShell.psd1'
                        if (Test-Path $VeeamModule) {
                            Import-Module $VeeamModule -Force -ErrorAction SilentlyContinue
                            $Writer.WriteLine("VERBOSE: Veeam PS module imported from $VeeamModule")
                        }

                        if (-not (Test-Path $OutputPath)) {
                            New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
                        }

                        $SecPass = ConvertTo-SecureString $Password -AsPlainText -Force
                        $Creds   = New-Object System.Management.Automation.PSCredential($Username, $SecPass)

                        # Build output filename
                        $SafeName    = $ModuleId -replace '[^a-zA-Z0-9._-]', '_'
                        $Timestamp   = Get-Date -Format 'yyyy-MM-dd_HHmm'
                        $OutFilename = "$SafeName.$Timestamp"

                        # Ensure per-module config dir exists
                        $BaseConfigDir  = "/etc/asbuiltreport/$ModuleId"
                        $BaseConfigFile = "$BaseConfigDir/AsBuiltReport.json"
                        if (-not (Test-Path $BaseConfigDir)) {
                            New-Item -ItemType Directory -Path $BaseConfigDir -Force | Out-Null
                        }

                        # Write the AsBuiltReport core config in the exact structure the module expects
                        # This matches the schema saved by New-AsBuiltReport interactively
                        # Report Name must be a valid filename - use module ID with dots replaced
                        $ReportName = "AsBuiltReport.$ModuleId"

                        # Load InfoLevel defaults from the module's own sample JSON if available
                        $ModuleSampleJson = (Get-Module -ListAvailable "AsBuiltReport.$ModuleId" |
                            Select-Object -First 1).ModuleBase + "/AsBuiltReport.$ModuleId.json"

                        $InfoLevel  = [ordered]@{}
                        $Options    = [ordered]@{}
                        if (Test-Path $ModuleSampleJson) {
                            $Sample    = Get-Content $ModuleSampleJson -Raw | ConvertFrom-Json
                            if ($Sample.InfoLevel)  { $InfoLevel  = $Sample.InfoLevel }
                            if ($Sample.Options)    { $Options    = $Sample.Options }
                            $Writer.WriteLine("VERBOSE: Loaded InfoLevel defaults from module sample JSON")
                        }

                        $CoreConfig = [ordered]@{
                            Report = [ordered]@{
                                Name               = $ReportName
                                Author             = "AsBuiltReport Manager"
                                Version            = "1.0"
                                Status             = "Released"
                                ShowCoverPageImage = $false
                                ShowTableOfContents= $true
                                ShowHeaderFooter   = $true
                                ShowSectionNumbers = $false
                                ShowTableCaptions  = $true
                            }
                            UserDefinedVariables = [ordered]@{
                                Company = [ordered]@{
                                    FullName  = ""
                                    ShortName = ""
                                    Contact   = ""
                                    Email     = ""
                                    Phone     = ""
                                    Address   = ""
                                }
                            }
                            InfoLevel = $InfoLevel
                            Options   = $Options
                        }
                        $CoreConfig | ConvertTo-Json -Depth 10 | Set-Content -Path $BaseConfigFile -Encoding UTF8
                        $Writer.WriteLine("VERBOSE: Wrote AsBuiltReport config to $BaseConfigFile")

                        # RVTools replica — custom Excel export script
                        if ($ModuleId -eq 'VMware.RVTools') {
                            $Script = '/app/reports/Get-RVToolsReport.ps1'
                            $Writer.WriteLine("VERBOSE: Using RVTools replica script")
                            # Ensure ImportExcel is available
                            if (-not (Get-Module -ListAvailable -Name 'ImportExcel' -ErrorAction SilentlyContinue)) {
                                $Writer.WriteLine("VERBOSE: Installing ImportExcel module...")
                                Install-Module -Name ImportExcel -Repository PSGallery -Force -Scope AllUsers -AcceptLicense
                            }
                            $PwshArgs = @(
                                '-NonInteractive'
                                '-NoProfile'
                                '-File', $Script
                                '-VCenterServer', $Target
                                '-Username', $Username
                                '-Password', $Password
                                '-ExportExcel'
                                '-ExportPath', $OutputPath
                            )
                            & pwsh @PwshArgs *>&1 | ForEach-Object { $Writer.WriteLine($_.ToString()) }
                            # Mark done — find the generated xlsx
                            $Writer.WriteLine("::DONE::$JobId")

                        # HPE OneView uses a custom script (no AsBuiltReport module available)
                        # IMPORTANT: Must run in a child pwsh process to avoid .NET assembly
                        # conflicts when HPEOneView module is loaded multiple times in same session
                        } elseif ($ModuleId -eq 'HPE.OneView') {
                            $Script = '/app/reports/Invoke-HPEOneViewReport.ps1'
                            $Writer.WriteLine("VERBOSE: Using custom HPE OneView report script (isolated process)")
                            $PwshArgs = @(
                                '-NonInteractive'
                                '-NoProfile'
                                '-File', $Script
                                '-Target', $Target
                                '-Username', $Username
                                '-Password', $Password
                                '-OutputPath', $OutputPath
                                '-JobId', $JobId
                            )
                            & pwsh @PwshArgs *>&1 |
                                ForEach-Object { $Writer.WriteLine($_.ToString()) }
                        } else {
                            $Params = @{
                                Report                = $ModuleId
                                Target                = $Target
                                Credential            = $Creds
                                OutputFolderPath      = $OutputPath
                                Format                = $Formats
                                AsBuiltConfigFilePath = $BaseConfigFile
                                ReportConfigFilePath  = $BaseConfigFile
                                Verbose               = $true
                            }
                            if ((Test-Path $ConfigPath) -and ($ConfigPath -ne $BaseConfigFile)) {
                                $Params['ReportConfigFilePath'] = $ConfigPath
                            }

                            $Writer.WriteLine("VERBOSE: Running New-AsBuiltReport with params:")
                            $Params.GetEnumerator() | Where-Object { $_.Key -ne 'Credential' } | ForEach-Object {
                                $Writer.WriteLine("VERBOSE:   $($_.Key) = $($_.Value)")
                            }

                            New-AsBuiltReport @Params *>&1 | ForEach-Object { $Writer.WriteLine($_.ToString()) }
                        }

                        $Writer.WriteLine("::DONE::$JobId")
                    } catch {
                        $Writer.WriteLine("ERROR: $($_.Exception.Message)")
                        $Writer.WriteLine("ERROR STACK: $($_.ScriptStackTrace)")
                    }
                }
            }

            default {
                Write-Host "[Worker] 404 - no route for '$ReqPath'"
                Send-Json $Context @{ error = "Not found: $ReqPath" } 404
            }
        }

    } catch [System.Net.HttpListenerException] {
        Write-Host "[Worker] Listener stopped."
        break
    } catch {
        Write-Host "[Worker] Unhandled error: $_"
    }
}
