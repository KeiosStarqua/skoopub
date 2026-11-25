#Requires -Version 5.1
<#
.SYNOPSIS
    One-shot Windows bootstrap: install Scoop, restore packages, wire up the shell config.

.DESCRIPTION
    - Installs Scoop if it is missing (per-user, or system-wide when run elevated).
    - Makes sure git is available, then runs `scoop import scoop.json` (buckets + apps).
    - Adds a dot-source line for profile.ps1 to your PowerShell $PROFILE.

    Works two ways:
      Local :  .\install.ps1
      Remote:  irm https://raw.githubusercontent.com/KeiosStarqua/skoopub/main/install.ps1 | iex

.PARAMETER RepoRawBase
    Raw URL base used to fetch scoop.json / profile.ps1 when the script is piped in
    and there is no local checkout. Override this if you use a fork.

.EXAMPLE
    irm https://raw.githubusercontent.com/KeiosStarqua/skoopub/main/install.ps1 | iex

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
#>
[CmdletBinding()]
param(
    [string]$RepoRawBase = 'https://raw.githubusercontent.com/KeiosStarqua/skoopub/main'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message)   { Write-Host "    $Message" -ForegroundColor DarkGray }

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
    foreach ($file in 'scoop.json', 'profile.ps1') {
        $dest = Join-Path $repoRoot $file
        Invoke-WebRequest -UseBasicParsing -Uri "$RepoRawBase/$file" -OutFile $dest
        Unblock-File $dest
        Write-Ok "fetched $file"
    }
}

$manifest      = Join-Path $repoRoot 'scoop.json'
$profileScript = Join-Path $repoRoot 'profile.ps1'
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
Write-Step "Importing $manifest"
& $scoop import $manifest
if ($LASTEXITCODE -ne 0) { throw "scoop import failed with exit code $LASTEXITCODE." }

# --- 6. Hook the repo-managed profile into $PROFILE --------------------------
Write-Step 'Wiring profile.ps1 into your PowerShell profile'
$hook    = "# Load the repo-managed shell config. Edit that file, not this one.`n. `"$profileScript`""
$already = (Test-Path $PROFILE) -and (Select-String -Path $PROFILE -SimpleMatch $profileScript -Quiet)
if ($already) {
    Write-Ok "already present in $PROFILE"
} else {
    New-Item -ItemType Directory -Force -Path (Split-Path $PROFILE) | Out-Null
    Add-Content -Path $PROFILE -Value "`n$hook" -Encoding UTF8
    Write-Ok "added to $PROFILE"
}

Write-Host ''
Write-Host 'Done. Open a new PowerShell window, then try: z ..' -ForegroundColor Green
