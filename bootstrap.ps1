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

# 2. Install WezTerm first.
$extrasBucket = scoop bucket list 2>$null | Select-String -Pattern '^\s*extras\b' -Quiet
if (-not $extrasBucket) { scoop bucket add extras }
$weztermInstalled = scoop list 2>$null | Select-String -Pattern '^\s*wezterm\b' -Quiet
if (-not $weztermInstalled) { scoop install wezterm } else { Write-Host 'WezTerm already installed.' }

# 3. Restore buckets + apps declared in scoop.json.
$manifest = Join-Path $repo 'scoop.json'
if (-not $ForceUniKey -and (Test-UniKeyInstalled)) {
    Write-Host 'UniKey already installed - keeping the existing copy (-ForceUniKey overrides).'
    $json = Get-Content -Raw $manifest | ConvertFrom-Json
    $json.apps = @($json.apps | Where-Object { $_.Name -ne 'unikey' })
    $manifest = Join-Path $env:TEMP 'skoop-scoop-no-unikey.json'
    $json | ConvertTo-Json -Depth 10 | Set-Content -Path $manifest -Encoding UTF8
}
scoop import $manifest

# 4. Default the Rust toolchain to GNU when none is configured yet.
$scoopRoot = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $env:USERPROFILE 'scoop' }
$cargoBin = Join-Path $scoopRoot 'persist\rustup\.cargo\bin'
if (Test-Path $cargoBin) { $env:Path = "$cargoBin;$env:Path" }
if (Get-Command rustup -ErrorAction SilentlyContinue) {
    $null = rustup show active-toolchain 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'Setting GNU toolchain as the default Rust toolchain.'
        rustup default stable-x86_64-pc-windows-gnu
    } else {
        Write-Host 'Rust toolchain already set; keeping it.'
    }
}

# 5. Let ShareX own PrtSc: Windows otherwise hands the key to the Snipping Tool.
$sharexFix = Join-Path $repo 'fix-sharex-printscreen.ps1'
if (Test-Path $sharexFix) { & $sharexFix }

# 6. Make PowerShell load the repo-managed shell config on startup.
#    Any earlier hook is rewritten: a stale path (e.g. ~\skoop\profile.ps1 from an
#    old layout) would point at a missing file and silently load nothing.
$loader = Join-Path $repo 'profile.ps1'
$hook = "# Load the repo-managed shell config. Edit that file, not this one.`n. `"$loader`""

New-Item -ItemType Directory -Force -Path (Split-Path $PROFILE) | Out-Null
$lines = if (Test-Path $PROFILE) { @(Get-Content -Path $PROFILE) } else { @() }
$stale   = 'skoop[\\/]profile\.ps1|\$skoopProfile|^# Load the repo-managed shell config|' + [regex]::Escape($loader)
$body    = (($lines | Where-Object { $_ -notmatch $stale }) -join "`r`n").TrimEnd()
$desired = if ($body) { "$body`r`n$hook" } else { $hook }

$existing = if (Test-Path $PROFILE) { Get-Content -Raw -Path $PROFILE } else { '' }
if ($existing.TrimEnd() -ne $desired) {
    Set-Content -Path $PROFILE -Value $desired -Encoding UTF8
    Write-Host "Wired profile.ps1 into $PROFILE"
}

Write-Host "Done. Open a new PowerShell window, then try: z .." -ForegroundColor Green
