#Requires -Version 5.1
<#
.SYNOPSIS
    One-shot Windows bootstrap: install Scoop, restore packages, wire up the shell config.

.DESCRIPTION
    - Installs Scoop if it is missing (per-user, or system-wide when run elevated).
    - Makes sure git is available, then runs `scoop import scoop.json` (buckets + apps).
    - Keeps a UniKey that is already installed (e.g. on a public PC) instead of
      adding a second copy; -ForceUniKey installs the Scoop build anyway.
    - Applies fix-sharex-printscreen.ps1 so ShareX owns the PrtSc key.
    - Applies show-taskbar-clock.ps1 so the clock is always on the taskbar.
    - Adds a dot-source line for profile.ps1 to your PowerShell $PROFILE.

    Works two ways:
      Local :  .\install.ps1
      Remote:  irm https://raw.githubusercontent.com/KeiosStarqua/skoopub/main/install.ps1 | iex

.PARAMETER RepoRawBase
    Raw URL base used to fetch scoop.json / profile.ps1 when the script is piped in
    and there is no local checkout. Override this if you use a fork.

.PARAMETER ForceUniKey
    Install the Scoop UniKey package even if another UniKey is already installed.

.EXAMPLE
    irm https://raw.githubusercontent.com/KeiosStarqua/skoopub/main/install.ps1 | iex

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
#>
[CmdletBinding()]
param(
    [string]$RepoRawBase = 'https://raw.githubusercontent.com/KeiosStarqua/skoopub/main',
    [switch]$ForceUniKey
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message)   { Write-Host "    $Message" -ForegroundColor DarkGray }

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

function Find-ScoopShims {
    @(
        (Join-Path $env:USERPROFILE 'scoop\shims'),
        (Join-Path $env:ProgramData 'scoop\shims')
    ) | Where-Object { Test-Path (Join-Path $_ 'scoop.cmd') } | Select-Object -First 1
}

# --- 1. Locate the repo files ------------------------------------------------
$repoRoot = $null
foreach ($candidate in @($PSScriptRoot, (Get-Location).Path)) {
    if ($candidate -and (Test-Path (Join-Path $candidate 'scoop.json'))) {
        $repoRoot = $candidate
        break
    }
}

if (-not $repoRoot) {
    Write-Step 'No local checkout found - downloading repo files'
    $repoRoot = Join-Path $env:LOCALAPPDATA 'skoop'
    New-Item -ItemType Directory -Force -Path $repoRoot | Out-Null
    foreach ($file in 'scoop.json', 'profile.ps1', 'fix-sharex-printscreen.ps1', 'sharex-hotkeys.template.json', 'show-taskbar-clock.ps1') {
        $dest = Join-Path $repoRoot $file
        Invoke-WebRequest -UseBasicParsing -Uri "$RepoRawBase/$file" -OutFile $dest
        Unblock-File $dest
        Write-Ok "fetched $file"
    }
}

$manifest      = Join-Path $repoRoot 'scoop.json'
$profileScript = Join-Path $repoRoot 'profile.ps1'
$sharexFix     = Join-Path $repoRoot 'fix-sharex-printscreen.ps1'
Write-Ok "repo root: $repoRoot"

# --- 2. Install Scoop if its shims are missing -------------------------------
$shimDir = Find-ScoopShims
if (-not $shimDir) {
    Write-Step 'Installing Scoop'
    $installer = Join-Path $env:TEMP 'install-scoop.ps1'
    Invoke-WebRequest -UseBasicParsing 'https://get.scoop.sh' -OutFile $installer
    Unblock-File $installer

    $elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($elevated) {
        Write-Ok 'elevated shell detected - installing Scoop system-wide (C:\ProgramData\scoop)'
    }

    & $installer -RunAsAdmin:$elevated
    $shimDir = Find-ScoopShims
} else {
    Write-Ok "Scoop already installed ($shimDir)"
}

if (-not $shimDir) { throw 'Scoop installed but its shims directory was not found.' }

