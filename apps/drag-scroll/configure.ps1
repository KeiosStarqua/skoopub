#Requires -Version 5.1
<#
.SYNOPSIS
    Installs and starts AutoHotkey drag-to-scroll as a LibreScroll replacement.

.DESCRIPTION
    Deploys the repo-managed AutoHotkey v2 script to
    %LOCALAPPDATA%\skoop\drag-scroll\mouse-scroll.ahk, installs AutoHotkey v2
    with Scoop when it is missing, writes a per-user Startup shortcut and
    starts the script when it is not already running. Idempotent: re-runs only
    repair the copy/shortcut/process. Hold the RIGHT mouse button and move the
    mouse to scroll; release to stop. Unlike LibreScroll this does not block
    physical wheel events, so skoopub-mouse diagnostics are unaffected.
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$NoLaunch,
    [switch]$NoAutostart
)

$ErrorActionPreference = 'Stop'

$source = Join-Path $PSScriptRoot 'mouse-scroll.ahk'
if (-not (Test-Path -LiteralPath $source)) { throw "missing $source" }

$installDir = Join-Path $env:LOCALAPPDATA 'skoop\drag-scroll'
$scriptPath = Join-Path $installDir 'mouse-scroll.ahk'
New-Item -ItemType Directory -Force -Path $installDir | Out-Null

# --- 1. AutoHotkey v2 ---------------------------------------------------------
$autohotkey = Get-Command autohotkey -ErrorAction SilentlyContinue
if (-not $autohotkey) {
    $scoop = Get-Command scoop -ErrorAction SilentlyContinue
    if (-not $scoop) { throw 'autohotkey not found and scoop is unavailable; install AutoHotkey v2 first' }
    Write-Host '==> installing AutoHotkey v2 with Scoop'
    & $scoop.Source install autohotkey
    $autohotkey = Get-Command autohotkey -ErrorAction SilentlyContinue
}
if (-not $autohotkey) { throw 'autohotkey v2 is not on PATH after install' }
$ahkExe = $autohotkey.Source
Write-Host "==> using AutoHotkey: $ahkExe"

# --- 2. Deploy the script ------------------------------------------------------
function Read-Normalized {
    param([string]$Path)
    return ((Get-Content -Raw -LiteralPath $Path) -replace "`r`n", "`n").TrimEnd()
}

$changed = $true
if (Test-Path -LiteralPath $scriptPath) {
    $changed = (Read-Normalized $scriptPath) -ne (Read-Normalized $source)
    if (-not $changed -and -not $Force) {
        Write-Host "==> $scriptPath already up to date"
    } else {
        if (-not $Force) {
            $backup = '{0}.bak.{1}' -f $scriptPath, (Get-Date -Format 'yyyyMMdd-HHmmss')
            Copy-Item -LiteralPath $scriptPath -Destination $backup -Force
            Write-Host "    backed up $scriptPath -> $backup"
        }
    }
}
if ($changed -or $Force) {
    # A running instance holds the script open; stop it before overwriting.
    $running = @(Get-CimInstance Win32_Process -Filter "Name='autohotkey.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*mouse-scroll.ahk*" })
    if ($running.Count -gt 0) {
        $running | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Milliseconds 400
    }
    Copy-Item -LiteralPath $source -Destination $scriptPath -Force
    Write-Host "==> installed $scriptPath"
}

# --- 3. Autostart shortcut ----------------------------------------------------
if (-not $NoAutostart) {
    $startup = [Environment]::GetFolderPath('Startup')
    if ($startup) {
        $shortcut = Join-Path $startup 'Skoop Drag Scroll.lnk'
        $shell = New-Object -ComObject WScript.Shell
        $link = $shell.CreateShortcut($shortcut)
        $link.TargetPath = $ahkExe
        $link.Arguments = '"{0}"' -f $scriptPath
        $link.WorkingDirectory = $installDir
        $link.Description = 'Right-button drag to scroll (AutoHotkey)'
        $link.Save()
        Write-Host "==> startup shortcut: $shortcut"
    }
}

# --- 4. Launch ----------------------------------------------------------------
if (-not $NoLaunch) {
    $running = @(Get-CimInstance Win32_Process -Filter "Name='autohotkey.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*mouse-scroll.ahk*" })
    if ($running.Count -eq 0) {
        Start-Process -FilePath $ahkExe -ArgumentList ('"{0}"' -f $scriptPath) -WindowStyle Hidden | Out-Null
        Start-Sleep -Milliseconds 800
        $running = @(Get-CimInstance Win32_Process -Filter "Name='autohotkey.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like "*mouse-scroll.ahk*" })
    }
    if ($running.Count -gt 0) {
        Write-Host "==> running (PID $($running[0].ProcessId)): hold RIGHT mouse button and drag to scroll"
    } else {
        Write-Host '==> could not start the drag-scroll script' -ForegroundColor Yellow
    }
}
