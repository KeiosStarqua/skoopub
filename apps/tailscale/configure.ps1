#Requires -Version 5.1
<#
.SYNOPSIS
    Advertise a tailnet ACL tag on this device (default: tag:public-client).

.DESCRIPTION
    Idempotent and non-fatal. Resolves tailscale.exe from PATH, Program Files
    or Scoop, skips when Tailscale is not connected, and only runs
    `tailscale up --advertise-tags=...` when the tag is not already advertised.
    It never reauthenticates an unconnected node: sign in from the tray icon or
    with `tailscale up` first. Native stderr is merged through cmd.exe because
    Windows PowerShell 5.1 turns it into a terminating NativeCommandError.

    With -RestoreVicinae and/or -RestorePearDesktop, a connected node also restores
    that app from the latest acer-ubuntu snapshot through
    core/restore-backup.ps1 (-Only vicinae / -Only pear). A marker under
    %LOCALAPPDATA%\skoop keeps re-runs from downloading it again; failures are
    non-fatal. -ForceVicinaeRestore / -ForcePearDesktopRestore repeat one app even
    when its marker exists.

.PARAMETER Tag
    ACL tag to advertise. The `tag:` prefix is added when omitted.

.PARAMETER SkipTag
    Leave this device's advertised tags untouched.

.PARAMETER SignIn
    Run `tailscale up --qr` when this node is not signed in, so the login URL
    and QR code are printed in the terminal. Used by the core-terminal phase so
    Tailscale is connected before the slower phases (and Firefox) start.

.PARAMETER RestoreVicinae
    After sign-in (or for an already-connected node), restore Vicinae from the
    shutdown backup once per machine. Needs -BackupUser or SKOOP_BACKUP_USER for
    unattended runs; otherwise restore-backup.ps1 prompts when interactive.

.PARAMETER RestorePearDesktop
    After sign-in (or for an already-connected node), restore Pear Desktop's
    signed-in userData from the shutdown backup once per machine. Cookies are
    DPAPI-encrypted, so a different Windows user/machine may still ask for a
    Google sign-in.

.PARAMETER ForceVicinaeRestore
    Ignore the "already restored" marker and restore Vicinae again.

.PARAMETER ForcePearDesktopRestore
    Ignore the "already restored" marker and restore Pear Desktop again.

.PARAMETER BackupUser
    SSH user on acer-ubuntu for the optional Vicinae restore. Defaults to
    $env:SKOOP_BACKUP_USER.

.EXAMPLE
    .\apps\tailscale\configure.ps1

.EXAMPLE
    .\apps\tailscale\configure.ps1 -SignIn -RestoreVicinae -RestorePearDesktop

.EXAMPLE
    .\apps\tailscale\configure.ps1 -Tag tag:public-client
#>
[CmdletBinding()]
param(
    [string]$Tag = 'tag:public-client',
    [switch]$SkipTag,
    [switch]$SignIn,
    [switch]$RestoreVicinae,
    [switch]$RestorePearDesktop,
    [switch]$ForceVicinaeRestore,
    [switch]$ForcePearDesktopRestore,
    [string]$BackupUser = "$env:SKOOP_BACKUP_USER"
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message)   { Write-Host "    $Message" -ForegroundColor DarkGray }
function Write-Warn([string]$Message) { Write-Host "    $Message" -ForegroundColor Yellow }

function Resolve-TailscaleCli {
    $found = Get-Command tailscale -ErrorAction SilentlyContinue
    if ($found) { return $found.Source }
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Tailscale\tailscale.exe'),
        (Join-Path $env:USERPROFILE 'scoop\shims\tailscale.exe')
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) { return $candidate }
    }
    return $null
}

