# configure-komorebi.ps1
# Deploy the repo-managed whkdrc to ~/.config/whkdrc, then start (or reload)
# whkd so the hotkeys are active. Starts Komorebi too when it is not running.
#
#   powershell -ExecutionPolicy Bypass -File .\configure-komorebi.ps1
#   powershell -ExecutionPolicy Bypass -File .\configure-komorebi.ps1 -Restart
#   powershell -ExecutionPolicy Bypass -File .\configure-komorebi.ps1 -NoStart
[CmdletBinding()]
param(
    # Resolved in the body: $PSScriptRoot is empty during param binding in PS 5.1.
    [string]$SourceDir = '',
    [string]$ConfigDir = '',
    # Overwrite a changed whkdrc directly instead of keeping a timestamped .bak.
    [switch]$NoBackup,
    # Deploy files only; do not start or restart komorebi/whkd.
    [switch]$NoStart,
    # Restart whkd even when its config has not changed.
    [switch]$Restart
)

$ErrorActionPreference = 'Stop'

if (-not $SourceDir) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    if (-not $scriptDir) { $scriptDir = $PSScriptRoot }
    $SourceDir = Join-Path $scriptDir 'komorebi'
}

if (-not $ConfigDir) {
    if ($env:USERPROFILE) { $ConfigDir = Join-Path $env:USERPROFILE '.config' }
    else { $ConfigDir = Join-Path $env:APPDATA 'Komorebi' }
}

$source = Join-Path $SourceDir 'whkdrc'
if (-not (Test-Path -LiteralPath $source)) {
    Write-Host "whkdrc not found at $source - skipping" -ForegroundColor Yellow
    return
}

New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
$destination = Join-Path $ConfigDir 'whkdrc'

function Read-Normalized {
    param([string]$Path)
    return ((Get-Content -Raw -LiteralPath $Path) -replace "`r`n", "`n").TrimEnd()
}

$changed = $true
if (Test-Path -LiteralPath $destination) {
    $changed = (Read-Normalized $destination) -ne (Read-Normalized $source)
    if (-not $changed) {
        Write-Host "whkdrc already up to date: $destination"
    } else {
        if (-not $NoBackup) {
            $backup = '{0}.bak.{1}' -f $destination, (Get-Date -Format 'yyyyMMdd-HHmmss')
            Copy-Item -LiteralPath $destination -Destination $backup -Force
            Write-Host "Backed up $destination -> $backup"
        }
    }
} else {
    Write-Host "Installing $destination (first run)"
}

if ($changed) {
    Copy-Item -LiteralPath $source -Destination $destination -Force
}

function Resolve-Tool {
    param([string]$Name)
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    foreach ($root in @($env:SCOOP, (Join-Path $env:USERPROFILE 'scoop'))) {
        if (-not $root) { continue }
        $shim = Join-Path $root "shims\$Name.exe"
        if (Test-Path -LiteralPath $shim) { return $shim }
    }
    return $null
}

if ($NoStart) {
    Write-Host 'Skipping process start/reload (-NoStart).' -ForegroundColor DarkGray
    return
}

$komorebic = Resolve-Tool 'komorebic'
$whkd = Resolve-Tool 'whkd'

if (-not (Get-Process -Name komorebi -ErrorAction SilentlyContinue)) {
    if ($komorebic) {
        Write-Host 'Starting Komorebi...'
        & $komorebic start 2>&1 | ForEach-Object { Write-Host "    $_" }
    } else {
        Write-Host 'komorebic not found; cannot start Komorebi.' -ForegroundColor Yellow
    }
} else {
    Write-Host 'Komorebi is already running.'
}

$whkdRunning = [bool](Get-Process -Name whkd -ErrorAction SilentlyContinue)
if ($whkdRunning -and ($changed -or $Restart)) {
    Write-Host 'Restarting whkd to load the new hotkeys...'
    Stop-Process -Name whkd -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    $whkdRunning = $false
}

if (-not $whkdRunning -and $whkd) {
    Write-Host 'Starting whkd...'
    Start-Process -FilePath $whkd -WindowStyle Hidden
    Start-Sleep -Seconds 1
}

if (-not (Get-Process -Name whkd -ErrorAction SilentlyContinue)) {
    Write-Host 'whkd did not stay running - check ~/.config/whkdrc for syntax errors.' -ForegroundColor Yellow
} else {
    Write-Host "Komorebi hotkeys are active (whkdrc: $destination)." -ForegroundColor Green
}
