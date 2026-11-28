#Requires -Version 5.1
<#
.SYNOPSIS
    Advertise a tailnet ACL tag on this device (default: tag:public-client).

.DESCRIPTION
    Idempotent and non-fatal. Resolves tailscale.exe from PATH, Program Files
    or any Scoop root (shim or app dir), skips when Tailscale is not connected, and only runs
    `tailscale up --advertise-tags=...` when the tag is not already advertised.
    Tagging runs BEFORE the snapshot restores, because the tailnet ACL may only
    let tagged devices reach acer-ubuntu: an untagged node would be refused.
    It never reauthenticates an unconnected node: sign in from the tray icon or
    with `tailscale up` first. Native stderr is merged through cmd.exe because
    Windows PowerShell 5.1 turns it into a terminating NativeCommandError.

    With -RestoreVicinae, -RestorePearDesktop, -RestoreFirefox, -RestoreAtuin
    and/or -RestoreOpenCode, a connected node also restores that app from the
    latest acer-ubuntu snapshot through core/restore-backup.ps1 (-Only vicinae /
    pear / firefox / atuin / opencode). A marker under %LOCALAPPDATA%\skoop keeps
    re-runs from downloading it again. OpenCode is restored first; Vicinae, Pear
    Desktop, Firefox and Atuin then run as parallel child processes and the parent
    waits for all of them. Failures are non-fatal unless -FailOnFirefoxRestoreError
    / -FailOnOpenCodeRestoreError is set. -ForceVicinaeRestore
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
    Leave this device's advertised tags untouched. The parallel per-app restore
    children pass this; the parent tags once, before the restores.

.PARAMETER SignIn
    Run `tailscale up --qr` when this node is not signed in, so the login URL
    and QR code are shown. The QR is opened in a new Rio window when Rio and
    pwsh are available (they render the Unicode block QR correctly); otherwise
    it streams in the current console with UTF-8 output. Used by the
    core-terminal phase so Tailscale is connected before the slower phases (and
    Firefox) start.

.PARAMETER SignInTimeout
    Seconds to wait for the QR sign-in when it runs in its own Rio window.
    Defaults to 600; 0 waits until you interrupt the script.

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
    # Seconds to wait for the QR sign-in when it runs in its own terminal
    # window. 0 waits until you give up (Ctrl+C).
    [int]$SignInTimeout = 600,
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
    [string]$BackupUser = "$env:SKOOP_BACKUP_USER",
    # Internal: per-app log path used when restores run as parallel child jobs.
    [string]$RestoreLogPath
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
    $candidates = @()
    if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe') }
    if (${env:ProgramFiles(x86)}) { $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Tailscale\tailscale.exe') }
    # Scoop can be rooted in a user profile or ProgramData; its shim and the
    # package's app dir are both usable when PATH has not caught up yet.
    $roots = @()
    if ($env:SCOOP) { $roots += $env:SCOOP }
    if ($env:USERPROFILE) { $roots += (Join-Path $env:USERPROFILE 'scoop') }
    if ($env:ProgramData) { $roots += (Join-Path $env:ProgramData 'scoop') }
    foreach ($root in $roots) {
        $candidates += (Join-Path $root 'shims\tailscale.exe')
        $candidates += (Join-Path $root 'apps\tailscale\current\tailscale.exe')
    }
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) { return $candidate }
    }
    return $null
}

function Resolve-TailscaleAppDir {
    param([string]$Cli)
    # Prefer the package's app dir over the CLI's folder: Scoop also shims
    # tailscale-ipn.exe into shims\, and the tray must be launched from
    # apps\tailscale\current to keep its notification-area identity.
    $candidates = @()
    $roots = @()
    if ($env:SCOOP) { $roots += $env:SCOOP }
    if ($env:USERPROFILE) { $roots += (Join-Path $env:USERPROFILE 'scoop') }
    if ($env:ProgramData) { $roots += (Join-Path $env:ProgramData 'scoop') }
    foreach ($root in $roots) { $candidates += (Join-Path $root 'apps\tailscale\current') }
    if ($Cli) { $candidates += (Split-Path -Parent $Cli) }
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath (Join-Path $candidate 'tailscale-ipn.exe'))) { return $candidate }
    }
    return $null
}

