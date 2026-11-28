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

    With -RestoreVicinae, -RestorePearDesktop, -RestoreFirefox, -RestoreAtuin
    and/or -RestoreOpenCode, a connected node also restores that app from the
    latest acer-ubuntu snapshot through core/restore-backup.ps1 (-Only vicinae /
    pear / firefox / atuin / opencode). A marker under %LOCALAPPDATA%\skoop keeps
    re-runs from downloading it again; failures are non-fatal. -ForceVicinaeRestore
    / -ForcePearDesktopRestore / -ForceFirefoxRestore / -ForceAtuinRestore /
    -ForceOpenCodeRestore repeat one app even when its marker exists. These run
    right after the Tailscale connect probe, so Firefox, Atuin and OpenCode may be
    restored before their apps are installed (all three are file copies; OpenCode's
    credential import still happens later, once its CLI exists). Firefox is closed
    politely (and relaunched afterwards only if it was running) because its profile
    files are locked while it runs; Atuin needs no process stop, but other shells
    with an active session should be closed.

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

.PARAMETER RestoreFirefox
    After sign-in (or for an already-connected node), restore the Firefox profile
    from the shutdown backup once per machine. Firefox is closed before the copy
    (politely, then forced if needed) and relaunched afterwards only when it was
    running; if it cannot be closed, the restore is skipped with a warning rather
    than copying locked files. Firefox need not be installed yet - the profile is
    simply put in place for when it is. Needs -BackupUser or SKOOP_BACKUP_USER for
    unattended runs.

.PARAMETER RestoreAtuin
    After sign-in (or for an already-connected node), restore Atuin config and
    history from the shutdown backup once per machine. Atuin need not be installed
    yet. The restore removes stale SQLite WAL/SHM sidecars; close other shells with
    active Atuin sessions before using the restored history. Needs -BackupUser or
    SKOOP_BACKUP_USER for unattended runs.

.PARAMETER RestoreOpenCode
    Restore OpenCode config/state and credentials from the shutdown backup once
    per machine. Run it after the app phases: the CLI must be installed for
    `opencode auth import`.

.PARAMETER ForceVicinaeRestore
    Ignore the "already restored" marker and restore Vicinae again.

.PARAMETER ForcePearDesktopRestore
    Ignore the "already restored" marker and restore Pear Desktop again.

.PARAMETER ForceFirefoxRestore
    Ignore the "already restored" marker and restore Firefox again.

.PARAMETER ForceAtuinRestore
    Ignore the "already restored" marker and restore Atuin again.

.PARAMETER ForceOpenCodeRestore
    Ignore the "already restored" marker and restore OpenCode again.

.PARAMETER BackupUser
    SSH user on acer-ubuntu for the optional restore steps. Defaults to
    $env:SKOOP_BACKUP_USER.

.PARAMETER FailOnFirefoxRestoreError
    Treat a failed Firefox restore as a terminating error instead of a warning.
    The bootstraps pass this so an install stops before GitHub auth and repo
    clones when the Firefox profile could not be restored.

.PARAMETER FailOnOpenCodeRestoreError
    Treat a failed OpenCode auth restore as a terminating error. The bootstraps
    pass this so credentials are restored before the Firefox profile.

.EXAMPLE
    .\apps\tailscale\configure.ps1

.EXAMPLE
    .\apps\tailscale\configure.ps1 -SignIn -RestoreVicinae -RestorePearDesktop

.EXAMPLE
    .\apps\tailscale\configure.ps1 -RestoreOpenCode -BackupUser keios

.EXAMPLE
    .\apps\tailscale\configure.ps1 -SignIn -RestoreVicinae -RestorePearDesktop -RestoreFirefox -RestoreAtuin

