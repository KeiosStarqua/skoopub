# apps/yasb/configure.ps1
# Deploy a repo-managed YASB theme (config.yaml + styles.css) into ~/.config/yasb,
# create a .env from the template when missing, and start YASB. Adaptive Islands
# is the default; the previous Komorebi bar theme is preserved under
# themes/komorebi/ and can be restored with -Theme komorebi. It also clones the
# community aesthetic-wallpapers collection once and sets YASB_WALLPAPER_DIR.
# The config watches for changes, so a restart is only needed with -Restart.
#
#   powershell -ExecutionPolicy Bypass -File .\apps/yasb/configure.ps1
#   powershell -ExecutionPolicy Bypass -File .\apps/yasb/configure.ps1 -Theme komorebi
#   powershell -ExecutionPolicy Bypass -File .\apps/yasb/configure.ps1 -Restart
[CmdletBinding()]
param(
    # Resolved in the body: $PSScriptRoot is empty during param binding in PS 5.1.
    [string]$SourceDir = '',
    [string]$ConfigDir = '',
    # Which repo-managed theme to deploy (default: Adaptive Islands).
    [ValidateSet('adaptive-islands', 'komorebi')]
    [string]$Theme = 'adaptive-islands',
    # Overwrite changed files directly instead of keeping a timestamped .bak.
    [switch]$NoBackup,
    # Stop and relaunch YASB so the config is reloaded immediately.
    [switch]$Restart,
    # Skip the one-time aesthetic-wallpapers clone (also SKOOP_NO_WALLPAPERS=1).
    [switch]$NoWallpapers
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

$themeDir = if ($Theme -eq 'komorebi') { Join-Path $SourceDir 'themes\komorebi' } else { $SourceDir }
if (-not (Test-Path -LiteralPath $themeDir)) {
    Write-Host "YASB theme '$Theme' not found at $themeDir" -ForegroundColor Yellow
    return
}
Write-Host "Deploying YASB theme: $Theme"

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
    $source = Join-Path $themeDir $file
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

# The Adaptive Islands wallpapers widget reads YASB_WALLPAPER_DIR. Clone the
# community collection once and point the env var at its images folder. This is
# deliberately non-fatal so an offline bootstrap still gets a working bar.
$wallpapersScript = Join-Path $SourceDir 'setup-wallpapers.ps1'
if ($NoWallpapers -or $env:SKOOP_NO_WALLPAPERS -eq '1') {
    Write-Host 'Skipping wallpaper setup (-NoWallpapers).' -ForegroundColor DarkGray
} elseif (Test-Path -LiteralPath $wallpapersScript) {
    try {
        & $wallpapersScript -EnvFile $envFile
    } catch {
        Write-Host "    Wallpaper setup failed (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
    }
} else {
    Write-Host 'setup-wallpapers.ps1 not found - YASB_WALLPAPER_DIR left unchanged.' -ForegroundColor Yellow
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
    Write-Host "YASB is running with the '$Theme' theme ($ConfigDir)." -ForegroundColor Green
} else {
    Write-Host 'YASB did not stay running; check `yasbc log`.' -ForegroundColor Yellow
}