function Start-TailscaleTray {
    # Launch the tray app from its Scoop Apps Start Menu shortcut. Windows keys
    # the notification-area entry on the shortcut/executable identity, so a tray
    # started from a versioned folder (apps\tailscale\1.104.7) is treated as a
    # different app and can stay hidden. Starting the .lnk keeps the icon and
    # the "Authentication Needed" notification visible.
    param([string]$AppDir)

    $wanted = if ($AppDir) { Join-Path $AppDir 'tailscale-ipn.exe' } else { $null }
    $running = @(Get-Process -Name 'tailscale-ipn' -ErrorAction SilentlyContinue)
    $stale = @()
    foreach ($process in $running) {
        try {
            $path = $process.Path
            if ($wanted -and $path -and ($path -ne $wanted)) { $stale += $process }
        } catch {
            # An elevated tray may hide its path; leave it alone.
        }
    }
    if ($running.Count -gt 0 -and $stale.Count -eq 0) {
        Write-Ok 'Tailscale tray is already running'
        return
    }
    if ($stale.Count -gt 0) {
        try {
            $stale | Stop-Process -Force
            Start-Sleep -Milliseconds 500
            Write-Ok 'restarted the Tailscale tray so its icon identity matches'
        } catch {
            Write-Warn "could not restart the stale Tailscale tray: $($_.Exception.Message)"
        }
    }

    $shortcut = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Microsoft\Windows\Start Menu\Programs\Scoop Apps\Tailscale.lnk'
    if (Test-Path -LiteralPath $shortcut) {
        try {
            Start-Process -FilePath $shortcut
            Write-Ok 'started the Tailscale tray from its Scoop Apps shortcut'
            return
        } catch {
            Write-Warn "could not start the Tailscale shortcut: $($_.Exception.Message)"
        }
    }
    if ($wanted -and (Test-Path -LiteralPath $wanted)) {
        try {
            Start-Process -FilePath $wanted
            Write-Ok 'started tailscale-ipn.exe (Tailscale tray)'
        } catch {
            Write-Warn "could not start the Tailscale tray: $($_.Exception.Message)"
        }
    }
}

function Resolve-SkoopExe {
    # Resolve rio/pwsh from PATH or the Scoop roots (shims, app dir, bin).
    param([string]$Name)
    $found = Get-Command $Name -ErrorAction SilentlyContinue
    if ($found) { return $found.Source }
    $roots = @()
    if ($env:SCOOP) { $roots += $env:SCOOP }
    if ($env:USERPROFILE) { $roots += (Join-Path $env:USERPROFILE 'scoop') }
    if ($env:ProgramData) { $roots += (Join-Path $env:ProgramData 'scoop') }
    foreach ($root in $roots) {
        foreach ($relative in @("shims\$Name.exe", "apps\$Name\current\$Name.exe", "apps\$Name\current\bin\$Name.exe")) {
            $candidate = Join-Path $root $relative
            if (Test-Path -LiteralPath $candidate) { return $candidate }
        }
    }
    return $null
}

function Test-TailscaleSignInProcess {
    # True when a `tailscale up --qr` is already running, e.g. the QR window from
    # an earlier install run. Reuse it instead of opening another window.
    try {
        $procs = @(Get-CimInstance Win32_Process -Filter "Name='tailscale.exe'" -ErrorAction SilentlyContinue)
    } catch {
        return $false
    }
    foreach ($proc in $procs) {
        $line = [string]$proc.CommandLine
        if ($line -match '(^|\s)up(\s|$)' -and $line -match '--qr') { return $true }
    }
    return $false
}

function Start-TailscaleQrWindow {
    # Show `tailscale up --qr` in its own Rio window. Rio (installed in phase 1)
    # renders the Unicode block QR correctly, while a legacy conhost with code
    # page 437 shows it as mojibake. The window closes itself once `tailscale up`
    # returns, so repeated install runs do not pile up terminals. Returns $true
    # when the window was opened.
    param([string]$Cli)

    if (-not [Environment]::UserInteractive) { return $false }
    $rio = Resolve-SkoopExe -Name 'rio'
    $pwsh = Resolve-SkoopExe -Name 'pwsh'
    if (-not $rio -or -not $pwsh) { return $false }

    $reposDir = Join-Path $env:USERPROFILE 'repos'
    if (-not (Test-Path -LiteralPath $reposDir)) {
        New-Item -ItemType Directory -Force -Path $reposDir | Out-Null
    }
    # Single quotes keep a path with spaces intact; the whole -Command string is
    # double-quoted because Start-Process joins -ArgumentList without quoting.
    # `$LASTEXITCODE` is escaped so the child evaluates it, not this script.
    $command = "& '$Cli' up --qr; if (`$LASTEXITCODE -ne 0) { Write-Host 'Tailscale sign-in did not finish - see the message above.'; Start-Sleep -Seconds 10 }"
    $rioArgs = @('-w', "`"$reposDir`"", '-e', "`"$pwsh`"", '-NoLogo', '-Command', "`"$command`"")
    try {
        Start-Process -FilePath $rio -ArgumentList $rioArgs -WorkingDirectory $reposDir | Out-Null
        return $true
    } catch {
        Write-Warn "could not open Rio for the QR: $($_.Exception.Message)"
        return $false
    }
}