.EXAMPLE
    .\apps\tailscale\configure.ps1 -RestoreFirefox -RestoreAtuin -BackupUser keios

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
    [switch]$RestoreFirefox,
    [switch]$RestoreAtuin,
    [switch]$RestoreOpenCode,
    [switch]$ForceVicinaeRestore,
    [switch]$ForcePearDesktopRestore,
    [switch]$ForceFirefoxRestore,
    [switch]$ForceAtuinRestore,
    [switch]$ForceOpenCodeRestore,
    [switch]$FailOnFirefoxRestoreError,
    [switch]$FailOnOpenCodeRestoreError,
    [string]$BackupUser = "$env:SKOOP_BACKUP_USER"
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message)   { Write-Host "    $Message" -ForegroundColor DarkGray }
function Write-Warn([string]$Message) { Write-Host "    $Message" -ForegroundColor Yellow }

function Resolve-BackupUser {
    param([string]$Explicit)
    if ($Explicit) { return $Explicit.Trim() }
    $cacheFile = Join-Path $env:LOCALAPPDATA 'skoop\backup-user'
    if (Test-Path -LiteralPath $cacheFile) {
        $cached = (Get-Content -LiteralPath $cacheFile -TotalCount 1 -ErrorAction SilentlyContinue)
        if ($cached -and $cached.Trim()) { return $cached.Trim() }
    }
    return $null
}
# install.ps1 caches -BackupUser early; use it here too so non-interactive
# restores do not fail just because the caller omitted -BackupUser.
$BackupUser = Resolve-BackupUser -Explicit $BackupUser

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

function Wait-TailscaleConnected {
    param([string]$Cli, [int]$TimeoutSeconds = 30)
    # `tailscale up --qr` can exit 0 before status --json reports Online.
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (Test-TailscaleConnected $Cli) { return $true }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    return Test-TailscaleConnected $Cli
}

function Get-FirefoxExePath {
    # Prefer the path of a running Firefox; otherwise look in the usual install
    # locations. Scoop's shim points at a versioned folder, so use the app dir.
    $running = @(Get-Process -Name firefox -ErrorAction SilentlyContinue)
    foreach ($proc in $running) {
        try {
            if ($proc.Path) { return $proc.Path }
        } catch { }
    }
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA, (Join-Path $env:USERPROFILE 'scoop'))
    if ($env:SCOOP) { $roots += $env:SCOOP }
    foreach ($root in $roots) {
        if (-not $root) { continue }
        foreach ($relative in @('Mozilla Firefox\firefox.exe', 'apps\firefox\current\firefox.exe')) {
            $candidate = Join-Path $root $relative
            if (Test-Path -LiteralPath $candidate) { return $candidate }
        }
    }
    return $null
}

function Close-FirefoxForRestore {
    # restore-backup.ps1 refuses to copy a live Firefox profile, so close it
    # here first. Returns an object describing whether it is safe to proceed,
    # whether a running Firefox was stopped and its exe path for the relaunch.
    $processes = @(Get-Process -Name firefox -ErrorAction SilentlyContinue)
    if ($processes.Count -eq 0) {
        return [pscustomobject]@{ Ok = $true; WasRunning = $false; Exe = $null }
    }

    $exe = $null
    foreach ($proc in $processes) {
        try {
            if ($proc.Path) { $exe = $proc.Path; break }
        } catch { }
    }
    if (-not $exe) { $exe = Get-FirefoxExePath }

    Write-Step 'Closing Firefox for a clean profile restore'
    foreach ($proc in $processes) {
        try { $null = $proc.CloseMainWindow() } catch { }
    }
    # Give the windows a few seconds to exit on their own before forcing them.
    foreach ($proc in $processes) {
        try { $null = $proc.WaitForExit(5000) } catch { }
    }
    $remaining = @(Get-Process -Name firefox -ErrorAction SilentlyContinue)
    if ($remaining.Count -gt 0) {
        Write-Warn 'Firefox did not exit on its own - stopping the remaining processes.'
        foreach ($proc in $remaining) {
            try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop } catch { }
        }
        Start-Sleep -Milliseconds 1500
        $remaining = @(Get-Process -Name firefox -ErrorAction SilentlyContinue)
    }
    if ($remaining.Count -gt 0) {
        Write-Warn 'Firefox is still running - skipping its auto-restore so locked profile files are not copied.'
        return [pscustomobject]@{ Ok = $false; WasRunning = $true; Exe = $exe }
    }
    return [pscustomobject]@{ Ok = $true; WasRunning = $true; Exe = $exe }
}

