# configure-alacritty.ps1
# Copy the repo-managed Alacritty config into %APPDATA%\alacritty.
# A changed original gets a timestamped .bak copy unless -NoBackup is passed.
#
#   powershell -ExecutionPolicy Bypass -File .\configure-alacritty.ps1
#   powershell -ExecutionPolicy Bypass -File .\configure-alacritty.ps1 -NoBackup
[CmdletBinding()]
param(
    [string]$SourceFile = '',
    [string]$ConfigDir = '',
    # Overwrite a changed config directly instead of keeping a timestamped .bak.
    [switch]$NoBackup
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is empty while param defaults are evaluated under PowerShell 5.1.
if (-not $SourceFile) { $SourceFile = Join-Path $PSScriptRoot 'alacritty\alacritty.toml' }

if (-not $ConfigDir) {
    if ($env:APPDATA) { $ConfigDir = Join-Path $env:APPDATA 'alacritty' }
    else { $ConfigDir = Join-Path $env:USERPROFILE 'AppData\Roaming\alacritty' }
}

if (-not (Test-Path -LiteralPath $SourceFile)) {
    Write-Host "Alacritty config source not found: $SourceFile" -ForegroundColor Yellow
    return
}

New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
$destination = Join-Path $ConfigDir 'alacritty.toml'

$normalize = {
    param([string]$Text)
    return ($Text -replace "`r`n", "`n").TrimEnd()
}

if (Test-Path -LiteralPath $destination) {
    $existing = & $normalize (Get-Content -Raw -LiteralPath $destination)
    $desired  = & $normalize (Get-Content -Raw -LiteralPath $SourceFile)
    if ($existing -eq $desired) {
        Write-Host "Alacritty config already up to date: $destination" -ForegroundColor DarkGray
        return
    }

    if (-not $NoBackup) {
        $backup = '{0}.bak.{1}' -f $destination, (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item -LiteralPath $destination -Destination $backup -Force
        Write-Host "Backed up $destination -> $backup"
    }
}

Copy-Item -LiteralPath $SourceFile -Destination $destination -Force
Write-Host "Installed $destination" -ForegroundColor Green
if (Get-Process -Name alacritty -ErrorAction SilentlyContinue) {
    Write-Host 'Alacritty is running - restart it to load the new font settings.' -ForegroundColor Yellow
}
