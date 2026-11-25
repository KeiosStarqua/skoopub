# bootstrap.ps1 - restore this Scoop + shell setup on a Windows machine.
# Usage:  powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1
$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot

# 1. Install Scoop if it is missing (no admin needed unless already elevated).
if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
    $installer = Join-Path $env:TEMP 'install-scoop.ps1'
    Invoke-WebRequest -UseBasicParsing 'https://get.scoop.sh' -OutFile $installer
    Unblock-File $installer
    $elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    & $installer -RunAsAdmin:$elevated
}
$env:Path = "$env:USERPROFILE\scoop\shims;$env:Path"

# 2. Restore buckets + apps declared in scoop.json.
scoop import (Join-Path $repo 'scoop.json')

# 3. Make PowerShell load the repo-managed shell config on startup.
$loader = Join-Path $repo 'profile.ps1'
$hook = "# Load the repo-managed shell config. Edit that file, not this one.`n. `"$loader`""
$already = (Test-Path $PROFILE) -and (Select-String -Path $PROFILE -SimpleMatch $loader -Quiet)
if (-not $already) {
    New-Item -ItemType Directory -Force -Path (Split-Path $PROFILE) | Out-Null
    Add-Content -Path $PROFILE -Value "`n$hook" -Encoding UTF8
}

Write-Host "Done. Open a new PowerShell window, then try: z .." -ForegroundColor Green
