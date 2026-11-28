#Requires -Version 5.1
<#
.SYNOPSIS
    Restore the latest Firefox, Vicinae, Atuin, Pear Desktop, OpenCode, SSH key and/or registered repos list snapshot from acer-ubuntu onto a fresh machine.

.DESCRIPTION
    Companion to core/cleanup-before-shutdown.ps1. The backup keeps one folder per
    app on the tailnet host (~/skoop-backups/firefox/<timestamp>/firefox,
    ~/skoop-backups/vicinae/<timestamp>/vicinae,
    ~/skoop-backups/atuin/<timestamp>/atuin,
    ~/skoop-backups/pear/<timestamp>/pear,
    ~/skoop-backups/opencode/<timestamp>/opencode and
    ~/skoop-backups/ssh/<timestamp>/ssh and
    ~/skoop-backups/repos/<timestamp>/repos); this script picks the newest
    timestamp for each app independently, downloads it with scp and merges it into
    place:

      - Firefox: profiles.ini, installs.ini and every profile folder in the
        snapshot go back under %APPDATA%\Mozilla\Firefox. Existing folders are
        merged rather than deleted, and a changed profiles.ini / installs.ini is
        kept as .bak.<timestamp>. Firefox must be closed while this runs.
      - Vicinae: the config, data and state folders in the snapshot are merged
        into %LOCALAPPDATA%\vicinae (the disposable cache is never restored). A
        running vicinae-server is stopped for the copy and restarted afterwards.
      - Atuin: config.toml / server.toml and the data folder (history.db,
        records.db, meta.db, key and SQLite sidecars) are merged into
        %USERPROFILE%\.atuin. Stale .db-wal / .db-shm files already on this machine
        are removed first so a restored database is not mixed with local journal
        data. Close other shells with active Atuin sessions before using the
        restored history; Atuin is per-shell so there is no service to stop.
      - Pear Desktop: the snapshotted userData folders are merged back under
        %APPDATA% (and %LOCALAPPDATA% when that scope was backed up), keeping the
        saved Google login. A running Pear Desktop / YouTube Music process is
        stopped first and a stale Chromium lockfile is removed. Cookies are
        encrypted with Windows DPAPI, so a different Windows user or machine may
        still ask you to sign in again; the app config and local storage survive.
      - OpenCode: config (`~/.config/opencode`) and state (`~/.local/state/opencode`,
        including the selected model and prompt history) are merged back, then the
        snapshot's `auth/export.json` is imported with `opencode auth import` so
        integrations stay signed in. Legacy v1 `auth.json` files are copied back
        too. The CLI must be installed; run the restore after the app phase or
        install it first.
      - Repos: the registered repo list (repos.json) is copied to
        %LOCALAPPDATA%\skoop\repos.json; install.ps1 uses it to clone missing
        checkouts on a fresh machine.
      - SSH: private/public keys and the client config from ~/.ssh are merged
        back (existing files get a timestamped .bak unless -NoBackup). Protect
        the restored private key; never leave it on a public/shared PC.

    Nothing is uploaded or changed on the remote host. -List prints the newest
    snapshot for each app, -Stamp pins all apps to one timestamp, -Only narrows
    the restore, and -DryRun prints the plan without changing anything. -NoBackup
    overwrites local config without keeping a .bak copy; -NoRestart leaves a
    stopped Vicinae server stopped. After a fresh machine's first install you can
    re-run .\apps\vicinae\configure.ps1 -Restart to reapply the managed keybinds
    if you changed them outside the repo.

.PARAMETER User
    SSH user on acer-ubuntu. Defaults to $env:SKOOP_BACKUP_USER, then the cached
    %LOCALAPPDATA%\skoop\backup-user written by install.ps1; prompts only when
    neither is available. An answer given at the prompt is cached for next time.

.PARAMETER TargetHost
    Tailnet hostname/IP of the backup machine (default 'acer-ubuntu').

.PARAMETER FirefoxRemotePath
    Firefox snapshot parent on the remote host (default 'skoop-backups/firefox').

.PARAMETER VicinaeRemotePath
    Vicinae snapshot parent on the remote host (default 'skoop-backups/vicinae').

.PARAMETER AtuinRemotePath
    Atuin snapshot parent on the remote host (default 'skoop-backups/atuin').

.PARAMETER PearRemotePath
    Pear Desktop snapshot parent on the remote host (default 'skoop-backups/pear').

.PARAMETER OpenCodeRemotePath
    OpenCode snapshot parent on the remote host (default 'skoop-backups/opencode').

.PARAMETER SshRemotePath
    SSH key snapshot parent on the remote host (default 'skoop-backups/ssh').

.PARAMETER ReposRemotePath
    Registered repo-list snapshot parent on the remote host (default
    'skoop-backups/repos'). Restored to %LOCALAPPDATA%\skoop\repos.json, which
    install.ps1 prefers over the repo's own manifests/repos.json.

.PARAMETER Stamp
    Use this timestamp for all apps instead of each app's latest. Fails if a
    requested app has no snapshot with that timestamp.

.PARAMETER Only
    Restrict the restore to firefox, vicinae, atuin, pear, opencode, ssh and/or
    repos (default: all).

.PARAMETER List
    Print the newest snapshot timestamp per app and exit.

.PARAMETER DryRun
    Show what would be downloaded and restored; do not change any local files.

.PARAMETER NoBackup
    Overwrite profiles.ini / installs.ini, Vicinae folders, Atuin config/data,
    Pear Desktop userData and OpenCode config/state without a .bak copy.

.PARAMETER NoRestart
    Do not relaunch vicinae-server after restoring (it is stopped first if running).

.PARAMETER StagingDir
    Local folder used to assemble the download. Defaults to %LOCALAPPDATA%\skoop\restore.

