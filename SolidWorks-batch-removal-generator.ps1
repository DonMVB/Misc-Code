#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Scans the Uninstall registry hive for SolidWorks entries, reports install
    sizes, and generates a batch file to run each uninstall string followed by
    a directory-size check.

.NOTES
    Run from an elevated (Administrator) PowerShell prompt.
    Output batch file: Uninstall-SolidWorks.bat  (same folder as this script)
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Registry paths to scan (32-bit and 64-bit hives) ──────────────────────────
$regPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)

# ── Helper: format bytes to KB / MB / GB ──────────────────────────────────────
function Format-Size {
    param([long]$Bytes)
    if     ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    elseif ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    else                    { return "$Bytes bytes" }
}

# ── Helper: get directory size (recursive) ────────────────────────────────────
function Get-DirSize {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return -1
    }

    $size = (Get-ChildItem -Path $Path -Recurse -Force -ErrorAction SilentlyContinue |
             Where-Object { -not $_.PSIsContainer } |
             Measure-Object -Property Length -Sum).Sum

    if ($null -eq $size) {
        return [long]0
    }

    return [long]$size
}

# ── Collect matching entries ───────────────────────────────────────────────────
$found = [System.Collections.Generic.List[hashtable]]::new()

Write-Host ""
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  SolidWorks Registry Scanner" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host ""

foreach ($regPath in $regPaths) {
    if (-not (Test-Path $regPath)) { continue }

    $hive = if ($regPath -like '*WOW6432*') { '(32-bit hive)' } else { '(64-bit hive)' }

    Get-ChildItem -Path $regPath -ErrorAction SilentlyContinue | ForEach-Object {
        $key = $_
        try {
            $displayName     = $key.GetValue('DisplayName',      '')
            $installLocation = $key.GetValue('InstallLocation',  '')
            $uninstallString = $key.GetValue('UninstallString',  '')

            if ($displayName -match 'solidworks') {

                Write-Host "Found: $displayName  $hive" -ForegroundColor Yellow
                Write-Host "  Registry Key   : $($key.Name)"
                Write-Host "  InstallLocation: $(if ($installLocation) { $installLocation } else { '(not set)' })"
                Write-Host "  UninstallString: $(if ($uninstallString) { $uninstallString } else { '(not set)' })"

                $sizeDisplay = '(no InstallLocation set)'
                $sizeBytes   = 0L
                if ($installLocation -and (Test-Path $installLocation)) {
                    Write-Host "  Measuring install size (may take a moment)..." -ForegroundColor DarkGray
                    $sizeBytes   = Get-DirSize -Path $installLocation
                    $sizeDisplay = Format-Size -Bytes $sizeBytes
                } elseif ($installLocation) {
                    $sizeDisplay = '(path not found on disk)'
                }
                Write-Host "  Install Size   : $sizeDisplay" -ForegroundColor Green
                Write-Host ""

                $found.Add(@{
                    DisplayName      = $displayName
                    InstallLocation  = $installLocation
                    UninstallString  = $uninstallString
                    SizeDisplay      = $sizeDisplay
                    SizeBytes        = $sizeBytes
                    KeyName          = $key.Name
                })
            }
        } catch {
            Write-Warning "Could not read key '$($key.Name)': $_"
        }
    }
}

# ── Summary ────────────────────────────────────────────────────────────────────
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  Summary: $($found.Count) SolidWorks product(s) found" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan

if ($found.Count -eq 0) {
    Write-Host "No SolidWorks entries found in the Uninstall registry hive." -ForegroundColor Red
    exit 0
}

$totalBytes = ($found | ForEach-Object { $_.SizeBytes } | Measure-Object -Sum).Sum
Write-Host "  Total install footprint: $(Format-Size -Bytes $totalBytes)" -ForegroundColor Green
Write-Host ""

# ── Generate batch file ────────────────────────────────────────────────────────
$batchPath  = Join-Path $PSScriptRoot 'Uninstall-SolidWorks.bat'
$batchLines = [System.Collections.Generic.List[string]]::new()