function Invoke-RestoreOnConnect {
    # The shutdown backup uploads the Firefox profile, Vicinae's config/data,
    # Atuin's config/history, Pear Desktop's signed-in userData and OpenCode's
    # config/state/credentials, so a reconnected (or freshly installed) machine
    # can put them straight back. One marker per app keeps re-runs idempotent.
    param(
        [ValidateSet('firefox', 'vicinae', 'atuin', 'pear', 'opencode')]
        [string] $App,
        [string] $Label,
        [switch] $ForceRestore,
        [string] $ForceSwitch,
        [string] $MarkerName,
        [switch] $FailOnRestoreError
    )

    $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $restoreScript = Join-Path $repoRoot 'core\restore-backup.ps1'
    if (-not (Test-Path -LiteralPath $restoreScript)) {
        $message = "core/restore-backup.ps1 not found - skipping $Label auto-restore."
        if ($FailOnRestoreError) { throw $message }
        Write-Warn $message
        return
    }
    if ($App -eq 'opencode' -and -not (Get-Command opencode -ErrorAction SilentlyContinue)) {
        Write-Warn 'opencode is not installed yet - its config/credentials are restored after the app phases.'
        return
    }
    if (-not $MarkerName) { $MarkerName = "$App-restore-on-connect.done" }
    $marker = Join-Path $env:LOCALAPPDATA "skoop\$MarkerName"
    if ((Test-Path -LiteralPath $marker) -and -not $ForceRestore) {
        Write-Ok "$Label already restored - skipping (pass -$ForceSwitch to repeat)"
        return
    }
    if (-not $BackupUser -and -not [Environment]::UserInteractive) {
        $message = "no SSH user for acer-ubuntu - set -BackupUser / SKOOP_BACKUP_USER to auto-restore $Label."
        if ($FailOnRestoreError) { throw $message }
        Write-Warn $message
        return
    }
    # Hashtable splatting binds these as named parameters. A string array would
    # bind positionally (-Only -> -User, firefox -> -TargetHost), producing the
    # bogus "-Only@firefox" SSH target.
    $restoreArgs = @{ Only = $App }
    if ($BackupUser) { $restoreArgs.User = $BackupUser }

    # No CLI-existence guard for Firefox/Atuin: their restore is a plain file
    # copy and must work before the apps are installed in later phases.
    $closedFirefox = $null
    if ($App -eq 'firefox') {
        $closedFirefox = Close-FirefoxForRestore
        if (-not $closedFirefox.Ok) {
            $message = "Firefox is still running - cannot restore its profile; close it and re-run."
            if ($FailOnRestoreError) { throw $message }
            return
        }
    } elseif ($App -eq 'atuin') {
        Write-Warn 'Close other shells with active Atuin sessions before using the restored history.'
    }

    Write-Step "Restoring $Label from the latest backup after Tailscale connect"
    try {
        & $restoreScript @restoreArgs
        $markerDir = Split-Path -Parent $marker
        if (-not (Test-Path -LiteralPath $markerDir)) { New-Item -ItemType Directory -Force -Path $markerDir | Out-Null }
        [System.IO.File]::WriteAllText($marker, (Get-Date -Format 'o'))
        Write-Ok "$Label restored; marker written to $marker"
    } catch {
        $message = "$Label auto-restore failed: $($_.Exception.Message)"
        if ($FailOnRestoreError) { throw $message }
        Write-Warn "$message (non-fatal)"
    } finally {
        # Only relaunch when a running Firefox was actually closed for the copy.
        if ($closedFirefox -and $closedFirefox.WasRunning -and $closedFirefox.Exe) {
            try {
                Start-Process -FilePath $closedFirefox.Exe
                Write-Ok 'Firefox relaunched after the profile restore'
            } catch {
                Write-Warn "could not relaunch Firefox ($($closedFirefox.Exe)): $($_.Exception.Message)"
            }
        }
    }
}