.PARAMETER LogPath
    File to mirror log output into. Defaults to <StagingDir>\restore-<timestamp>.log.

.EXAMPLE
    .\core\restore-backup.ps1 -List -User keios

.EXAMPLE
    .\core\restore-backup.ps1 -User keios

.EXAMPLE
    .\core\restore-backup.ps1 -User keios -Only vicinae -DryRun

.EXAMPLE
    .\core\restore-backup.ps1 -User keios -Only atuin

.EXAMPLE
    .\core\restore-backup.ps1 -User keios -Only pear

.EXAMPLE
    .\core\restore-backup.ps1 -User keios -Only opencode
#>
[CmdletBinding()]
param(
    [string] $User = "$env:SKOOP_BACKUP_USER",
    [string] $TargetHost = 'acer-ubuntu',
    [string] $FirefoxRemotePath = 'skoop-backups/firefox',
    [string] $VicinaeRemotePath = 'skoop-backups/vicinae',
    [string] $AtuinRemotePath = 'skoop-backups/atuin',
    [string] $PearRemotePath = 'skoop-backups/pear',
    [string] $OpenCodeRemotePath = 'skoop-backups/opencode',
    [string] $SshRemotePath = 'skoop-backups/ssh',
    [string] $ReposRemotePath = 'skoop-backups/repos',
    [string] $Stamp,
    [ValidateSet('firefox', 'vicinae', 'atuin', 'pear', 'opencode', 'ssh', 'repos')]
    [string[]] $Only = @('firefox', 'vicinae', 'atuin', 'pear', 'opencode', 'ssh', 'repos'),
    [switch] $List,
    [switch] $DryRun,
    [switch] $NoBackup,
    [switch] $NoRestart,
    [string] $StagingDir,
    [string] $LogPath
)

$ErrorActionPreference = 'Stop'

$script:LogPath = $null
$remoteHome = $null
$peer = $null
$sshArgs = @()

function Write-Log {
    param([string] $Message)

    $line = '[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $Message
    Write-Host $line
    if ($script:LogPath) {
        try {
            Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
        } catch {
            Write-Host ("[restore] WARNING: could not write log file: " + $_.Exception.Message)
        }
    }
}

function Write-Warn {
    param([string] $Message)
    Write-Log ("WARNING: " + $Message)
}

function Resolve-SshUser {
    $cacheFile = Join-Path $env:LOCALAPPDATA 'skoop\backup-user'
    $resolved = $null
    if ($User) {
        $resolved = $User.Trim()
    } elseif (Test-Path -LiteralPath $cacheFile) {
        $cached = (Get-Content -LiteralPath $cacheFile -TotalCount 1 -ErrorAction SilentlyContinue)
        if ($cached -and $cached.Trim()) {
            $resolved = $cached.Trim()
            Write-Log ("SSH user from " + $cacheFile + ": " + $resolved)
        }
    }
    if (-not $resolved) {
        if (-not [Environment]::UserInteractive) {
            throw 'SSH user is required in a non-interactive shell. Re-run with -User <username>.'
        }
        $answer = Read-Host ("SSH user for " + $TargetHost)
        if (-not $answer -or -not $answer.Trim()) {
            throw 'SSH user cannot be empty.'
        }
        $resolved = $answer.Trim()
    }
    # Remember the answer (or an explicit -User) so later installs and the
    # per-app Tailscale restore hooks never prompt again on this machine.
    try {
        $cacheDir = Split-Path -Parent $cacheFile
        if (-not (Test-Path -LiteralPath $cacheDir)) { New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null }
        Set-Content -LiteralPath $cacheFile -Value $resolved -Encoding ASCII
    } catch {
        Write-Warn ("could not cache the SSH user in " + $cacheFile + ": " + $_.Exception.Message)
    }
    return $resolved
}

function Remove-SshDiagnostics {
    # ssh writes host-key/banner notices to stderr; with 2>&1 they are mixed
    # into stdout, so never treat them as the remote home path.
    param([object[]] $Lines)
    return @($Lines |
        ForEach-Object { $_.ToString().Trim() } |
        Where-Object { $_ -and $_ -notmatch '^(Warning: Permanently added|Pseudo-terminal will not be allocated|Banner:)' })
}

function Get-LatestStamps {
    param([string[]] $SshArgs, [string] $Path)

    $dir = $remoteHome.TrimEnd('/') + '/' + $Path.Trim('/')
    $cmd = "find '" + $dir + "' -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null"
    $out = & ssh @SshArgs $cmd 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warn ("could not list " + $dir + " - no snapshots there yet?")
        return @()
    }
    return @($out |
        ForEach-Object { $_.ToString().Trim() } |
        Where-Object { $_ -match '^\d{4}-\d{2}-\d{2}-\d{6}$' } |
        Sort-Object -Descending)
}

function Get-SnapshotRemotePath {
    param([string] $BasePath, [string] $FolderName, [string] $TheStamp)
    return $remoteHome.TrimEnd('/') + '/' + $BasePath.Trim('/') + '/' + $TheStamp + '/' + $FolderName
}

function Copy-Tree {
    param([string] $Source, [string] $Destination)

    if (Get-Command robocopy -ErrorAction SilentlyContinue) {
        # Run through cmd.exe so robocopy's stderr is merged into stdout; under
        # Windows PowerShell 5.1 native stderr would otherwise become a
        # terminating NativeCommandError and abort before the exit code is seen.
        # Retry briefly for files that are still locked as Firefox exits.
        $code = 0
        $copyOutput = ''
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            $copyOutput = (& cmd.exe /d /c "robocopy `"$Source`" `"$Destination`" /E /COPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NP 2>&1" | Out-String)
            $code = $LASTEXITCODE
            Write-Log ("robocopy attempt {0} for {1}: exit {2}" -f $attempt, $Source, $code)
            if ($code -lt 8) { return }
            if ($attempt -lt 3) { Start-Sleep -Seconds 2 }
        }
        throw ("robocopy failed with code $code for $Source`n" + $copyOutput)
    }

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
            return
        } catch {
            if ($attempt -eq 3) { throw }
            Start-Sleep -Seconds 2
        }
    }
}

