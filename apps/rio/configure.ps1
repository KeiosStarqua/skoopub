# apps/rio/configure.ps1
# Copy the repo-managed Rio config into the current user's Rio config folder.
# Rio reads %LOCALAPPDATA%\rio\config.toml and hot-reloads it on change, so no
# restart is needed. The config sets the font size (Rio's zoom) to 16.
#
#   powershell -ExecutionPolicy Bypass -File .\apps/rio/configure.ps1
#   powershell -ExecutionPolicy Bypass -File .\apps/rio/configure.ps1 -NoBackup
[CmdletBinding()]
param(
    [string]$SourceFile = '',
    [string]$ConfigDir = '',
    # Overwrite a changed config directly instead of keeping a timestamped .bak.
    [switch]$NoBackup
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is not populated during parameter binding in PowerShell 5.1.
if (-not $SourceFile) { $SourceFile = Join-Path $PSScriptRoot 'config.toml' }
if (-not $ConfigDir) {
    if ($env:LOCALAPPDATA) { $ConfigDir = Join-Path $env:LOCALAPPDATA 'rio' }
    else { $ConfigDir = Join-Path $env:USERPROFILE 'AppData\Local\rio' }
}

if (-not (Test-Path -LiteralPath $SourceFile)) {
    throw "Rio config source not found: $SourceFile"
}

$destination = Join-Path $ConfigDir 'config.toml'
$normalize = {
    param([string]$Text)
    return ($Text -replace "`r`n", "`n").TrimEnd()
}
$desired = & $normalize (Get-Content -Raw -LiteralPath $SourceFile)

New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null

if (Test-Path -LiteralPath $destination) {
    $existing = & $normalize (Get-Content -Raw -LiteralPath $destination)
    if ($existing -eq $desired) {
        Write-Host "Rio config already up to date: $destination" -ForegroundColor DarkGray
        return
    }

    if (-not $NoBackup) {
        $backup = '{0}.bak.{1}' -f $destination, (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item -LiteralPath $destination -Destination $backup -Force
        Write-Host "Backed up $destination -> $backup"
    }
}

Copy-Item -LiteralPath $SourceFile -Destination $destination -Force
Write-Host "Installed $destination (font size / zoom 16)" -ForegroundColor Green

if (Get-Process -Name rio -ErrorAction SilentlyContinue) {
    Write-Host 'Rio is running; it hot-reloads config.toml, so new windows use zoom 16.' -ForegroundColor DarkGray
}
