<#
    Ollama / OpenWebUI / Docker / Rancher Desktop / LM Studio System Audit
    Version: 1.9
    Written: 2026-07-03 11:05 EDT
    Updated: 2026-07-05 (added startup / autostart persistence audit)
    Author: Copilot

    PURPOSE:
      Exhaustively audit Windows 11 for:
        - Ollama
        - Open WebUI
        - Docker Desktop
        - Rancher Desktop
        - WSL
        - LM Studio

      For each application:
        - Processes
        - Services
        - Scheduled tasks
        - Startup / autostart entries (see below)
        - Install directories
        - Registry uninstall entries
        - CLI behavior (where applicable)
        - AI-related network ports

    STARTUP / AUTOSTART COVERAGE (new in 1.9):
      Detects the logon-persistence mechanisms that surface in the
      Windows 11 Task Manager "Startup apps" tab, which is what a
      per-user "task" like ollama.exe actually comes from:
        - Run / RunOnce registry keys:
            HKCU\Software\Microsoft\Windows\CurrentVersion\Run
            HKLM\Software\Microsoft\Windows\CurrentVersion\Run
            HKLM\Software\WOW6432Node\...\Run  (32-bit)
            plus the RunOnce variants of each
        - Task Manager enabled/disabled state, read from the
          StartupApproved keys (disabling in Task Manager does NOT
          delete the Run entry; it writes an override here). The
          disable timestamp is decoded where present.
        - Startup folders (shortcuts resolved to their targets):
            %APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup
            %PROGRAMDATA%\Microsoft\Windows\Start Menu\Programs\Startup
        - App execution aliases:
            %LOCALAPPDATA%\Microsoft\WindowsApps
            plus App Paths registry keys
      Scheduled Tasks and service wrappers are already covered by the
      dedicated Scheduled tasks and Services sections above.

    NOTES:
      - Read-only
      - Modular, application-centric
      - Compact, consistent output
      - Three-space indentation under each app section
      - Printable ASCII only
#>

$ErrorActionPreference = 'Stop'

# Timing
$startTime = Get-Date
Write-Host "Audit started at $startTime"

# Output file
$timestamp  = $startTime.ToString("yyyyMMdd_HHmmss")
$reportPath = Join-Path -Path $env:TEMP -ChildPath "System_Audit_$timestamp.txt"

function Write-Section {
    param([string]$Title)
    Add-Content -Path $reportPath -Value ""
    Add-Content -Path $reportPath -Value "==== $Title ===="
}

function Invoke-SafeCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,
        [string[]]$Arguments = @()
    )

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $Command
        $psi.Arguments              = ($Arguments -join ' ')
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        $null = $proc.Start()

        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()

        if ($stderr -and $stderr.Trim().Length -gt 0) {
            return "STDERR:`n$stderr"
        }

        if ($stdout -and $stdout.Trim().Length -gt 0) {
            return $stdout
        }

        return "Command executed but produced no output."
    }
    catch {
        return "Exception: $($_.Exception.Message)"
    }
}

function Test-CommandPresent {
    param([string]$Name)
    $cmd = Get-Command -Name $Name -ErrorAction SilentlyContinue
    return [bool]$cmd
}

function Is-OutputFailure {
    param([string]$Output)
    if (-not $Output) { return $true }
    if ($Output -like "Exception:*") { return $true }
    if ($Output -like "*not recognized*") { return $true }
    if ($Output -like "*Cannot connect*") { return $true }
    if ($Output -like "*failed to connect*") { return $true }
    return $false
}

function Extract-ErrorMessage {
    param([string]$Output)
    if (-not $Output) { return "Unknown error." }
    if ($Output -like "STDERR:*") {
        $lines = $Output -split "`r?`n"
        $errLines = $lines | Where-Object { $_ -and ($_ -notlike "STDERR:*") }
        if ($errLines.Count -gt 0) {
            return ($errLines -join " ")
        }
        else {
            return $Output
        }
    }
    return $Output
}

# Preload global data
$allProcesses = Get-Process | Sort-Object -Property ProcessName
$allServices  = Get-Service
$allTasks     = $null
try { $allTasks = Get-ScheduledTask } catch { $allTasks = @() }

$netstatOutput = Invoke-SafeCommand "netstat" @("-ano")