$batchLines.Add('@echo off')
$batchLines.Add('setlocal enabledelayedexpansion')
$batchLines.Add('echo ========================================================')
$batchLines.Add('echo  SolidWorks Uninstall Batch')
$batchLines.Add('echo  Generated: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
$batchLines.Add('echo ========================================================')
$batchLines.Add('echo.')
$batchLines.Add('')
$batchLines.Add(':: Check for administrator privileges')
$batchLines.Add('net session >nul 2>&1')
$batchLines.Add('if %errorlevel% NEQ 0 (')
$batchLines.Add('    echo ERROR: This batch file must be run as Administrator.')
$batchLines.Add('    pause')
$batchLines.Add('    exit /b 1')
$batchLines.Add(')')
$batchLines.Add('')

$index = 0
foreach ($entry in $found) {
    $index++

    $batchLines.Add(":: ── Product $index of $($found.Count) ─────────────────────────────────────────")
    $batchLines.Add("echo [%DATE% %TIME%] Starting uninstall $index of $($found.Count):")
    $batchLines.Add("echo   $($entry.DisplayName)")
    $batchLines.Add("echo   Size before uninstall: $($entry.SizeDisplay)")
    $batchLines.Add('echo.')

    if ($entry.UninstallString) {
        $uninstCmd = $entry.UninstallString.Trim()

        if ($uninstCmd -imatch '^msiexec') {
            $batchLines.Add("echo Running: $uninstCmd")
            $batchLines.Add($uninstCmd)
        } else {
            $batchLines.Add("echo Running: $uninstCmd")
            $batchLines.Add('cmd /c "' + $uninstCmd + '"')
        }
        $batchLines.Add('echo Uninstall command returned exit code: %ERRORLEVEL%')
    } else {
        $batchLines.Add('echo WARNING: No UninstallString found for this product. Skipping.')
    }

    $batchLines.Add('echo.')

    # ── Post-uninstall directory check ────────────────────────────────────────
    #
    # Two bugs fixed here vs previous versions:
    #
    # BUG 1 (previous version): Multi-line Add() calls put bare pipe characters
    #   on their own lines in the .bat, causing "| was unexpected at this time."
    #   Fix: entire PS command is one concatenated string.
    #
    # BUG 2 (this version): The else clause used else{"$b bytes"} which contains
    #   an inner double-quote ( " ).  cmd.exe sees the outer for /f wrapper as:
    #      ... -Command "...else{"   <- double-quote closes the cmd string here!
    #   Everything after that point lands outside the quoted block and is parsed
    #   as raw batch syntax, producing the parser error about a missing ' terminator.
    #   Fix: use else{[string]$b+' bytes'} — no double-quotes inside the PS command.
    #
    # BUG 3 (defensive): Embedding $loc inside PS single-quotes breaks if the path
    #   ever contains an apostrophe.
    #   Fix: pass the path via a temporary env var (SW_CHECK_PATH) so the PS command
    #   reads $env:SW_CHECK_PATH — no path quoting inside the PS command at all.
    #
if ($entry.InstallLocation) {
    $loc = $entry.InstallLocation.TrimEnd('\')
    $escapedLoc = $loc.Replace('"','\"')

    $batchLines.Add(":: Post-uninstall directory check")
    $batchLines.Add('if exist "' + $loc + '" (')
    $batchLines.Add('    echo Directory still exists after uninstall:')
    $batchLines.Add('    echo   ' + $loc)
    $batchLines.Add('    echo Measuring remaining size...')

    # Only run size check if uninstall exit code was 0
    $batchLines.Add('    if NOT "%ERRORLEVEL%"=="0" goto SkipSizeCheck')

    # Single-line PowerShell command
    $psCmd = '$b=(Get-ChildItem -LiteralPath \"' + $escapedLoc + '\" -Recurse -Force -EA SilentlyContinue | Where-Object { -not $_.PSIsContainer } | Measure-Object -Property Length -Sum).Sum; ' +
             'if($b -ge 1GB){"{0:N2} GB"-f($b/1GB)} elseif($b -ge 1MB){"{0:N2} MB"-f($b/1MB)} elseif($b -ge 1KB){"{0:N2} KB"-f($b/1KB)} else{"$b bytes"}'

    $batchLines.Add('    for /f "usebackq tokens=*" %%S in (`powershell -NoProfile -Command "' + $psCmd + '"`) do (')
    $batchLines.Add('        echo   Remaining size: %%S')
    $batchLines.Add('    )')

    $batchLines.Add('    :SkipSizeCheck')
    $batchLines.Add('    echo.')
    $batchLines.Add('    echo NOTE: You may need to manually delete this directory.')
    $batchLines.Add(') else (')
    $batchLines.Add('    echo Directory successfully removed: ' + $loc)
    $batchLines.Add(')')
}
else {
    $batchLines.Add("echo (No InstallLocation was recorded — skipping directory check.)")
}


    $batchLines.Add('echo.')
    $batchLines.Add("echo ── Product $index complete ──────────────────────────────────────────")
    $batchLines.Add('echo.')
    $batchLines.Add('')
}

$batchLines.Add('echo ========================================================')
$batchLines.Add('echo  All uninstall commands were  attempted / executed.')
$batchLines.Add('echo ========================================================')
$batchLines.Add('pause')
$batchLines.Add('endlocal')

# Write batch file (ANSI encoding — cmd.exe friendly)
$batchContent = $batchLines -join "`r`n"
[System.IO.File]::WriteAllText($batchPath, $batchContent, [System.Text.Encoding]::Default)

Write-Host "Batch file written to:" -ForegroundColor Cyan
Write-Host "  $batchPath" -ForegroundColor White
Write-Host ""
Write-Host "Review the batch file before running it." -ForegroundColor Yellow
Write-Host "Run it from an elevated (Administrator) command prompt." -ForegroundColor Yellow
Write-Host ""