function Get-ProfilesIniSections {
    param([string] $Path)

    $sections = @()
    $current = $null
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        if ($line -match '^\[(.+)\]') {
            if ($current) { $sections += $current }
            $current = @{ Section = $Matches[1] }
        } elseif ($current -and $line -match '^([^=]+)=(.*)$') {
            $current[$Matches[1].Trim()] = $Matches[2].Trim()
        }
    }
    if ($current) { $sections += $current }
    return @($sections)
}

function Save-Snapshot {
    param(
        [string] $RemoteFolder,
        [string] $StageRoot,
        [string] $FolderName,
        [string[]] $Excludes = @()
    )

    # Drop a stale target from an earlier interrupted run so the download is clean.
    $target = Join-Path $StageRoot $FolderName
    if ((Test-Path -LiteralPath $target)) {
        Remove-Item -LiteralPath $target -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $target | Out-Null

    # A tar stream avoids Windows' 260-character path limit that scp hits on
    # deep Firefox cache paths. cmd.exe carries the binary stream straight from
    # ssh to tar; PowerShell 5.1 would corrupt it through its text pipeline.
    $tarCmd = Get-Command tar -ErrorAction SilentlyContinue
    if ($tarCmd) {
        $excludeArgs = @()
        foreach ($pattern in $Excludes) { $excludeArgs += "--exclude='$pattern'" }
        $tarExcludes = if ($excludeArgs.Count) { ' ' + ($excludeArgs -join ' ') } else { '' }
        $remoteCmd = "cd '$RemoteFolder' && tar -cf -$tarExcludes ."
        $sshQuoted = @($sshArgs | ForEach-Object { '"' + $_ + '"' }) -join ' '
        # Separate stderr files: both sides of a cmd pipeline writing to the
        # same append target causes a sharing violation on Windows.
        $sshErrLog = $script:LogPath + '.ssh.err'
        $tarErrLog = $script:LogPath + '.tar.err'
        foreach ($errLog in @($sshErrLog, $tarErrLog)) {
            if (Test-Path -LiteralPath $errLog) { Remove-Item -LiteralPath $errLog -Force }
        }
        $cmdLine = "ssh $sshQuoted `"$remoteCmd`" 2>>`"$sshErrLog`" | `"$($tarCmd.Source)`" -xf - -C `"$target`" 2>>`"$tarErrLog`""
        Write-Log ("tar stream: ssh " + ($sshArgs -join ' ') + " '$remoteCmd' | tar -xf - -C $target")
        & cmd.exe /d /c $cmdLine | Out-Null
        $tarExit = $LASTEXITCODE
        foreach ($errLog in @($sshErrLog, $tarErrLog)) {
            if (Test-Path -LiteralPath $errLog) {
                Get-Content -LiteralPath $errLog | ForEach-Object { Write-Log ("stream: " + $_.Trim()) }
            }
        }
        if ($tarExit -eq 0) { return }
        Write-Warn "tar download failed for $RemoteFolder (exit $tarExit); falling back to scp."
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
    }

    $scpArgs = @('-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=10', '-o', 'LogLevel=ERROR', '-r', ($peer + ':' + $RemoteFolder), $StageRoot)
    Write-Log ("scp command: scp " + ($scpArgs -join ' '))
    & scp @scpArgs 2>&1 | ForEach-Object { Write-Log ("scp: " + $_.ToString().Trim()) }
    if ($LASTEXITCODE -ne 0) {
        throw "scp download failed for $RemoteFolder"
    }
}

function Restore-Repos {
    param([string] $StageRoot, [string] $TheStamp)

    $source = Join-Path $StageRoot 'repos\repos.json'
    if (-not (Test-Path -LiteralPath $source)) {
        throw 'Downloaded snapshot has no repos/repos.json; cannot restore the repo list.'
    }
    if ($DryRun) {
        Write-Log 'DRYRUN would restore the registered repos list to %LOCALAPPDATA%\skoop\repos.json'
        return
    }
    $targetDir = Join-Path $env:LOCALAPPDATA 'skoop'
    New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
    $target = Join-Path $targetDir 'repos.json'
    if ((Test-Path -LiteralPath $target) -and -not $NoBackup) {
        $backup = '{0}.bak.{1}' -f $target, (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item -LiteralPath $target -Destination $backup -Force
    }
    Copy-Item -LiteralPath $source -Destination $target -Force
    Write-Log ("restore repos/repos.json -> " + $target)
}

function Restore-Ssh {
    param([string] $StageRoot, [string] $TheStamp)

    $srcRoot = Join-Path $StageRoot 'ssh'
    if (-not (Test-Path -LiteralPath $srcRoot)) {
        throw 'Downloaded snapshot has no ssh folder; cannot restore SSH keys.'
    }
    if ($DryRun) {
        Write-Log 'DRYRUN would restore SSH keys to ~/.ssh'
        return
    }
    $sshDir = Join-Path $env:USERPROFILE '.ssh'
    New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
    $files = @(Get-ChildItem -LiteralPath $srcRoot -File -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) {
        Write-Warn 'SSH snapshot is empty; nothing restored.'
        return
    }
    foreach ($file in $files) {
        $target = Join-Path $sshDir $file.Name
        if ((Test-Path -LiteralPath $target) -and -not $NoBackup) {
            $backup = '{0}.bak.{1}' -f $target, (Get-Date -Format 'yyyyMMdd-HHmmss')
            Copy-Item -LiteralPath $target -Destination $backup -Force
        }
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
        Write-Log ("restore ssh/" + $file.Name + " -> " + $target)
    }
    Write-Warn 'Private SSH key restored - keep it secret; never leave it on a public PC.'
}

function Restore-Firefox {
    param([string] $StageRoot, [string] $TheStamp)

    $firefoxBase = Join-Path $env:APPDATA 'Mozilla\Firefox'
    $srcIni = Join-Path (Join-Path $StageRoot 'firefox') 'profiles.ini'
    if (-not (Test-Path -LiteralPath $srcIni)) {
        if ($DryRun) {
            Write-Log 'DRYRUN would restore Firefox profiles from the downloaded snapshot'
            return
        }
        throw 'Downloaded snapshot has no profiles.ini; cannot restore Firefox.'
    }
    $sections = @(Get-ProfilesIniSections -Path $srcIni)
    if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $firefoxBase | Out-Null }

    foreach ($section in $sections) {
        if (-not $section.ContainsKey('Path')) { continue }
        $rel = ($section['Path'] -replace '/', '\').TrimStart('\')
        if ($section.ContainsKey('IsRelative') -and $section['IsRelative'] -eq '1') {
            $dest = Join-Path $firefoxBase $rel
        } else {
            $dest = $rel
        }
        $leaf = Split-Path -Leaf $rel
        $src = Join-Path (Join-Path $StageRoot 'firefox') $leaf
        if (-not (Test-Path -LiteralPath $src)) {
            Write-Warn ("profile folder missing from snapshot: " + $leaf)
            continue
        }
        Write-Log ("restore profile: " + $leaf + " -> " + $dest)
        if (-not $DryRun) { Copy-Tree -Source $src -Destination $dest }
    }

    foreach ($name in @('profiles.ini', 'installs.ini')) {
        $src = Join-Path (Join-Path $StageRoot 'firefox') $name
        if (-not (Test-Path -LiteralPath $src)) { continue }
        $dest = Join-Path $firefoxBase $name
        if (-not $DryRun -and (Test-Path -LiteralPath $dest) -and -not $NoBackup) {
            $bak = '{0}.bak.{1}' -f $dest, $TheStamp
            Copy-Item -LiteralPath $dest -Destination $bak -Force
            Write-Log ("backed up " + $dest + " -> " + $bak)
        }
        Write-Log ("restore " + $name + " -> " + $dest)
        if (-not $DryRun) { Copy-Item -LiteralPath $src -Destination $dest -Force }
    }
}

function Restore-Vicinae {
    param([string] $StageRoot, [string] $TheStamp)

    $base = Join-Path $env:LOCALAPPDATA 'vicinae'
    foreach ($name in @('config', 'data', 'state')) {
        $src = Join-Path (Join-Path $StageRoot 'vicinae') $name
        if (-not (Test-Path -LiteralPath $src)) { continue }
        $dest = Join-Path $base $name
        if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $base | Out-Null }
        if (-not $DryRun -and (Test-Path -LiteralPath $dest) -and -not $NoBackup) {
            $bak = '{0}.bak.{1}' -f $dest, $TheStamp
            Copy-Item -LiteralPath $dest -Destination $bak -Recurse -Force
            Write-Log ("backed up " + $dest + " -> " + $bak)
        }
        Write-Log ("restore vicinae/" + $name + " -> " + $dest)
        if (-not $DryRun) { Copy-Tree -Source $src -Destination $dest }
    }
}

function Restore-Atuin {
    param([string] $StageRoot, [string] $TheStamp)

    $atuinHome = Join-Path $env:USERPROFILE '.atuin'
    $srcRoot = Join-Path $StageRoot 'atuin'
    if (-not (Test-Path -LiteralPath $srcRoot)) {
        if ($DryRun) {
            Write-Log 'DRYRUN would restore Atuin config/data from the downloaded snapshot'
            return
        }
        throw 'Downloaded snapshot has no atuin folder; cannot restore Atuin.'
    }
    if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $atuinHome | Out-Null }

    foreach ($name in @('config.toml', 'server.toml')) {
        $src = Join-Path $srcRoot $name
        if (-not (Test-Path -LiteralPath $src)) { continue }
        $dest = Join-Path $atuinHome $name
        if (-not $DryRun -and (Test-Path -LiteralPath $dest) -and -not $NoBackup) {
            $bak = '{0}.bak.{1}' -f $dest, $TheStamp
            Copy-Item -LiteralPath $dest -Destination $bak -Force
            Write-Log ("backed up " + $dest + " -> " + $bak)
        }
        Write-Log ("restore atuin/" + $name + " -> " + $dest)
        if (-not $DryRun) { Copy-Item -LiteralPath $src -Destination $dest -Force }
    }

    $srcData = Join-Path $srcRoot 'data'
    if (-not (Test-Path -LiteralPath $srcData)) { return }
    $destData = Join-Path $atuinHome 'data'
    if (-not $DryRun) {
        New-Item -ItemType Directory -Force -Path $destData | Out-Null
        if ((Test-Path -LiteralPath $destData) -and -not $NoBackup) {
            $bak = '{0}.bak.{1}' -f $destData, $TheStamp
            Copy-Item -LiteralPath $destData -Destination $bak -Recurse -Force
            Write-Log ("backed up " + $destData + " -> " + $bak)
        }
        # Drop local journal sidecars first: replaying a stale WAL against the
        # restored databases would corrupt the history.
        $sidecars = @(Get-ChildItem -LiteralPath $destData -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like '*.db-wal' -or $_.Name -like '*.db-shm' })
        foreach ($sidecar in $sidecars) {
            Remove-Item -LiteralPath $sidecar.FullName -Force
            Write-Log ("removed stale SQLite sidecar: " + $sidecar.FullName)
        }
    }
    Write-Log ("restore atuin/data -> " + $destData)
    if (-not $DryRun) { Copy-Tree -Source $srcData -Destination $destData }
    Write-Warn 'Close other shells with active Atuin sessions before using the restored history.'
}

