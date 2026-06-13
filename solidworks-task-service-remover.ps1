# ============================================
# SOLIDWORKS Forensic Cleanup Tool
# ASCII Only - PS5.1 Safe - Prompted Actions
# ============================================

# --------------------------------------------
# Logging Setup (Script Directory)
# --------------------------------------------
if ($PSScriptRoot -and $PSScriptRoot.Trim() -ne "") {
    $BaseDir = $PSScriptRoot
} else {
    $BaseDir = (Get-Location).Path
}

$LogDir = Join-Path $BaseDir "Logs"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }

$LogFile = Join-Path $LogDir ("SWBD_Audit_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))

function Log {
    param([string]$Message)
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "$timestamp  $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line
}

function Log-ForensicBlock {
    param([string]$Header, [object]$Data)
    Log "----- FORENSIC BLOCK BEGIN: $Header -----"
    $Data | Out-String | ForEach-Object { Log $_.TrimEnd() }
    Log "----- FORENSIC BLOCK END: $Header -----"
}

function Ask-YesNo {
    param([string]$Prompt)
    $resp = Read-Host "$Prompt (Y/N)"
    Log "User response to '$Prompt' -> $resp"
    return $resp -match '^[Yy]'
}

Log "=== Starting SOLIDWORKS Forensic Cleanup ==="
Log ("Script directory: {0}" -f $BaseDir)
Log ("Log file: {0}" -f $LogFile)

# --------------------------------------------
# 1. SolidWorks services
# --------------------------------------------
Log "[1] Searching for SolidWorks-related services..."

$swServices = Get-Service | Where-Object {
    $_.Name -match "SolidWorks" -or $_.DisplayName -match "SolidWorks"
}

if (-not $swServices) {
    Log "No SolidWorks-related services found."
} else {
    foreach ($svc in $swServices) {
        Log ("Service: {0}" -f $svc.Name)
        Log ("DisplayName: {0}" -f $svc.DisplayName)
        Log ("Status: {0}" -f $svc.Status)

        # Extract BinaryPathName
        try {
            $qc = sc.exe qc $svc.Name 2>&1
            Log-ForensicBlock "Service_QC_Output_$($svc.Name)" $qc

            $binPathLine = $qc | Where-Object { $_ -match "BINARY_PATH_NAME" }
            if ($binPathLine) {
                $rawPath = $binPathLine -replace ".*BINARY_PATH_NAME\s+:", ""
                $rawPath = $rawPath.Trim()
                $exePath = $rawPath.Trim('"')
                Log ("Executable path: {0}" -f $exePath)
            } else {
                Log "Could not extract BINARY_PATH_NAME for service $($svc.Name)."
                continue
            }
        }
        catch {
            Log "ERROR: Failed to query service configuration for $($svc.Name)."
            Log-ForensicBlock "Service_QC_Exception_$($svc.Name)" $_
            continue
        }

        # Directory analysis
        $exeDir = $null
        if (Test-Path $exePath) {
            Log ("Executable exists: {0}" -f $exePath)
            $exeDir = Split-Path $exePath -Parent
            if (Test-Path $exeDir) {
                $files = Get-ChildItem -Recurse $exeDir -ErrorAction SilentlyContinue
                $count = $files.Count
                $size = ($files | Measure-Object -Property Length -Sum).Sum
                Log ("Service directory: {0}" -f $exeDir)
                Log ("File count: {0}" -f $count)
                Log ("Total size (bytes): {0}" -f $size)
            } else {
                Log "Service directory does not exist: $exeDir"
            }
        } else {
            Log ("Executable NOT found: {0}" -f $exePath)
        }

        # Stop service if running
        if ($svc.Status -eq "Running") {
            if (Ask-YesNo "Service '$($svc.DisplayName)' is running. Stop it?") {
                try {
                    Stop-Service $svc -Force -ErrorAction Stop
                    Log "Service stopped: $($svc.Name)"
                }
                catch {
                    Log "ERROR: Failed to stop service $($svc.Name)."
                    Log-ForensicBlock "Service_Stop_Exception_$($svc.Name)" $_
                }
            } else {
                Log "User chose not to stop running service $($svc.Name)."
            }
        } else {
            Log "Service is not running; no stop required for $($svc.Name)."
        }

        # Delete service
        if (Ask-YesNo "Delete service '$($svc.DisplayName)'?") {
            try {
                $del = sc.exe delete $svc.Name 2>&1
                Log-ForensicBlock "Service_Delete_Output_$($svc.Name)" $del
                Log "Service delete command executed for $($svc.Name)."
            }
            catch {
                Log "ERROR: Failed to delete service $($svc.Name)."
                Log-ForensicBlock "Service_Delete_Exception_$($svc.Name)" $_
            }
        } else {
            Log "User chose not to delete service $($svc.Name)."
        }

        # Delete directory
        if ($exeDir -and (Test-Path $exeDir)) {
            if (Ask-YesNo "Delete directory '$exeDir' and its contents?") {
                try {
                    Remove-Item -Recurse -Force $exeDir -ErrorAction Stop
                    if (-not (Test-Path $exeDir)) {
                        Log ("Deleted directory: {0}" -f $exeDir)
                    } else {
                        Log ("WARNING: Delete command executed but directory still exists: {0}" -f $exeDir)
                    }
                }
                catch {
                    Log "ERROR: Failed to delete directory $exeDir."
                    Log-ForensicBlock "Directory_Delete_Exception_$($svc.Name)" $_
                }
            } else {
                Log "User chose not to delete directory $exeDir."
            }
        } else {
            Log "No valid directory to delete for service $($svc.Name)."
        }
    }
}

# --------------------------------------------
# 2. LocalAppData caches
# --------------------------------------------
Log "[2] Checking %LOCALAPPDATA% SolidWorks caches..."

$localApp = $env:LOCALAPPDATA
$cacheDirs = @(
    (Join-Path $localApp "SolidWorks")
    (Join-Path $localApp "swcachedir")
)

foreach ($dir in $cacheDirs) {
    if (Test-Path $dir) {
        $files = Get-ChildItem -Recurse $dir -ErrorAction SilentlyContinue
        $count = $files.Count
        $size = ($files | Measure-Object -Property Length -Sum).Sum
        Log ("Cache directory: {0}" -f $dir)
        Log ("File count: {0}" -f $count)
        Log ("Total size (bytes): {0}" -f $size)

        if (Ask-YesNo "Delete cache directory '$dir' and its contents?") {
            try {
                Remove-Item -Recurse -Force $dir -ErrorAction Stop
                if (-not (Test-Path $dir)) {
                    Log ("Deleted cache directory: {0}" -f $dir)
                } else {
                    Log ("WARNING: Delete command executed but cache directory still exists: {0}" -f $dir)
                }
            }
            catch {
                Log "ERROR: Failed to delete cache directory $dir."
                Log-ForensicBlock "Cache_Delete_Exception_$dir" $_
            }
        } else {
            Log "User chose not to delete cache directory $dir."
        }
    } else {
        Log ("Cache directory not found: {0}" -f $dir)
    }
}

# --------------------------------------------
# 3. Start Menu SOLIDWORKS Installation Manager
# --------------------------------------------
Log "[3] Checking SOLIDWORKS Installation Manager shortcuts..."

$startMenuDir = "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\SOLIDWORKS Installation Manager"

if (Test-Path $startMenuDir) {
    $lnks = Get-ChildItem -Path $startMenuDir -Filter *.lnk -ErrorAction SilentlyContinue
    if ($lnks.Count -gt 0) {
        foreach ($lnk in $lnks) {
            Log ("Shortcut: {0}" -f $lnk.FullName)

            try {
                $shell = New-Object -ComObject WScript.Shell
                $shortcut = $shell.CreateShortcut($lnk.FullName)
                $targetPath = $shortcut.TargetPath
                $arguments = $shortcut.Arguments

                Log ("Shortcut target: {0}" -f $targetPath)
                Log ("Shortcut arguments: {0}" -f $arguments)

                if (Test-Path $targetPath) {
                    Log ("Target executable exists: {0}" -f $targetPath)
                } else {
                    Log ("Target executable NOT found: {0}" -f $targetPath)
                }

                if (Ask-YesNo "Delete shortcut '$($lnk.FullName)'?") {
                    try {
                        Remove-Item -Force $lnk.FullName -ErrorAction Stop
                        if (-not (Test-Path $lnk.FullName)) {
                            Log ("Deleted shortcut: {0}" -f $lnk.FullName)
                        } else {
                            Log ("WARNING: Delete command executed but shortcut still exists: {0}" -f $lnk.FullName)
                        }
                    }
                    catch {
                        Log "ERROR: Failed to delete shortcut $($lnk.FullName)."
                        Log-ForensicBlock "Shortcut_Delete_Exception_$($lnk.Name)" $_
                    }
                } else {
                    Log "User chose not to delete shortcut $($lnk.FullName)."
                }

                if (Test-Path $targetPath) {
                    if (Ask-YesNo "Delete target executable '$targetPath'?") {
                        try {
                            Remove-Item -Force $targetPath -ErrorAction Stop
                            if (-not (Test-Path $targetPath)) {
                                Log ("Deleted target executable: {0}" -f $targetPath)
                            } else {
                                Log ("WARNING: Delete command executed but target still exists: {0}" -f $targetPath)
                            }
                        }
                        catch {
                            Log "ERROR: Failed to delete target executable $targetPath."
                            Log-ForensicBlock "Target_Delete_Exception_$($lnk.Name)" $_
                        }
                    } else {
                        Log "User chose not to delete target executable $targetPath."
                    }
                }
            }
            catch {
                Log "ERROR: Failed to inspect shortcut $($lnk.FullName)."
                Log-ForensicBlock "Shortcut_Inspect_Exception_$($lnk.Name)" $_
            }
        }
    } else {
        Log "No .lnk files found in SOLIDWORKS Installation Manager folder."
    }
} else {
    Log "SOLIDWORKS Installation Manager folder not found: $startMenuDir"
}

# --------------------------------------------
# 4. RUN keys and Startup folders
# --------------------------------------------
Log "[4] Checking RUN keys and Startup folders for SolidWorks..."

$runKeys = @(
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run"
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce"
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce"
)

foreach ($rk in $runKeys) {
    if (Test-Path $rk) {
        $props = Get-ItemProperty $rk -ErrorAction SilentlyContinue
        foreach ($prop in $props.PSObject.Properties) {
            $val = [string]$prop.Value
            if ($prop.Name -match "SolidWorks" -or $val -match "SolidWorks") {
                Log ("RUN entry: Key={0} Name={1} Value={2}" -f $rk, $prop.Name, $val)
                if (Ask-YesNo "Delete RUN entry '$($prop.Name)' from '$rk'?") {
                    try {
                        Remove-ItemProperty -Path $rk -Name $prop.Name -ErrorAction Stop
                        Log ("Deleted RUN entry: {0} from {1}" -f $prop.Name, $rk)
                    }
                    catch {
                        Log "ERROR: Failed to delete RUN entry $($prop.Name) from $rk."
                        Log-ForensicBlock "Run_Delete_Exception_$($prop.Name)" $_
                    }
                } else {
                    Log "User chose not to delete RUN entry $($prop.Name) from $rk."
                }
            }
        }
    } else {
        Log ("RUN key not found: {0}" -f $rk)
    }
}

$startupDirs = @(
    (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup")
    "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup"
)

foreach ($sd in $startupDirs) {
    if (Test-Path $sd) {
        $items = Get-ChildItem -Path $sd -ErrorAction SilentlyContinue
        foreach ($item in $items) {
            if ($item.Name -match "SolidWorks" -or $item.FullName -match "SolidWorks") {
                Log ("Startup item: {0}" -f $item.FullName)
                if (Ask-YesNo "Delete startup item '$($item.FullName)'?") {
                    try {
                        Remove-Item -Force $item.FullName -ErrorAction Stop
                        if (-not (Test-Path $item.FullName)) {
                            Log ("Deleted startup item: {0}" -f $item.FullName)
                        } else {
                            Log ("WARNING: Delete command executed but startup item still exists: {0}" -f $item.FullName)
                        }
                    }
                    catch {
                        Log "ERROR: Failed to delete startup item $($item.FullName)."
                        Log-ForensicBlock "Startup_Delete_Exception_$($item.Name)" $_
                    }
                } else {
                    Log "User chose not to delete startup item $($item.FullName)."
                }
            }
        }
    } else {
        Log ("Startup directory not found: {0}" -f $sd)
    }
}

Log "=== SOLIDWORKS Forensic Cleanup Complete - Log saved to $LogFile ==="