function Wait-TailscaleSignIn {
    # The QR runs in its own window, so poll the backend instead of waiting on
    # the child process. -TimeoutSeconds 0 waits until the script is stopped.
    param([string]$Cli, [int]$TimeoutSeconds = 600, [switch]$WatchProcess)
    $deadline = if ($TimeoutSeconds -gt 0) { (Get-Date).AddSeconds($TimeoutSeconds) } else { $null }
    $nextReport = (Get-Date).AddSeconds(20)
    while ($true) {
        if (Test-TailscaleConnected $Cli) { return $true }
        if ($WatchProcess -and -not (Test-TailscaleSignInProcess)) {
            # The QR window exited (cancelled or failed). Give the backend a
            # moment, then stop instead of waiting out the whole timeout.
            Start-Sleep -Seconds 5
            return (Test-TailscaleConnected $Cli)
        }
        if ($deadline -and (Get-Date) -ge $deadline) { return $false }
        if ((Get-Date) -ge $nextReport) {
            if ($deadline) {
                $left = [int][Math]::Max(0, [Math]::Ceiling(($deadline - (Get-Date)).TotalSeconds))
                Write-Ok "waiting for the Tailscale sign-in (${left}s left)"
            } else {
                Write-Ok 'waiting for the Tailscale sign-in'
            }
            $nextReport = (Get-Date).AddSeconds(20)
        }
        Start-Sleep -Seconds 2
    }
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
    if ($RestoreLogPath) { $restoreArgs.LogPath = $RestoreLogPath }

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
        # A legacy conhost with code page 437 renders the Unicode block QR as
        # mojibake, so the QR is shown in a new Rio window when possible. An
        # already-open `tailscale up --qr` (from an earlier run) is reused
        # instead of opening another terminal.
        if (Test-TailscaleSignInProcess) {
            Write-Step 'Signing in to Tailscale (a QR window is already open)'
            $signInCompleted = Wait-TailscaleSignIn -Cli $cli -TimeoutSeconds $SignInTimeout -WatchProcess
            if ($signInCompleted) {
                Write-Ok 'Tailscale sign-in complete'
            } else {
                Write-Warn 'Tailscale sign-in did not complete - run `tailscale up --qr` later.'
            }
        } elseif (Start-TailscaleQrWindow -Cli $cli) {
            Write-Step 'Signing in to Tailscale (scan the QR code in the new Rio window)'
            $signInCompleted = Wait-TailscaleSignIn -Cli $cli -TimeoutSeconds $SignInTimeout -WatchProcess
            if ($signInCompleted) {
                Write-Ok 'Tailscale sign-in complete'
            } else {
                Write-Warn 'Tailscale sign-in did not complete - run `tailscale up --qr` later.'
            }
        } else {
            Write-Step 'Signing in to Tailscale (scan the QR code below)'
            # Fallback for machines without Rio/pwsh: stream the QR through
            # PowerShell. --qr draws it on stderr and a transcript does not
            # capture native stderr live, so Tee-Object keeps a copy in
            # %LOCALAPPDATA%\skoop\tailscale-signin.log and Write-Host makes
            # every line appear as it arrives. The console code page is forced
            # to UTF-8 so the block characters are not mangled; cmd merges
            # stderr so 5.1 does not raise NativeCommandError.
            $signInLog = Join-Path $env:LOCALAPPDATA 'skoop\tailscale-signin.log'
            $signInDir = Split-Path -Parent $signInLog
            if (-not (Test-Path -LiteralPath $signInDir)) {
                New-Item -ItemType Directory -Force -Path $signInDir | Out-Null
            }
            $oldEncoding = [Console]::OutputEncoding
            try {
                [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
                & cmd /c "`"$cli`" up --qr 2>&1" |
                    Tee-Object -FilePath $signInLog |
                    ForEach-Object {
                        if ($_ -match '(https://login\.tailscale\.com/\S+)') {
                            Write-Host ('    Login URL: ' + $Matches[1]) -ForegroundColor Yellow
                        } else {
                            Write-Host $_
                        }
                    }
            } finally {
                [Console]::OutputEncoding = $oldEncoding
            }
            $exit = $LASTEXITCODE
            if ($exit -ne 0) {
                Write-Warn "Tailscale sign-in did not finish (exit $exit) - run ``tailscale up --qr`` later."
            } else {
                Write-Ok 'Tailscale sign-in complete'
                $signInCompleted = $true
            }
        }
    }
}

# Probe again rather than trusting the sign-in exit code: the QR flow can exit
# 0 without a working connection, and already-connected nodes skip it entirely.
# After a successful sign-in, allow status --json a few seconds to report Online.
$connected = Test-TailscaleConnected $cli
if ($signInCompleted -and -not $connected) { $connected = Wait-TailscaleConnected $cli }
# Bring the tray back from its Scoop Apps shortcut once the node is connected:
# that is the identity Windows expects, so the icon and its notifications show.
if ($connected) {
    Start-TailscaleTray -AppDir (Resolve-TailscaleAppDir -Cli $cli)
}
# Advertise the ACL tag BEFORE restoring: the tailnet ACL may only let tagged
# devices reach acer-ubuntu, so SSH restores are refused until this device carries
# the tag. The parallel per-app children run with -SkipTag and never repeat it.
# When restores are requested, a tag that cannot be applied stops the run - the
# restores would otherwise fail one by one with a confusing SSH error.
$restoresRequested = $RestoreVicinae -or $RestorePearDesktop -or $RestoreFirefox -or $RestoreAtuin -or $RestoreOpenCode
if ($SkipTag) {
    Write-Ok 'Tailnet tagging skipped (-SkipTag)'
} else {
    if ($Tag -notlike 'tag:*') { $Tag = "tag:$Tag" }
    $tagError = $null
    if (-not $cli) {
        $tagError = 'tailscale.exe was not found'
    } elseif (-not $connected) {
        $tagError = 'Tailscale is not connected'
    } else {
        Write-Step "Tagging this device with $Tag in the tailnet"
        $prefsRaw = (& cmd /c "`"$cli`" debug prefs 2>&1" | Out-String)
        $prefs = try { $prefsRaw | ConvertFrom-Json -ErrorAction Stop } catch { $null }
        $advertised = if ($prefs) { @($prefs.AdvertiseTags) } else { @() }
        if ($advertised -contains $Tag) {
            Write-Ok "$Tag is already advertised on this device"
        } else {
            $out = (& cmd /c "`"$cli`" up --advertise-tags=$Tag 2>&1" | Out-String)
            if ($LASTEXITCODE -ne 0) {
                $tagError = "tailscale up --advertise-tags exited ${LASTEXITCODE}: $(($out -split "`r?`n" | Select-Object -First 2) -join ' ')"
            } else {
                Write-Ok "advertised $Tag on this device"
                # A tag change re-registers the node; wait before the restores SSH out.
                if (-not (Wait-TailscaleConnected $cli)) {
                    $connected = $false
                    $tagError = 'Tailscale did not come back online after tagging'
                }
            }
        }
    }
    if ($tagError) {
        $message = "Cannot advertise $Tag ($tagError). The tailnet ACL may only let tagged devices reach acer-ubuntu, so the restores would fail."
        if ($restoresRequested) {
            throw "$message Fix the tag ownership in the ACL, then re-run install.ps1."
        } else {
            Write-Warn "$message (non-fatal outside the restore flow)"
            Write-Warn 'Check that your tailnet ACL lists you as a tag owner for this tag.'
        }
    }
}
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
# OpenCode credentials first: the bootstraps require them to be in place before
# the Firefox profile is copied and before gh auth prompts.
if ($RestoreOpenCode -and $connected) {
    Invoke-RestoreOnConnect -App opencode -Label 'OpenCode' -ForceRestore:$ForceOpenCodeRestore -ForceSwitch 'ForceOpenCodeRestore' -MarkerName 'opencode-restore.done' -FailOnRestoreError:$FailOnOpenCodeRestoreError
}

# The remaining snapshots touch different apps, so run each in its own child
# process and wait for all of them before tagging or returning. Firefox is
# closed and relaunched by its own worker.
$restoreJobs = @()
if ($RestoreVicinae -and $connected) {
    $restoreJobs += [pscustomobject]@{ App='vicinae'; Label='Vicinae'; Switch='-RestoreVicinae'; Marker=$null; Force=$ForceVicinaeRestore; ForceSwitch='ForceVicinaeRestore'; Fail=$false }
}
if ($RestorePearDesktop -and $connected) {
    $restoreJobs += [pscustomobject]@{ App='pear'; Label='Pear Desktop'; Switch='-RestorePearDesktop'; Marker=$null; Force=$ForcePearDesktopRestore; ForceSwitch='ForcePearDesktopRestore'; Fail=$false }
}
if ($RestoreFirefox -and $connected) {
    $restoreJobs += [pscustomobject]@{ App='firefox'; Label='Firefox'; Switch='-RestoreFirefox'; Marker='firefox-restore.done'; Force=$ForceFirefoxRestore; ForceSwitch='ForceFirefoxRestore'; Fail=[bool]$FailOnFirefoxRestoreError }
}
if ($RestoreAtuin -and $connected) {
    $restoreJobs += [pscustomobject]@{ App='atuin'; Label='Atuin'; Switch='-RestoreAtuin'; Marker='atuin-restore.done'; Force=$ForceAtuinRestore; ForceSwitch='ForceAtuinRestore'; Fail=$false }
}

if ($restoreJobs.Count -eq 1) {
    $job = $restoreJobs[0]
    $params = @{ App = $job.App; Label = $job.Label; ForceRestore = $job.Force; ForceSwitch = $job.ForceSwitch; FailOnRestoreError = $job.Fail }
    if ($job.Marker) { $params.MarkerName = $job.Marker }
    Invoke-RestoreOnConnect @params
} elseif ($restoreJobs.Count -gt 1) {
    Write-Step ('Restoring {0} backups in parallel' -f $restoreJobs.Count)
    $exe = (Get-Process -Id $PID).Path
    if (-not $exe) {
        $exe = if ($PSVersionTable.PSEdition -eq 'Core') { Join-Path $PSHOME 'pwsh.exe' } else { Join-Path $PSHOME 'powershell.exe' }
    }
    $scriptPath = if ($PSCommandPath) { $PSCommandPath } else { Join-Path $PSScriptRoot 'configure.ps1' }
    $running = @()
    try {
        foreach ($job in $restoreJobs) {
            $logPath = Join-Path $env:LOCALAPPDATA ('skoop\restore\restore-{0}-{1}.log' -f $job.App, (Get-Date -Format 'yyyy-MM-dd-HHmmss'))
            $argLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" -SkipTag {1} -RestoreLogPath "{2}"' -f $scriptPath, $job.Switch, $logPath
            if ($BackupUser) { $argLine += ' -BackupUser "{0}"' -f $BackupUser }
            if ($job.Force) { $argLine += ' -' + $job.ForceSwitch }
            if ($job.Fail) { $argLine += ' -FailOnFirefoxRestoreError' }
            $running += [pscustomobject]@{ Job = $job; Process = (Start-Process -FilePath $exe -ArgumentList $argLine -NoNewWindow -PassThru) }
        }
    } catch {
        if ($running.Count -gt 0) {
            foreach ($entry in $running) { $entry.Process.WaitForExit() }
            throw
        }
        Write-Warn "parallel restores unavailable ($($_.Exception.Message)) - running sequentially"
        foreach ($job in $restoreJobs) {
            $params = @{ App = $job.App; Label = $job.Label; ForceRestore = $job.Force; ForceSwitch = $job.ForceSwitch; FailOnRestoreError = $job.Fail }
            if ($job.Marker) { $params.MarkerName = $job.Marker }
            Invoke-RestoreOnConnect @params
        }
        $restoreJobs = @()
    }
    foreach ($entry in $running) {
        $entry.Process.WaitForExit()
        if ($entry.Process.ExitCode -ne 0) {
            $message = "$($entry.Job.Label) auto-restore failed (exit $($entry.Process.ExitCode))."
            if ($entry.Job.Fail) { throw $message }
            Write-Warn "$message (non-fatal)"
        }
    }
}
