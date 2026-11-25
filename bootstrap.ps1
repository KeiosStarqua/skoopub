# bootstrap.ps1 - restore this Scoop + shell setup on a Windows machine.
# Usage:  powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1
# Use -ForceUniKey to replace an already installed UniKey with the Scoop build.
[CmdletBinding()]
param(
    [switch]$ForceUniKey
)

$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot

function Test-UniKeyInstalled {
    # Public PCs often ship a manually installed UniKey; installing the Scoop
    # copy as well would leave two IMEs fighting over the same hotkeys.
    if (Get-Process -Name UniKeyNT -ErrorAction SilentlyContinue) { return $true }
    $uninstallKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($key in $uninstallKeys) {
        if (Get-ItemProperty -Path $key -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match 'UniKey' }) { return $true }
    }
    $scoopRoots = @($env:SCOOP, (Join-Path $env:USERPROFILE 'scoop'), (Join-Path $env:ProgramData 'scoop'))
    foreach ($root in $scoopRoots) {
        if ($root -and (Test-Path (Join-Path $root 'apps\unikey\current'))) { return $true }
    }
    return $false
}

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
$manifest = Join-Path $repo 'scoop.json'
if (-not $ForceUniKey -and (Test-UniKeyInstalled)) {
    Write-Host 'UniKey already installed - keeping the existing copy (-ForceUniKey overrides).'
    $json = Get-Content -Raw $manifest | ConvertFrom-Json
    $json.apps = @($json.apps | Where-Object { $_.Name -ne 'unikey' })
    $manifest = Join-Path $env:TEMP 'skoop-scoop-no-unikey.json'
    $json | ConvertTo-Json -Depth 10 | Set-Content -Path $manifest -Encoding UTF8
}
scoop import $manifest

# 3. Let ShareX own PrtSc: Windows otherwise hands the key to the Snipping Tool.
$sharexFix = Join-Path $repo 'fix-sharex-printscreen.ps1'
if (Test-Path $sharexFix) { & $sharexFix }

# 4. Make PowerShell load the repo-managed shell config on startup.
$loader = Join-Path $repo 'profile.ps1'
$hook = "# Load the repo-managed shell config. Edit that file, not this one.`n. `"$loader`""
$already = (Test-Path $PROFILE) -and (
    (Select-String -Path $PROFILE -SimpleMatch $loader -Quiet) -or
    (Select-String -Path $PROFILE -Pattern 'skoop\\profile\.ps1' -Quiet)
)
if (-not $already) {
    New-Item -ItemType Directory -Force -Path (Split-Path $PROFILE) | Out-Null
    Add-Content -Path $PROFILE -Value "`n$hook" -Encoding UTF8
}

Write-Host "Done. Open a new PowerShell window, then try: z .." -ForegroundColor Green