"Audit started: $startTime" | Out-File -FilePath $reportPath -Encoding UTF8

# Application definitions
$appDefs = @(
    @{
        Name              = "Ollama"
        ProcessPatterns   = @("ollama")
        ServiceCandidates = @()
        TaskPatterns      = @("ollama")
        InstallPaths      = @(
            "$env:LOCALAPPDATA\Ollama",
            "$env:LOCALAPPDATA\Programs\Ollama",
            "$env:APPDATA\Ollama",
            "$env:USERPROFILE\.ollama",
            "C:\Program Files\Ollama",
            "C:\ProgramData\Ollama"
        )
        RegistryPatterns  = @("ollama")
        CliName           = "ollama"
        CliChecks         = @(
            @{ Label = "Version check"; Command = "ollama"; Args = @("--version") },
            @{ Label = "Model list";   Command = "ollama"; Args = @("list") }
        )
        Ports             = @(
            @{ Port = ":11434"; Comment = "Ollama Windows desktop: 11434" }
        )
    },
    @{
        Name              = "Open WebUI"
        ProcessPatterns   = @("open-webui","openwebui")
        ServiceCandidates = @()
        TaskPatterns      = @("open-webui","openwebui")
        InstallPaths      = @(
            "$env:LOCALAPPDATA\open-webui",
            "$env:APPDATA\open-webui",
            "$env:USERPROFILE\.open-webui",
            "C:\Program Files\Open WebUI",
            "C:\ProgramData\open-webui"
        )
        RegistryPatterns  = @("open webui","open-webui")
        CliName           = $null
        CliChecks         = @()
        Ports             = @(
            @{ Port = ":3000"; Comment = "Open WebUI: 3000" },
            @{ Port = ":8080"; Comment = "Open WebUI: 8080" }
        )
    },
    @{
        Name              = "Docker Desktop"
        ProcessPatterns   = @("docker","dockerd")
        ServiceCandidates = @("com.docker.service","Docker Desktop Service")
        TaskPatterns      = @("Docker Desktop","docker")
        InstallPaths      = @(
            "C:\Program Files\Docker",
            "C:\ProgramData\Docker"
        )
        RegistryPatterns  = @("docker")
        CliName           = "docker"
        CliChecks         = @(
            @{ Label = "Info";           Command = "docker"; Args = @("info") },
            @{ Label = "Container list"; Command = "docker"; Args = @("ps","-a") },
            @{ Label = "Image list";     Command = "docker"; Args = @("images") }
        )
        Ports             = @(
            @{ Port = ":2375"; Comment = "Docker daemon (TCP): 2375" },
            @{ Port = ":2376"; Comment = "Docker daemon (TLS): 2376" }
        )
    },
    @{
        Name              = "Rancher Desktop"
        ProcessPatterns   = @("rancher","nerdctl","containerd")
        ServiceCandidates = @("containerd","containerd-shim")
        TaskPatterns      = @("rancher")
        InstallPaths      = @(
            "C:\Program Files\Rancher Desktop",
            "C:\ProgramData\RancherDesktop"
        )
        RegistryPatterns  = @("rancher")
        CliName           = "nerdctl"
        CliChecks         = @(
            @{ Label = "Info";           Command = "nerdctl"; Args = @("info") },
            @{ Label = "Container list"; Command = "nerdctl"; Args = @("ps","-a") },
            @{ Label = "Image list";     Command = "nerdctl"; Args = @("images") }
        )
        Ports             = @()
    },
    @{
        Name              = "WSL"
        ProcessPatterns   = @("wsl","vmmem","vmmemWSL")
        ServiceCandidates = @("LxssManager","WSLService","WSLHost")
        TaskPatterns      = @("wsl")
        InstallPaths      = @(
            "C:\Windows\System32\wsl.exe"
        )
        RegistryPatterns  = @("Windows Subsystem for Linux","WSL")
        CliName           = "wsl"
        CliChecks         = @(
            @{ Label = "List distros"; Command = "wsl"; Args = @("--list","--verbose") }
        )
        Ports             = @()
    },
    @{
        Name              = "LM Studio"
        ProcessPatterns   = @("lmstudio","lmstudio-gpu","lmstudio-server")
        ServiceCandidates = @()
        TaskPatterns      = @("lmstudio")
        InstallPaths      = @(
            "$env:LOCALAPPDATA\LM Studio",
            "$env:APPDATA\LM Studio",
            "$env:USERPROFILE\.lmstudio",
            "C:\Program Files\LM Studio",
            "C:\ProgramData\LM Studio"
        )
        RegistryPatterns  = @("LM Studio","LMStudio")
        CliName           = "lmstudio"
        CliChecks         = @(
            @{ Label = "Version check"; Command = "lmstudio"; Args = @("--version") },
            @{ Label = "Model list";    Command = "lmstudio"; Args = @("list-models") },
            @{ Label = "Status";        Command = "lmstudio"; Args = @("status") }
        )
        Ports             = @(
            @{ Port = ":1234"; Comment = "LM Studio local server: 1234" },
            @{ Port = ":8000"; Comment = "LM Studio local server: 8000" },
            @{ Port = ":9990"; Comment = "LM Studio legacy server: 9990" }
        )
    }
)