$cli = Resolve-TailscaleCli
$signInCompleted = $false

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
            $signInCompleted = $true
        }
    }
}

# Probe again rather than trusting the sign-in exit code: the QR flow can exit
# 0 without a working connection, and already-connected nodes skip it entirely.
# After a successful sign-in, allow status --json a few seconds to report Online.
$connected = Test-TailscaleConnected $cli
if ($signInCompleted -and -not $connected) { $connected = Wait-TailscaleConnected $cli }
# Mandatory restores must not silently fall through when Tailscale is offline.
if ($RestoreFirefox -and $FailOnFirefoxRestoreError -and -not $connected) {
    $firefoxMarker = Join-Path $env:LOCALAPPDATA 'skoop\firefox-restore.done'
    if ($ForceFirefoxRestore -or -not (Test-Path -LiteralPath $firefoxMarker)) {
        throw 'Firefox restore is required but Tailscale is not connected - sign in to Tailscale, then re-run install.ps1.'
    }
}
if ($RestoreOpenCode -and $FailOnOpenCodeRestoreError -and -not $connected) {
    $opencodeMarker = Join-Path $env:LOCALAPPDATA 'skoop\opencode-restore.done'
    if ($ForceOpenCodeRestore -or -not (Test-Path -LiteralPath $opencodeMarker)) {
        throw 'OpenCode auth restore is required but Tailscale is not connected - sign in to Tailscale, then re-run install.ps1.'
    }
}
if ($RestoreVicinae -and $connected) {
    Invoke-RestoreOnConnect -App vicinae -Label 'Vicinae' -ForceRestore:$ForceVicinaeRestore -ForceSwitch 'ForceVicinaeRestore'
}
if ($RestorePearDesktop -and $connected) {
    Invoke-RestoreOnConnect -App pear -Label 'Pear Desktop' -ForceRestore:$ForcePearDesktopRestore -ForceSwitch 'ForcePearDesktopRestore'
}
# OpenCode credentials first: the bootstraps require them to be in place before
# the Firefox profile is copied and before gh auth prompts.
if ($RestoreOpenCode -and $connected) {
    Invoke-RestoreOnConnect -App opencode -Label 'OpenCode' -ForceRestore:$ForceOpenCodeRestore -ForceSwitch 'ForceOpenCodeRestore' -MarkerName 'opencode-restore.done' -FailOnRestoreError:$FailOnOpenCodeRestoreError
}
if ($RestoreFirefox -and $connected) {
    Invoke-RestoreOnConnect -App firefox -Label 'Firefox' -ForceRestore:$ForceFirefoxRestore -ForceSwitch 'ForceFirefoxRestore' -MarkerName 'firefox-restore.done' -FailOnRestoreError:$FailOnFirefoxRestoreError
}
if ($RestoreAtuin -and $connected) {
    Invoke-RestoreOnConnect -App atuin -Label 'Atuin' -ForceRestore:$ForceAtuinRestore -ForceSwitch 'ForceAtuinRestore' -MarkerName 'atuin-restore.done'
}

if ($SkipTag) { Write-Ok 'Tailnet tagging skipped (-SkipTag).'; return }
if ($Tag -notlike 'tag:*') { $Tag = "tag:$Tag" }

if (-not $cli) { Write-Warn 'tailscale.exe not found - skipping tailnet tagging.'; return }

Write-Step "Tagging this device with $Tag in the tailnet"
if (-not $connected) {
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
