# apps/yasb/configure.ps1
# Deploy the repo-managed YASB bar config (config.yaml + styles.css) into
# ~/.config/yasb, create a .env from the template when missing, and start YASB.
# The config watches for changes, so a restart is only needed with -Restart.
#
#   powershell -ExecutionPolicy Bypass -File .\apps/yasb/configure.ps1
#   powershell -ExecutionPolicy Bypass -File .\apps/yasb/configure.ps1 -Restart
[CmdletBinding()]
param(
    # Resolved in the body: $PSScriptRoot is empty during param binding in PS 5.1.
    [string]$SourceDir = '',
    [string]$ConfigDir = '',
    # Overwrite changed files directly instead of keeping a timestamped .bak.
    [switch]$NoBackup,
    # Stop and relaunch YASB so the config is reloaded immediately.
    [switch]$Restart
)

$ErrorActionPreference = 'Stop'

if (-not $SourceDir) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    if (-not $scriptDir) { $scriptDir = $PSScriptRoot }
    $SourceDir = $scriptDir
}

if (-not $ConfigDir) {
    if ($env:USERPROFILE) { $ConfigDir = Join-Path $env:USERPROFILE '.config\yasb' }
    else { $ConfigDir = Join-Path $env:APPDATA 'yasb' }
}

if (-not (Test-Path -LiteralPath $SourceDir)) {
    Write-Host "YASB config source not found: $SourceDir" -ForegroundColor Yellow
    return
}

New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null

function Copy-YasbFile {
    param([string]$Source, [string]$Destination)

    $normalize = {
        param([string]$Text)
        return ($Text -replace "`r`n", "`n").TrimEnd()
    }

    if (Test-Path -LiteralPath $Destination) {
        $existing = & $normalize (Get-Content -Raw -LiteralPath $Destination)
        $desired  = & $normalize (Get-Content -Raw -LiteralPath $Source)
        if ($existing -eq $desired) { return }

        if (-not $NoBackup) {
            $backup = '{0}.bak.{1}' -f $Destination, (Get-Date -Format 'yyyyMMdd-HHmmss')
            Copy-Item -LiteralPath $Destination -Destination $backup -Force
            Write-Host "Backed up $Destination -> $backup"
        }
    }

    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    Write-Host "Installed $Destination"
}

foreach ($file in @('config.yaml', 'styles.css')) {
    $source = Join-Path $SourceDir $file
    if (Test-Path -LiteralPath $source) {
        Copy-YasbFile -Source $source -Destination (Join-Path $ConfigDir $file)
    }
}

# YASB reads secrets from .env in the same directory. Never overwrite a real one.
$example = Join-Path $SourceDir '.env.example'
$envFile = Join-Path $ConfigDir '.env'
if ((Test-Path -LiteralPath $example) -and -not (Test-Path -LiteralPath $envFile)) {
    Copy-Item -LiteralPath $example -Destination $envFile
    Write-Host "Created $envFile from the template - fill in any values you need."
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

$yasbc = Resolve-Tool 'yasbc'
if (-not $yasbc) {
    Write-Host 'yasbc not found; YASB config deployed but not started.' -ForegroundColor Yellow
    return
}

$running = [bool](Get-Process -Name yasb -ErrorAction SilentlyContinue)
if ($running -and $Restart) {
    Write-Host 'Restarting YASB...'
    & $yasbc stop 2>&1 | ForEach-Object { Write-Host "    $_" }
    Start-Sleep -Milliseconds 700
    $running = $false
}

if (-not $running) {
    Write-Host 'Starting YASB...'
    & $yasbc start 2>&1 | ForEach-Object { Write-Host "    $_" }
    Start-Sleep -Seconds 2
}

if (Get-Process -Name yasb -ErrorAction SilentlyContinue) {
    Write-Host "YASB is running with the Komorebi bar ($ConfigDir)." -ForegroundColor Green
} else {
    Write-Host 'YASB did not stay running; check `yasbc log`.' -ForegroundColor Yellow
}