function Get-PearDesktopTargets {
    # Same scope/product matrix as cleanup-before-shutdown.ps1, so each staged
    # folder goes back to the directory it came from.
    $targets = @()
    foreach ($scope in @(
        @{ Name = 'roaming'; Path = $env:APPDATA },
        @{ Name = 'local'; Path = $env:LOCALAPPDATA }
    )) {
        if (-not $scope.Path) { continue }
        foreach ($app in @('YouTube Music', 'Pear Desktop')) {
            $targets += [pscustomobject]@{
                Scope = $scope.Name
                App   = $app
                Path  = (Join-Path $scope.Path $app)
            }
        }
    }
    return @($targets)
}

function Restore-PearDesktop {
    param([string] $StageRoot, [string] $TheStamp)

    $srcRoot = Join-Path $StageRoot 'pear'
    if (-not (Test-Path -LiteralPath $srcRoot)) {
        if ($DryRun) {
            Write-Log 'DRYRUN would restore Pear Desktop userData from the downloaded snapshot'
            return
        }
        throw 'Downloaded snapshot has no pear folder; cannot restore Pear Desktop.'
    }

    $restored = 0
    foreach ($target in @(Get-PearDesktopTargets)) {
        $src = Join-Path (Join-Path $srcRoot $target.Scope) $target.App
        if (-not (Test-Path -LiteralPath $src)) { continue }
        $restored++
        Write-Log ("restore pear/" + $target.Scope + "/" + $target.App + " -> " + $target.Path)
        if ($DryRun) { continue }
        if ((Test-Path -LiteralPath $target.Path) -and -not $NoBackup) {
            $bak = '{0}.bak.{1}' -f $target.Path, $TheStamp
            Copy-Item -LiteralPath $target.Path -Destination $bak -Recurse -Force
            Write-Log ("backed up " + $target.Path + " -> " + $bak)
        }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target.Path) | Out-Null
        Copy-Tree -Source $src -Destination $target.Path
        # A copied Chromium lockfile points at a dead process and can block startup.
        $lock = Join-Path $target.Path 'lockfile'
        if (Test-Path -LiteralPath $lock) {
            Remove-Item -LiteralPath $lock -Force
            Write-Log ("removed stale " + $lock)
        }
    }
    if ($restored -eq 0) {
        Write-Warn 'Pear Desktop folders are missing from the snapshot; nothing restored.'
    }
}