function Audit-Processes {
    param(
        [string]$AppName,
        [string[]]$Patterns
    )

    Add-Content -Path $reportPath -Value "   Processes:"
    foreach ($pattern in $Patterns) {
        $matches = $allProcesses | Where-Object { $_.ProcessName -like "*$pattern*" }
        if ($matches) {
            foreach ($m in $matches) {
                Add-Content -Path $reportPath -Value (
                    "      Name=$($m.ProcessName), Id=$($m.Id), WS(MB)=$([math]::Round($m.WorkingSet64/1MB,2))"
                )
            }
        }
        else {
            Add-Content -Path $reportPath -Value ("      Pattern '{0}': NotFound" -f $pattern)
        }
    }
}

function Audit-Services {
    param(
        [string]$AppName,
        [string[]]$Candidates
    )

    if (-not $Candidates -or $Candidates.Count -eq 0) {
        Add-Content -Path $reportPath -Value "   Services: (None defined)"
        return
    }

    Add-Content -Path $reportPath -Value "   Services:"
    $candList = [string]::Join(", ", $Candidates)
    Add-Content -Path $reportPath -Value ("      Service candidates: {0}" -f $candList)

    $found = $false
    foreach ($cand in $Candidates) {
        $svcMatch = $allServices | Where-Object {
            $_.Name -like "*$cand*" -or $_.DisplayName -like "*$cand*"
        }
        if ($svcMatch) {
            $found = $true
            foreach ($s in $svcMatch) {
                Add-Content -Path $reportPath -Value (
                    "      Found: Name=$($s.Name), DisplayName=$($s.DisplayName), Status=$($s.Status), StartType=$($s.StartType)"
                )
            }
        }
    }

    if (-not $found) {
        Add-Content -Path $reportPath -Value "      Found: NotFound"
    }
}

function Audit-Tasks {
    param(
        [string]$AppName,
        [string[]]$Patterns
    )

    if (-not $Patterns -or $Patterns.Count -eq 0) {
        Add-Content -Path $reportPath -Value "   Scheduled tasks: (None defined)"
        return
    }

    Add-Content -Path $reportPath -Value "   Scheduled tasks:"
    if (-not $allTasks -or $allTasks.Count -eq 0) {
        Add-Content -Path $reportPath -Value "      No scheduled tasks available (Get-ScheduledTask failed or returned none)."
        return
    }

    $anyFound = $false
    foreach ($pattern in $Patterns) {
        $matches = $allTasks | Where-Object {
            $_.TaskName -like "*$pattern*" -or $_.TaskPath -like "*$pattern*"
        }
        if ($matches) {
            $anyFound = $true
            foreach ($t in $matches) {
                $info = $t | Get-ScheduledTaskInfo
                Add-Content -Path $reportPath -Value (
                    "      Task=$($t.TaskName), Path=$($t.TaskPath), State=$($info.State), LastRun=$($info.LastRunTime), NextRun=$($info.NextRunTime)"
                )
            }
        }
    }

    if (-not $anyFound) {
        Add-Content -Path $reportPath -Value "      Found: NotFound"
    }
}

