#Requires -Version 5.1
<#
.SYNOPSIS
    Restore the latest Firefox, Vicinae and/or Atuin snapshot from acer-ubuntu onto a fresh machine.

.DESCRIPTION
    Companion to core/cleanup-before-shutdown.ps1. The backup keeps one folder per
    app on the tailnet host (~/skoop-backups/firefox/<timestamp>/firefox,
    ~/skoop-backups/vicinae/<timestamp>/vicinae and
    ~/skoop-backups/atuin/<timestamp>/atuin); this script picks the newest timestamp
    for each app independently, downloads it with scp and merges it into place:

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

    Nothing is uploaded or changed on the remote host. -List prints the newest
    snapshot for each app, -Stamp pins all apps to one timestamp, -Only narrows
    the restore, and -DryRun prints the plan without changing anything. -NoBackup
    overwrites local config without keeping a .bak copy; -NoRestart leaves a
    stopped Vicinae server stopped. After a fresh machine's first install you can
    re-run .\apps\vicinae\configure.ps1 -Restart to reapply the managed keybinds
    if you changed them outside the repo.

.PARAMETER User
    SSH user on acer-ubuntu. Defaults to $env:SKOOP_BACKUP_USER; prompts when omitted.

.PARAMETER TargetHost
    Tailnet hostname/IP of the backup machine (default 'acer-ubuntu').

.PARAMETER FirefoxRemotePath
    Firefox snapshot parent on the remote host (default 'skoop-backups/firefox').

.PARAMETER VicinaeRemotePath
    Vicinae snapshot parent on the remote host (default 'skoop-backups/vicinae').

.PARAMETER AtuinRemotePath
    Atuin snapshot parent on the remote host (default 'skoop-backups/atuin').

.PARAMETER Stamp
    Use this timestamp for all apps instead of each app's latest. Fails if a
    requested app has no snapshot with that timestamp.

.PARAMETER Only
    Restrict the restore to firefox, vicinae and/or atuin (default: all three).

.PARAMETER List
    Print the newest snapshot timestamp per app and exit.

.PARAMETER DryRun
    Show what would be downloaded and restored; do not change any local files.

.PARAMETER NoBackup
    Overwrite profiles.ini / installs.ini, Vicinae folders and Atuin config/data
    without a .bak copy.

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
#>
[CmdletBinding()]
param(
    [string] $User = "$env:SKOOP_BACKUP_USER",
    [string] $TargetHost = 'acer-ubuntu',
    [string] $FirefoxRemotePath = 'skoop-backups/firefox',
    [string] $VicinaeRemotePath = 'skoop-backups/vicinae',
    [string] $AtuinRemotePath = 'skoop-backups/atuin',
    [string] $Stamp,
    [ValidateSet('firefox', 'vicinae', 'atuin')]
    [string[]] $Only = @('firefox', 'vicinae', 'atuin'),
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
    if ($User) { return $User.Trim() }
    if (-not [Environment]::UserInteractive) {
        throw 'SSH user is required in a non-interactive shell. Re-run with -User <username>.'
    }
    $answer = Read-Host ("SSH user for " + $TargetHost)
    if (-not $answer -or -not $answer.Trim()) {
        throw 'SSH user cannot be empty.'
    }
    return $answer.Trim()
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
        $copyOutput = (& robocopy $Source $Destination /E /COPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NP 2>&1 | Out-String)
        $code = $LASTEXITCODE
        if ($code -ge 16) { throw "robocopy failed with code $code for $Source" }
        if ($code -ge 8) { Write-Warn ("robocopy skipped some files in " + $Source) }
    } else {
        Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
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
    param([string] $RemoteFolder, [string] $StageRoot, [string] $FolderName)

    # Drop a stale target from an earlier interrupted run so the download is clean.
    $target = Join-Path $StageRoot $FolderName
    if ((Test-Path -LiteralPath $target)) {
        Remove-Item -LiteralPath $target -Recurse -Force
    }
    $scpArgs = @('-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=10', '-r', ($peer + ':' + $RemoteFolder), $StageRoot)
    Write-Log ("scp command: scp " + ($scpArgs -join ' '))
    & scp @scpArgs 2>&1 | ForEach-Object { Write-Log ("scp: " + $_.ToString().Trim()) }
    if ($LASTEXITCODE -ne 0) {
        throw "scp download failed for $RemoteFolder"
    }
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
$sshArgs = @('-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=10', ($sshUser + '@' + $TargetHost))
$peer = $sshUser + '@' + $TargetHost

Write-Log ("ssh command: ssh " + ($sshArgs -join ' ') + ' printf %s "$HOME"')
$homeOutput = & ssh @sshArgs 'printf %s "$HOME"' 2>&1
foreach ($line in $homeOutput) { Write-Log ("ssh: " + $line.ToString().Trim()) }
if ($LASTEXITCODE -ne 0) {
    throw ("ssh to " + $peer + " failed: " + ($homeOutput | Out-String))
}
$remoteHome = ($homeOutput | Select-Object -Last 1).ToString().Trim()
if (-not $remoteHome) { throw 'Could not determine the remote home directory.' }
Write-Log ("remote home: " + $remoteHome)

# --- discover the newest snapshot for each app --------------------------------
if ($Stamp) {
    $ffStamps = @($Stamp)
    $vcStamps = @($Stamp)
    $atStamps = @($Stamp)
} else {
    $ffStamps = @(Get-LatestStamps -SshArgs $sshArgs -Path $FirefoxRemotePath)
    $vcStamps = @(Get-LatestStamps -SshArgs $sshArgs -Path $VicinaeRemotePath)
    $atStamps = @(Get-LatestStamps -SshArgs $sshArgs -Path $AtuinRemotePath)
}
$ffStamp = if ($ffStamps.Count) { $ffStamps[0] } else { $null }
$vcStamp = if ($vcStamps.Count) { $vcStamps[0] } else { $null }
$atStamp = if ($atStamps.Count) { $atStamps[0] } else { $null }

if ($List) {
    Write-Log ("Firefox  latest: " + $(if ($ffStamp) { $ffStamp } else { '(none)' }) + "  (" + $FirefoxRemotePath + ")")
    Write-Log ("Vicinae  latest: " + $(if ($vcStamp) { $vcStamp } else { '(none)' }) + "  (" + $VicinaeRemotePath + ")")
    Write-Log ("Atuin    latest: " + $(if ($atStamp) { $atStamp } else { '(none)' }) + "  (" + $AtuinRemotePath + ")")
    if (-not $ffStamp -and -not $vcStamp -and -not $atStamp) { Write-Warn 'No snapshots found; check -TargetHost / -User / remote paths.' }
    return
}

$doFirefox = $Only -contains 'firefox'
$doVicinae = $Only -contains 'vicinae'
$doAtuin = $Only -contains 'atuin'
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
if (-not $doFirefox -and -not $doVicinae -and -not $doAtuin) {
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

$restoreStamp = @($ffStamp, $vcStamp, $atStamp) | Where-Object { $_ } | Select-Object -First 1
$stage = Join-Path $restoreRoot $restoreStamp
if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $stage | Out-Null }

try {
    if ($doFirefox) {
        $remoteFolder = Get-SnapshotRemotePath -BasePath $FirefoxRemotePath -FolderName 'firefox' -TheStamp $ffStamp
        Write-Log ("restoring Firefox from " + $peer + ':' + $remoteFolder)
        if (-not $DryRun) { Save-Snapshot -RemoteFolder $remoteFolder -StageRoot $stage -FolderName 'firefox' }
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