function Get-OpenCodePaths {
    # Mirror cleanup-before-shutdown.ps1: prefer the CLI's own paths (XDG-aware).
    $homeDir = $env:USERPROFILE
    $paths = [ordered] @{
        Config       = Join-Path $homeDir '.config\opencode'
        Data         = Join-Path $homeDir '.local\share\opencode'
        State        = Join-Path $homeDir '.local\state\opencode'
        LocalAppData = Join-Path $env:LOCALAPPDATA 'opencode'
    }
    $opencode = Get-Command opencode -ErrorAction SilentlyContinue
    if ($opencode) {
        try {
            $out = & cmd /c ('"{0}" debug paths 2>nul' -f $opencode.Source)
            foreach ($line in @($out)) {
                if ($line -match '^(config|data|state)\s+(.+)$') {
                    $value = $Matches[2].Trim()
                    if (-not $value) { continue }
                    switch ($Matches[1]) {
                        'config' { $paths.Config = $value }
                        'data'   { $paths.Data = $value }
                        'state'  { $paths.State = $value }
                    }
                }
            }
        } catch {
            Write-Warn ('could not read opencode paths, using defaults: ' + $_.Exception.Message)
        }
    }
    return [pscustomobject] $paths
}

function Restore-OpenCode {
    param([string] $StageRoot, [string] $TheStamp)

    $paths = Get-OpenCodePaths
    $srcRoot = Join-Path $StageRoot 'opencode'
    if (-not (Test-Path -LiteralPath $srcRoot)) {
        if ($DryRun) {
            Write-Log 'DRYRUN would restore OpenCode config/state and credentials'
            return
        }
        throw 'Downloaded snapshot has no opencode folder; cannot restore OpenCode.'
    }

    foreach ($pair in @(
        @{ Name = 'config'; Target = $paths.Config },
        @{ Name = 'state'; Target = $paths.State }
    )) {
        $src = Join-Path $srcRoot $pair.Name
        if (-not (Test-Path -LiteralPath $src)) { continue }
        Write-Log ("restore opencode/" + $pair.Name + " -> " + $pair.Target)
        if ($DryRun) { continue }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $pair.Target) | Out-Null
        if ((Test-Path -LiteralPath $pair.Target) -and -not $NoBackup) {
            $bak = '{0}.bak.{1}' -f $pair.Target, $TheStamp
            Copy-Item -LiteralPath $pair.Target -Destination $bak -Recurse -Force
            Write-Log ("backed up " + $pair.Target + " -> " + $bak)
        }
        New-Item -ItemType Directory -Force -Path $pair.Target | Out-Null
        Copy-Tree -Source $src -Destination $pair.Target
    }

    $authRoot = Join-Path $srcRoot 'auth'
    $exportFile = Join-Path $authRoot 'export.json'
    if (Test-Path -LiteralPath $exportFile) {
        $opencode = Get-Command opencode -ErrorAction SilentlyContinue
        if (-not $opencode) {
            Write-Warn 'opencode CLI not found - credentials were not imported; run .\core\restore-backup.ps1 -Only opencode again after installing it.'
        } elseif ($DryRun) {
            Write-Log 'DRYRUN would run: opencode auth import <snapshot auth/export.json>'
        } else {
            Write-Log 'importing opencode credentials'
            $imported = $false
            foreach ($prefix in @('', '--standalone ')) {
                & cmd /c ('"{0}" {1}auth import "{2}" 2>nul' -f $opencode.Source, $prefix, $exportFile) | Out-Null
                if ($LASTEXITCODE -eq 0) { $imported = $true; break }
            }
            if (-not $imported) {
                throw 'opencode auth import failed (run it manually with the snapshot auth/export.json).'
            }
            Write-Log 'opencode credentials imported'
        }
    }

    # v1 builds kept auth.json under config/data instead of the current database.
    foreach ($legacy in @(
        @{ Name = 'config-auth.json'; Target = (Join-Path $paths.Config 'auth.json') },
        @{ Name = 'data-auth.json'; Target = (Join-Path $paths.Data 'auth.json') },
        @{ Name = 'localappdata-auth.json'; Target = (Join-Path $paths.LocalAppData 'auth.json') }
    )) {
        $src = Join-Path $authRoot $legacy.Name
        if (-not (Test-Path -LiteralPath $src)) { continue }
        Write-Log ("restore opencode/auth/" + $legacy.Name + " -> " + $legacy.Target)
        if ($DryRun) { continue }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $legacy.Target) | Out-Null
        Copy-Item -LiteralPath $src -Destination $legacy.Target -Force
    }
}