function Resolve-ShortcutTarget {
    # Resolve a .lnk shortcut to its target path so startup-folder
    # shortcuts can be matched on what they actually launch.
    param([string]$LnkPath)

    $target = $null
    try {
        $shell    = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($LnkPath)
        $target   = $shortcut.TargetPath
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
    }
    catch {
        $target = $null
    }
    return $target
}

function Get-StartupApprovedState {
    # Task Manager stores the enabled/disabled state of a startup item
    # as a 12-byte binary value under a StartupApproved key, keyed by the
    # same value name as the Run entry, or by the shortcut file name for
    # startup-folder items.
    #
    # Byte layout:
    #   bytes 0-3 : status DWORD (little-endian); byte 0 is the flag
    #   bytes 4-11: FILETIME of when the item was disabled (zero if enabled)
    #
    # Flag byte values:
    #   0x00 or 0x02 = Enabled
    #   0x03         = Disabled (via Task Manager / Startup Apps)
    #   0x06         = Disabled (other, e.g. policy)
    #   anything else that is not 0x00/0x02 is treated as Disabled.
    param(
        [string]$ApprovedKeyPath,
        [string]$ValueName
    )

    $result = [ordered]@{
        State        = "Enabled (no StartupApproved override)"
        RawFirstByte = $null
        DisabledOn   = $null
    }

    if (-not $ApprovedKeyPath) {
        return $result
    }

    try {
        $item = Get-ItemProperty -Path $ApprovedKeyPath -Name $ValueName -ErrorAction Stop
        $data = $item.$ValueName

        if ($data -is [byte[]] -and $data.Length -ge 1) {
            $b0                  = $data[0]
            $result.RawFirstByte = ("0x{0:X2}" -f $b0)

            if ($b0 -eq 0x00 -or $b0 -eq 0x02) {
                $result.State = "Enabled"
            }
            else {
                $result.State = "Disabled"
                if ($data.Length -ge 12) {
                    try {
                        $ft = [System.BitConverter]::ToInt64($data, 4)
                        if ($ft -gt 0) {
                            $result.DisabledOn = [DateTime]::FromFileTime($ft)
                        }
                    }
                    catch {
                        # leave DisabledOn null if the timestamp is unreadable
                    }
                }
            }
        }
    }
    catch {
        # No value present in StartupApproved: item has never been toggled,
        # so it runs by default. Keep the default "Enabled (no override)".
    }

    return $result
}

function Format-ApprovedState {
    # Compact one-line rendering of a StartupApproved state object.
    param($StateObj)
    $text = $StateObj.State
    if ($StateObj.RawFirstByte) {
        $text = "$text (flag=$($StateObj.RawFirstByte))"
    }
    if ($StateObj.DisabledOn) {
        $text = "$text, disabled on $($StateObj.DisabledOn)"
    }
    return $text
}