# --- 3. Put the shims on PATH for this process -------------------------------
$env:SCOOP = Split-Path $shimDir -Parent
$env:Path  = "$shimDir;$env:Path"
$scoop     = Join-Path $shimDir 'scoop.cmd'
Write-Ok "shims: $shimDir"

# --- 4. Buckets are git repos, so git must exist before scoop import ---------
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Step 'Installing git (required for Scoop buckets)'
    & $scoop install git
}

# --- 5. Restore buckets + apps ----------------------------------------------
$manifestToImport = $manifest
if (-not $ForceUniKey -and (Test-UniKeyInstalled)) {
    Write-Step 'UniKey already installed - keeping the existing copy'
    $json = Get-Content -Raw $manifest | ConvertFrom-Json
    $json.apps = @($json.apps | Where-Object { $_.Name -ne 'unikey' })
    $manifestToImport = Join-Path $env:TEMP 'skoop-scoop-no-unikey.json'
    $json | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestToImport -Encoding UTF8
    Write-Ok "importing without unikey ($manifestToImport)"
}

Write-Step "Importing $manifestToImport"
& $scoop import $manifestToImport
if ($LASTEXITCODE -ne 0) { throw "scoop import failed with exit code $LASTEXITCODE." }

# --- 6. Default Rust toolchain: GNU (no Visual Studio Build Tools needed) ----
$cargoBin = Join-Path $env:SCOOP 'persist\rustup\.cargo\bin'
if (Test-Path $cargoBin) { $env:Path = "$cargoBin;$env:Path" }
if (Get-Command rustup -ErrorAction SilentlyContinue) {
    $null = rustup show active-toolchain 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Step 'Setting GNU toolchain as the default Rust toolchain'
        rustup default stable-x86_64-pc-windows-gnu
    } else {
        Write-Ok "Rust toolchain already set; keeping it"
    }
}

# --- 7. Let ShareX own the PrtSc key -----------------------------------------
if (Test-Path $sharexFix) {
    Write-Step 'Applying ShareX PrtSc fix'
    & $sharexFix
} else {
    Write-Ok 'fix-sharex-printscreen.ps1 not found - skipping'
}

# --- 8. Make sure the taskbar clock is visible -------------------------------
$clockFix = Join-Path $repoRoot 'show-taskbar-clock.ps1'
if (Test-Path $clockFix) {
    Write-Step 'Showing the taskbar clock'
    & $clockFix
} else {
    Write-Ok 'show-taskbar-clock.ps1 not found - skipping'
}

# --- 9. Hook the repo-managed profile into $PROFILE --------------------------
Write-Step 'Wiring profile.ps1 into your PowerShell profile'
$hook = "# Load the repo-managed shell config. Edit that file, not this one.`n. `"$profileScript`""

New-Item -ItemType Directory -Force -Path (Split-Path $PROFILE) | Out-Null
$lines = if (Test-Path $PROFILE) { @(Get-Content -Path $PROFILE) } else { @() }

# Rewrite any earlier hook instead of trusting it: a stale one can point at a
# profile.ps1 that no longer exists (e.g. ~\skoop\profile.ps1) and then silently
# load nothing, which looks like the packages are missing.
$stale   = 'skoop[\\/]profile\.ps1|\$skoopProfile|^# Load the repo-managed shell config'
$body    = (($lines | Where-Object { $_ -notmatch $stale }) -join "`r`n").TrimEnd()
$desired = if ($body) { "$body`r`n$hook" } else { $hook }

$existing = if (Test-Path $PROFILE) { Get-Content -Raw -Path $PROFILE } else { '' }
if ($existing.TrimEnd() -eq $desired) {
    Write-Ok "already present in $PROFILE"
} else {
    Set-Content -Path $PROFILE -Value $desired -Encoding UTF8
    Write-Ok "wired into $PROFILE"
}

Write-Host ''
Write-Host 'Done. Open a new PowerShell window, then try: z ..' -ForegroundColor Green