function Start-VicinaeServer {
    $roots = @($env:SCOOP, (Join-Path $env:USERPROFILE 'scoop'), (Join-Path $env:ProgramData 'scoop'))
    $server = $roots | Where-Object { $_ } | ForEach-Object {
        Join-Path $_ 'apps\vicinae\current\bin\vicinae-server.exe'
    } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $server) {
        Write-Warn 'vicinae-server.exe not found; start it with .\apps\vicinae\enable-autostart.ps1 -Restart'
        return
    }
    foreach ($name in @('HERDR_ENV', 'HERDR_PANE_ID', 'HERDR_TAB_ID', 'HERDR_WORKSPACE_ID', 'HERDR_SOCKET_PATH', 'HERDR_BIN_PATH')) {
        Remove-Item "Env:$name" -ErrorAction SilentlyContinue
    }
    Start-Process -FilePath $server -WindowStyle Hidden
    Start-Sleep -Seconds 2
    Write-Log 'vicinae-server restarted'
}

# --- set up logging ------------------------------------------------------------
$restoreRoot = if ($StagingDir) { $StagingDir } else { Join-Path $env:LOCALAPPDATA 'skoop\restore' }
$runStamp = Get-Date -Format 'yyyy-MM-dd-HHmmss'
$script:LogPath = if ($LogPath) { $LogPath } else { Join-Path $restoreRoot ('restore-' + $runStamp + '.log') }
$logParent = Split-Path -Parent $script:LogPath
if (-not $logParent) { $logParent = '.' }
New-Item -ItemType Directory -Force -Path $logParent | Out-Null
[System.IO.File]::WriteAllText($script:LogPath, '', (New-Object System.Text.UTF8Encoding($false)))
Write-Log ("log file: " + $script:LogPath)

foreach ($tool in @('ssh', 'scp')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "$tool is not installed (enable Windows OpenSSH Client)."
    }
}

$sshUser = Resolve-SshUser
# LogLevel=ERROR keeps OpenSSH's "Permanently added ..." INFO notice off stderr,
# so `2>&1` cannot mix it into stdout values such as the remote home path.
$sshArgs = @('-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=10', '-o', 'LogLevel=ERROR', ($sshUser + '@' + $TargetHost))
$peer = $sshUser + '@' + $TargetHost

Write-Log ("ssh command: ssh " + ($sshArgs -join ' ') + ' printf %s "$HOME"')
$homeOutput = & ssh @sshArgs 'printf %s "$HOME"' 2>&1
$homeLines = @(Remove-SshDiagnostics $homeOutput)
foreach ($line in $homeLines) { Write-Log ("ssh: " + $line) }
if ($LASTEXITCODE -ne 0) {
    throw ("ssh to " + $peer + " failed: " + ($homeLines | Out-String))
}
$remoteHome = ($homeLines | Select-Object -Last 1)
if (-not $remoteHome) { throw 'Could not determine the remote home directory.' }
Write-Log ("remote home: " + $remoteHome)

# --- discover the newest snapshot for each app --------------------------------
if ($Stamp) {
    $ffStamps = @($Stamp)
    $vcStamps = @($Stamp)
    $atStamps = @($Stamp)
    $peStamps = @($Stamp)
    $ocStamps = @($Stamp)
    $ssStamps = @($Stamp)
    $rsStamps = @($Stamp)
} else {
    $ffStamps = @(Get-LatestStamps -SshArgs $sshArgs -Path $FirefoxRemotePath)
    $vcStamps = @(Get-LatestStamps -SshArgs $sshArgs -Path $VicinaeRemotePath)
    $atStamps = @(Get-LatestStamps -SshArgs $sshArgs -Path $AtuinRemotePath)
    $peStamps = @(Get-LatestStamps -SshArgs $sshArgs -Path $PearRemotePath)
    $ocStamps = @(Get-LatestStamps -SshArgs $sshArgs -Path $OpenCodeRemotePath)
    $ssStamps = @(Get-LatestStamps -SshArgs $sshArgs -Path $SshRemotePath)
    $rsStamps = @(Get-LatestStamps -SshArgs $sshArgs -Path $ReposRemotePath)
}
$ffStamp = if ($ffStamps.Count) { $ffStamps[0] } else { $null }
$vcStamp = if ($vcStamps.Count) { $vcStamps[0] } else { $null }
$atStamp = if ($atStamps.Count) { $atStamps[0] } else { $null }
$peStamp = if ($peStamps.Count) { $peStamps[0] } else { $null }
$ocStamp = if ($ocStamps.Count) { $ocStamps[0] } else { $null }
$ssStamp = if ($ssStamps.Count) { $ssStamps[0] } else { $null }
$rsStamp = if ($rsStamps.Count) { $rsStamps[0] } else { $null }