function Audit-Startup {
    # Detects logon-persistence entries that appear in the Windows 11
    # Task Manager "Startup apps" tab: Run/RunOnce registry keys,
    # startup folders, and app execution aliases. Reports the Task
    # Manager enabled/disabled state for each match.
    param(
        [string]$AppName,
        [string[]]$Patterns
    )

    Add-Content -Path $reportPath -Value "   Startup / autostart entries:"

    if (-not $Patterns -or $Patterns.Count -eq 0) {
        Add-Content -Path $reportPath -Value "      No startup patterns defined for this application."
        return
    }

    $anyFound = $false

    # --- 1. Run / RunOnce registry keys -------------------------------
    Add-Content -Path $reportPath -Value "      Run / RunOnce registry keys:"

    $runKeys = @(
        @{ Label = "HKCU Run";              Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run";                       Approved = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run" },
        @{ Label = "HKCU RunOnce";          Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce";                   Approved = $null },
        @{ Label = "HKLM Run";              Path = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run";                       Approved = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run" },
        @{ Label = "HKLM RunOnce";          Path = "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce";                   Approved = $null },
        @{ Label = "HKLM Run (WOW6432)";    Path = "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run";           Approved = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32" },
        @{ Label = "HKLM RunOnce (WOW6432)"; Path = "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce";      Approved = $null }
    )

    foreach ($rk in $runKeys) {
        try {
            $key = Get-Item -Path $rk.Path -ErrorAction SilentlyContinue
            if (-not $key) { continue }

            foreach ($valueName in $key.GetValueNames()) {
                if ([string]::IsNullOrEmpty($valueName)) { continue }
                $valueData = [string]$key.GetValue($valueName)

                $matched = $false
                foreach ($pattern in $Patterns) {
                    if ($valueName -like "*$pattern*" -or $valueData -like "*$pattern*") {
                        $matched = $true
                        break
                    }
                }

                if ($matched) {
                    $anyFound = $true
                    $state    = Get-StartupApprovedState -ApprovedKeyPath $rk.Approved -ValueName $valueName
                    $stateStr = Format-ApprovedState -StateObj $state
                    Add-Content -Path $reportPath -Value ("         [{0}] Name={1}, Command={2}" -f $rk.Label, $valueName, $valueData)
                    Add-Content -Path $reportPath -Value ("            TaskMgr state: {0}" -f $stateStr)
                }
            }
        }
        catch {
            # ignore per-key access errors
        }
    }

    # --- 2. Startup folders (shortcuts and loose files) ---------------
    Add-Content -Path $reportPath -Value "      Startup folders:"

    $startupFolders = @(
        @{ Label = "User Startup folder";   Path = (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup");     Approved = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder" },
        @{ Label = "Common Startup folder"; Path = (Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\Startup"); Approved = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder" }
    )

    foreach ($sf in $startupFolders) {
        if (-not [System.IO.Directory]::Exists($sf.Path)) { continue }
        try {
            $entries = Get-ChildItem -Path $sf.Path -File -ErrorAction SilentlyContinue
            foreach ($entry in $entries) {
                $targetPath = $null
                if ($entry.Extension -ieq ".lnk") {
                    $targetPath = Resolve-ShortcutTarget -LnkPath $entry.FullName
                }

                $matched = $false
                foreach ($pattern in $Patterns) {
                    if ($entry.Name -like "*$pattern*" -or ($targetPath -and $targetPath -like "*$pattern*")) {
                        $matched = $true
                        break
                    }
                }

                if ($matched) {
                    $anyFound = $true
                    $state    = Get-StartupApprovedState -ApprovedKeyPath $sf.Approved -ValueName $entry.Name
                    $stateStr = Format-ApprovedState -StateObj $state
                    if ($targetPath) {
                        Add-Content -Path $reportPath -Value ("         [{0}] File={1} -> Target={2}" -f $sf.Label, $entry.Name, $targetPath)
                    }
                    else {
                        Add-Content -Path $reportPath -Value ("         [{0}] File={1}" -f $sf.Label, $entry.Name)
                    }
                    Add-Content -Path $reportPath -Value ("            TaskMgr state: {0}" -f $stateStr)
                }
            }
        }
        catch {
            # ignore per-folder access errors
        }
    }

    # --- 3. App execution aliases and App Paths -----------------------
    Add-Content -Path $reportPath -Value "      App execution aliases / App Paths:"

    $aliasDir = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps"
    if ([System.IO.Directory]::Exists($aliasDir)) {
        try {
            $aliases = Get-ChildItem -Path $aliasDir -File -ErrorAction SilentlyContinue
            foreach ($alias in $aliases) {
                $matched = $false
                foreach ($pattern in $Patterns) {
                    if ($alias.Name -like "*$pattern*") { $matched = $true; break }
                }
                if ($matched) {
                    $anyFound   = $true
                    $isReparse  = ($alias.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
                    $kind       = if ($isReparse) { "execution alias (reparse point)" } else { "file" }
                    Add-Content -Path $reportPath -Value ("         [WindowsApps] Name={0} ({1})" -f $alias.Name, $kind)
                }
            }
        }
        catch {
            # ignore alias enumeration errors
        }
    }

    $appPathRoots = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths"
    )
    foreach ($apRoot in $appPathRoots) {
        try {
            $subKeys = Get-ChildItem -Path $apRoot -ErrorAction SilentlyContinue
            foreach ($sk in $subKeys) {
                $matched = $false
                foreach ($pattern in $Patterns) {
                    if ($sk.PSChildName -like "*$pattern*") { $matched = $true; break }
                }
                if ($matched) {
                    $anyFound  = $true
                    $props     = Get-ItemProperty -Path $sk.PSPath -ErrorAction SilentlyContinue
                    $exePath   = if ($props -and $props.'(default)') { $props.'(default)' } else { "(no default value)" }
                    Add-Content -Path $reportPath -Value ("         [App Paths] Key={0}, Path={1}" -f $sk.PSChildName, $exePath)
                }
            }
        }
        catch {
            # ignore App Paths access errors
        }
    }

    if (-not $anyFound) {
        Add-Content -Path $reportPath -Value "      Found: NotFound"
    }
}

function Format-Size {
    param([long]$Bytes)

    if ($Bytes -ge 1GB) {
        $gb = [math]::Round($Bytes / 1GB, 2)
        return "$gb GB"
    }
    elseif ($Bytes -ge 1MB) {
        $mb = [math]::Round($Bytes / 1MB, 2)
        return "$mb MB"
    }
    else {
        $kb = [math]::Round($Bytes / 1KB, 2)
        return "$kb KB"
    }
}

function Audit-InstallDirs {
    param(
        [string]$AppName,
        [string[]]$Paths
    )

    Add-Content -Path $reportPath -Value "   Install directories:"
    $foundAny = $false

    foreach ($path in $Paths) {
        if ([System.IO.Directory]::Exists($path)) {
            $foundAny = $true
            try {
                $items = Get-ChildItem -Path $path -Recurse -ErrorAction SilentlyContinue
                $files = $items | Where-Object { -not $_.PSIsContainer }
                $fileCount = $files.Count
                $totalBytes = ($files | Measure-Object -Property Length -Sum).Sum
                if (-not $totalBytes) { $totalBytes = 0 }
                $sizeStr = Format-Size -Bytes $totalBytes
                $createTime = [System.IO.Directory]::GetCreationTime($path)

                Add-Content -Path $reportPath -Value ("      FOUND: {0}" -f $path)
                Add-Content -Path $reportPath -Value ("         Files: {0}  Size: {1}  Created: {2}" -f $fileCount, $sizeStr, $createTime)
            }
            catch {
                Add-Content -Path $reportPath -Value ("      FOUND: {0}" -f $path)
                Add-Content -Path $reportPath -Value ("         Error enumerating: {0}" -f $_.Exception.Message)
            }
        }
        else {
            Add-Content -Path $reportPath -Value ("      NOT FOUND: {0}" -f $path)
        }
    }
}

function Audit-Registry {
    param(
        [string]$AppName,
        [string[]]$Patterns
    )

    Add-Content -Path $reportPath -Value "   Registry uninstall entries:"

    $roots = @(
        @{ Hive = "HKLM (64-bit)"; Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall" },
        @{ Hive = "HKLM (32-bit WOW6432Node)"; Path = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall" },
        @{ Hive = "HKCU"; Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall" }
    )

    foreach ($root in $roots) {
        $hiveName = $root.Hive
        $path     = $root.Path
        Add-Content -Path $reportPath -Value ("      {0}:" -f $hiveName)

        $foundAny = $false
        try {
            $keys = Get-ChildItem -Path $path -ErrorAction SilentlyContinue
            foreach ($key in $keys) {
                $props = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
                if ($props.DisplayName) {
                    foreach ($pattern in $Patterns) {
                        if ($props.DisplayName -like "*$pattern*") {
                            $foundAny = $true
                            Add-Content -Path $reportPath -Value (
                                "         Path=$($key.PSPath), Name=$($props.DisplayName), Publisher=$($props.Publisher), InstallLocation=$($props.InstallLocation), UninstallString=$($props.UninstallString)"
                            )
                        }
                    }
                }
            }
        }
        catch {
            # ignore per-root errors
        }

        if (-not $foundAny) {
            Add-Content -Path $reportPath -Value "         None Found"
        }
    }
}

function Audit-CLI {
    param(
        [string]$AppName,
        [string]$CliName,
        [array]$Checks
    )

    Add-Content -Path $reportPath -Value "   CLI checks:"
    if (-not $CliName) {
        Add-Content -Path $reportPath -Value "      No CLI defined for this application."
        return
    }

    if (-not (Test-CommandPresent $CliName)) {
        Add-Content -Path $reportPath -Value ("      {0} CLI not found in PATH." -f $CliName)
        return
    }

    $failCount = 0

    foreach ($check in $Checks) {
        $label   = $check.Label
        $command = $check.Command
        $args    = $check.Args

        $output  = Invoke-SafeCommand $command $args
        $cmdText = "$command " + ($args -join " ")

        if (Is-OutputFailure $output) {
            $failCount++
            Add-Content -Path $reportPath -Value ("      {0}: Command '{1}' Command failed." -f $label, $cmdText)
        }
        else {
            if ($output -like "STDERR:*") {
                $errMsg = Extract-ErrorMessage $output
                Add-Content -Path $reportPath -Value ("      {0}: Command '{1}' Error: {2}" -f $label, $cmdText, $errMsg)
            }
            else {
                Add-Content -Path $reportPath -Value ("      {0}: Command '{1}'" -f $label, $cmdText)
                Add-Content -Path $reportPath -Value ("      {0}" -f $output)
            }
        }

        if ($failCount -ge 2) {
            Add-Content -Path $reportPath -Value ("      Multiple CLI failures detected for {0}. Skipping remaining checks." -f $CliName)
            break
        }
    }
}

function Audit-Ports {
    param(
        [string]$AppName,
        [array]$Ports
    )

    Add-Content -Path $reportPath -Value "   Network ports (AI-related):"
    if (-not $Ports -or $Ports.Count -eq 0) {
        Add-Content -Path $reportPath -Value "      No specific AI-related ports defined for this application."
        return
    }

    foreach ($p in $Ports) {
        $port    = $p.Port
        $comment = $p.Comment
        $lines   = $netstatOutput -split "`r?`n" | Where-Object { $_ -like "*$port*" }

        if ($lines -and $lines.Count -gt 0) {
            Add-Content -Path $reportPath -Value ("      {0} Found" -f $comment)
            foreach ($line in $lines) {
                Add-Content -Path $reportPath -Value ("         {0}" -f $line)
            }
        }
        else {
            Add-Content -Path $reportPath -Value ("      {0} None Found." -f $comment)
        }
    }
}

# Main audit loop
Write-Section -Title "Application Audit"

$index = 1
$total = $appDefs.Count

foreach ($app in $appDefs) {
    $name      = $app.Name
    $procPat   = $app.ProcessPatterns
    $svcCand   = $app.ServiceCandidates
    $taskPat   = $app.TaskPatterns
    $paths     = $app.InstallPaths
    $regPat    = $app.RegistryPatterns
    $cliName   = $app.CliName
    $cliChecks = $app.CliChecks
    $ports     = $app.Ports

    # Effective startup patterns: process patterns plus registry (display-name)
    # patterns, deduplicated. Covers Run value names, shortcut file names, and
    # launch command paths without needing a separate field per app.
    $startupPat = @()
    if ($procPat) { $startupPat += $procPat }
    if ($regPat)  { $startupPat += $regPat }
    $startupPat = $startupPat | Sort-Object -Unique

    Write-Host "[${index}/$total] Auditing application: $name..."
    Add-Content -Path $reportPath -Value ""
    Add-Content -Path $reportPath -Value ("Application: {0}" -f $name)

    Audit-Processes   -AppName $name -Patterns $procPat
    Audit-Services    -AppName $name -Candidates $svcCand
    Audit-Tasks       -AppName $name -Patterns $taskPat
    Audit-Startup     -AppName $name -Patterns $startupPat
    Audit-InstallDirs -AppName $name -Paths $paths
    Audit-Registry    -AppName $name -Patterns $regPat
    Audit-CLI         -AppName $name -CliName $cliName -Checks $cliChecks
    Audit-Ports       -AppName $name -Ports $ports

    $index++
}

# Summary
Write-Section -Title "Summary"

$endTime = Get-Date
$delta   = New-TimeSpan -Start $startTime -End $endTime

Add-Content -Path $reportPath -Value ("Start Time: {0}" -f $startTime)
Add-Content -Path $reportPath -Value ("End Time:   {0}" -f $endTime)
Add-Content -Path $reportPath -Value ("Duration:   {0}" -f $delta.ToString())
Add-Content -Path $reportPath -Value ("Report:     {0}" -f $reportPath)

Write-Host "Audit complete."
Write-Host ("Report written to: {0}" -f $reportPath)
Write-Host ("Total duration: {0}" -f $delta.ToString())