function Test-TailscaleConnected {
    param([string]$Cli)
    if (-not $Cli) { return $false }
    $raw = (& cmd /c "`"$Cli`" status --json 2>&1" | Out-String)
    $status = try { $raw | ConvertFrom-Json -ErrorAction Stop } catch { $null }
    return [bool]($status -and $status.BackendState -eq 'Running' -and $status.Self.Online)
}

function Invoke-RestoreOnConnect {
    # The shutdown backup uploads Vicinae's config/data and Pear Desktop's
    # signed-in userData, so a reconnected (or freshly installed) machine can put
    # them straight back. One marker per app keeps re-runs idempotent.
    param(
        [ValidateSet('vicinae', 'pear')]
        [string] $App,
        [string] $Label,
        [switch] $ForceRestore,
        [string] $ForceSwitch
    )

    $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $restoreScript = Join-Path $repoRoot 'core\restore-backup.ps1'
    if (-not (Test-Path -LiteralPath $restoreScript)) {
        Write-Warn "core/restore-backup.ps1 not found - skipping $Label auto-restore."
        return
    }
    $marker = Join-Path $env:LOCALAPPDATA "skoop\$App-restore-on-connect.done"
    if ((Test-Path -LiteralPath $marker) -and -not $ForceRestore) {
        Write-Ok "$Label already restored on Tailscale connect - skipping (pass -$ForceSwitch to repeat)"
        return
    }
    if (-not $BackupUser -and -not [Environment]::UserInteractive) {
        Write-Warn "no SSH user for acer-ubuntu - set -BackupUser / SKOOP_BACKUP_USER to auto-restore $Label."
        return
    }
    $restoreArgs = @('-Only', $App)
    if ($BackupUser) { $restoreArgs += @('-User', $BackupUser) }
    Write-Step "Restoring $Label from the latest backup after Tailscale connect"
    try {
        & $restoreScript @restoreArgs
        $markerDir = Split-Path -Parent $marker
        if (-not (Test-Path -LiteralPath $markerDir)) { New-Item -ItemType Directory -Force -Path $markerDir | Out-Null }
        [System.IO.File]::WriteAllText($marker, (Get-Date -Format 'o'))
        Write-Ok "$Label restored; marker written to $marker"
    } catch {
        Write-Warn "$Label auto-restore failed (non-fatal): $($_.Exception.Message)"
    }
}

$cli = Resolve-TailscaleCli

if ($SignIn) {
    # Connect before the slow phases so `tailscale up --qr` can show its login
    # URL/QR in the terminal. Already-connected nodes are left alone.
    if (-not $cli) {
        Write-Warn 'tailscale.exe not found - skipping Tailscale sign-in.'
    } elseif (Test-TailscaleConnected $cli) {
        Write-Ok 'Tailscale is already signed in'
    } elseif (-not [Environment]::UserInteractive) {
        Write-Warn 'Tailscale sign-in needs a terminal - run `tailscale up --qr` yourself.'
    } else {
        Write-Step 'Signing in to Tailscale (scan the QR code or open the URL below)'
        # Stream the output: --qr draws the login QR code and the URL stays
        # clickable. cmd merges stderr so 5.1 does not raise NativeCommandError.
        & cmd /c "`"$cli`" up --qr 2>&1"
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "Tailscale sign-in did not finish (exit $LASTEXITCODE) - run ``tailscale up --qr`` later."
        } else {
            Write-Ok 'Tailscale sign-in complete'
        }
    }
}

# Probe again rather than trusting the sign-in exit code: the QR flow can exit
# 0 without a working connection, and already-connected nodes skip it entirely.
$connected = Test-TailscaleConnected $cli
if ($RestoreVicinae -and $connected) {
    Invoke-RestoreOnConnect -App vicinae -Label 'Vicinae' -ForceRestore:$ForceVicinaeRestore -ForceSwitch 'ForceVicinaeRestore'
}
if ($RestorePearDesktop -and $connected) {
    Invoke-RestoreOnConnect -App pear -Label 'Pear Desktop' -ForceRestore:$ForcePearDesktopRestore -ForceSwitch 'ForcePearDesktopRestore'
}

if ($SkipTag) { Write-Ok 'Tailnet tagging skipped (-SkipTag).'; return }
if ($Tag -notlike 'tag:*') { $Tag = "tag:$Tag" }

if (-not $cli) { Write-Warn 'tailscale.exe not found - skipping tailnet tagging.'; return }

Write-Step "Tagging this device with $Tag in the tailnet"
if (-not (Test-TailscaleConnected $cli)) {
    Write-Warn 'Tailscale is not connected - sign in from the tray icon or run `tailscale up`, then re-run.'
    return
}

$prefsRaw = (& cmd /c "`"$cli`" debug prefs 2>&1" | Out-String)
$prefs = try { $prefsRaw | ConvertFrom-Json -ErrorAction Stop } catch { $null }
$advertised = if ($prefs) { @($prefs.AdvertiseTags) } else { @() }
if ($advertised -contains $Tag) {
    Write-Ok "$Tag is already advertised on this device"
    return
}

$out = (& cmd /c "`"$cli`" up --advertise-tags=$Tag 2>&1" | Out-String)
if ($LASTEXITCODE -ne 0) {
    Write-Warn "Could not advertise $Tag (non-fatal, exit $LASTEXITCODE): $(($out -split "`r?`n" | Select-Object -First 2) -join ' ')"
    Write-Warn 'Check that your tailnet ACL lists you as a tag owner for this tag.'
    return
}
Write-Ok "advertised $Tag on this device"