if ($List) {
    Write-Log ("Firefox        latest: " + $(if ($ffStamp) { $ffStamp } else { '(none)' }) + "  (" + $FirefoxRemotePath + ")")
    Write-Log ("Vicinae        latest: " + $(if ($vcStamp) { $vcStamp } else { '(none)' }) + "  (" + $VicinaeRemotePath + ")")
    Write-Log ("Atuin          latest: " + $(if ($atStamp) { $atStamp } else { '(none)' }) + "  (" + $AtuinRemotePath + ")")
    Write-Log ("Pear Desktop   latest: " + $(if ($peStamp) { $peStamp } else { '(none)' }) + "  (" + $PearRemotePath + ")")
    Write-Log ("OpenCode       latest: " + $(if ($ocStamp) { $ocStamp } else { '(none)' }) + "  (" + $OpenCodeRemotePath + ")")
    Write-Log ("SSH key        latest: " + $(if ($ssStamp) { $ssStamp } else { '(none)' }) + "  (" + $SshRemotePath + ")")
    Write-Log ("Repos list     latest: " + $(if ($rsStamp) { $rsStamp } else { '(none)' }) + "  (" + $ReposRemotePath + ")")
    if (-not $ffStamp -and -not $vcStamp -and -not $atStamp -and -not $peStamp -and -not $ocStamp -and -not $ssStamp -and -not $rsStamp) { Write-Warn 'No snapshots found; check -TargetHost / -User / remote paths.' }
    return
}

$doFirefox = $Only -contains 'firefox'
$doVicinae = $Only -contains 'vicinae'
$doAtuin = $Only -contains 'atuin'
$doPear = $Only -contains 'pear'
$doOpenCode = $Only -contains 'opencode'
$doSsh = $Only -contains 'ssh'
$doRepos = $Only -contains 'repos'
if ($doFirefox -and -not $ffStamp) {
    Write-Warn 'No Firefox snapshot found; skipping Firefox.'
    $doFirefox = $false
}
if ($doVicinae -and -not $vcStamp) {
    Write-Warn 'No Vicinae snapshot found; skipping Vicinae.'
    $doVicinae = $false
}
if ($doAtuin -and -not $atStamp) {
    Write-Warn 'No Atuin snapshot found; skipping Atuin.'
    $doAtuin = $false
}
if ($doPear -and -not $peStamp) {
    Write-Warn 'No Pear Desktop snapshot found; skipping Pear Desktop.'
    $doPear = $false
}
if ($doOpenCode -and -not $ocStamp) {
    Write-Warn 'No OpenCode snapshot found; skipping OpenCode.'
    $doOpenCode = $false
}
if ($doSsh -and -not $ssStamp) {
    Write-Warn 'No SSH key snapshot found; skipping SSH.'
    $doSsh = $false
}
if ($doRepos -and -not $rsStamp) {
    Write-Warn 'No repos-list snapshot found; skipping repos.'
    $doRepos = $false
}
if (-not $doFirefox -and -not $doVicinae -and -not $doAtuin -and -not $doPear -and -not $doOpenCode -and -not $doSsh -and -not $doRepos) {
    throw 'Nothing to restore. Run -List to see the available snapshots.'
}

$ffRunning = @(Get-Process -Name firefox -ErrorAction SilentlyContinue)
if ($doFirefox -and $ffRunning.Count -gt 0 -and -not $DryRun) {
    throw 'Firefox is running. Close it before restoring its profile.'
}
$vicRunning = @(Get-Process -Name vicinae-server -ErrorAction SilentlyContinue)
if ($doVicinae -and $vicRunning.Count -gt 0 -and -not $DryRun) {
    Write-Log 'Stopping vicinae-server for a clean restore'
    $vicRunning | Stop-Process -Force
    Start-Sleep -Seconds 2
}
$pearRunning = @(Get-Process -Name 'YouTube Music', 'Pear Desktop' -ErrorAction SilentlyContinue)
if ($doPear -and $pearRunning.Count -gt 0 -and -not $DryRun) {
    Write-Log 'Stopping Pear Desktop for a clean restore'
    $pearRunning | Stop-Process -Force
    Start-Sleep -Seconds 2
}

$restoreStamp = @($ffStamp, $vcStamp, $atStamp, $peStamp, $ocStamp, $ssStamp, $rsStamp) | Where-Object { $_ } | Select-Object -First 1
$stage = Join-Path $restoreRoot $restoreStamp
if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $stage | Out-Null }

try {
    if ($doFirefox) {
        $remoteFolder = Get-SnapshotRemotePath -BasePath $FirefoxRemotePath -FolderName 'firefox' -TheStamp $ffStamp
        Write-Log ("restoring Firefox from " + $peer + ':' + $remoteFolder)
        if (-not $DryRun) {
            # Skip browser caches: they are not part of the usable profile and
            # contain paths longer than Windows' MAX_PATH (scp cannot create them).
            $firefoxExcludes = @('cache', 'cache2', 'startupCache', 'offlineCache', 'thumbnails', 'jumpListCache')
            Save-Snapshot -RemoteFolder $remoteFolder -StageRoot $stage -FolderName 'firefox' -Excludes $firefoxExcludes
        }
        if (-not $DryRun -and -not (Test-Path -LiteralPath (Join-Path $stage 'firefox\profiles.ini'))) {
            throw 'Downloaded Firefox snapshot has no profiles.ini.'
        }
        Restore-Firefox -StageRoot $stage -TheStamp $ffStamp
    }

    if ($doVicinae) {
        $remoteFolder = Get-SnapshotRemotePath -BasePath $VicinaeRemotePath -FolderName 'vicinae' -TheStamp $vcStamp
        Write-Log ("restoring Vicinae from " + $peer + ':' + $remoteFolder)
        if (-not $DryRun) { Save-Snapshot -RemoteFolder $remoteFolder -StageRoot $stage -FolderName 'vicinae' }
        $vcFiles = if ($DryRun) { @() } else { @(Get-ChildItem -LiteralPath (Join-Path $stage 'vicinae') -Recurse -File -ErrorAction SilentlyContinue) }
        if (-not $DryRun -and $vcFiles.Count -lt 1) {
            throw 'Downloaded Vicinae snapshot is empty.'
        }
        Restore-Vicinae -StageRoot $stage -TheStamp $vcStamp
    }

    if ($doAtuin) {
        $remoteFolder = Get-SnapshotRemotePath -BasePath $AtuinRemotePath -FolderName 'atuin' -TheStamp $atStamp
        Write-Log ("restoring Atuin from " + $peer + ':' + $remoteFolder)
        if (-not $DryRun) { Save-Snapshot -RemoteFolder $remoteFolder -StageRoot $stage -FolderName 'atuin' }
        if (-not $DryRun -and -not (Test-Path -LiteralPath (Join-Path $stage 'atuin\data\history.db'))) {
            throw 'Downloaded Atuin snapshot has no data/history.db.'
        }
        Restore-Atuin -StageRoot $stage -TheStamp $atStamp
    }

    if ($doPear) {
        $remoteFolder = Get-SnapshotRemotePath -BasePath $PearRemotePath -FolderName 'pear' -TheStamp $peStamp
        Write-Log ("restoring Pear Desktop from " + $peer + ':' + $remoteFolder)
        if (-not $DryRun) { Save-Snapshot -RemoteFolder $remoteFolder -StageRoot $stage -FolderName 'pear' }
        $peFiles = if ($DryRun) { @() } else { @(Get-ChildItem -LiteralPath (Join-Path $stage 'pear') -Recurse -File -ErrorAction SilentlyContinue) }
        if (-not $DryRun -and $peFiles.Count -lt 1) {
            throw 'Downloaded Pear Desktop snapshot is empty.'
        }
        Restore-PearDesktop -StageRoot $stage -TheStamp $peStamp
    }

    if ($doOpenCode) {
        $remoteFolder = Get-SnapshotRemotePath -BasePath $OpenCodeRemotePath -FolderName 'opencode' -TheStamp $ocStamp
        Write-Log ("restoring OpenCode from " + $peer + ':' + $remoteFolder)
        if (-not $DryRun) { Save-Snapshot -RemoteFolder $remoteFolder -StageRoot $stage -FolderName 'opencode' }
        $ocFiles = if ($DryRun) { @() } else { @(Get-ChildItem -LiteralPath (Join-Path $stage 'opencode') -Recurse -File -ErrorAction SilentlyContinue) }
        if (-not $DryRun -and $ocFiles.Count -lt 1) {
            throw 'Downloaded OpenCode snapshot is empty.'
        }
        Restore-OpenCode -StageRoot $stage -TheStamp $ocStamp
    }

    if ($doSsh) {
        $remoteFolder = Get-SnapshotRemotePath -BasePath $SshRemotePath -FolderName 'ssh' -TheStamp $ssStamp
        Write-Log ("restoring SSH key from " + $peer + ':' + $remoteFolder)
        if (-not $DryRun) { Save-Snapshot -RemoteFolder $remoteFolder -StageRoot $stage -FolderName 'ssh' }
        $ssFiles = if ($DryRun) { @() } else { @(Get-ChildItem -LiteralPath (Join-Path $stage 'ssh') -Recurse -File -ErrorAction SilentlyContinue) }
        if (-not $DryRun -and $ssFiles.Count -lt 1) {
            throw 'Downloaded SSH snapshot is empty.'
        }
        Restore-Ssh -StageRoot $stage -TheStamp $ssStamp
    }

    if ($doRepos) {
        $remoteFolder = Get-SnapshotRemotePath -BasePath $ReposRemotePath -FolderName 'repos' -TheStamp $rsStamp
        Write-Log ("restoring repos list from " + $peer + ':' + $remoteFolder)
        if (-not $DryRun) { Save-Snapshot -RemoteFolder $remoteFolder -StageRoot $stage -FolderName 'repos' }
        Restore-Repos -StageRoot $stage -TheStamp $rsStamp
    }

    if ($DryRun) {
        Write-Log 'DRYRUN complete; nothing was changed'
    } else {
        Write-Log 'restore complete'
        Write-Log ("log saved: " + $script:LogPath)
    }
} finally {
    if ($doVicinae -and $vicRunning.Count -gt 0 -and -not $DryRun -and -not $NoRestart) {
        Start-VicinaeServer
    }
    if (-not $DryRun -and (Test-Path -LiteralPath $stage)) {
        Remove-Item -LiteralPath $stage -Recurse -Force
        Write-Log ("removed staging: " + $stage)
    }
}
