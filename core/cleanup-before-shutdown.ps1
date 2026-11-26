<#
.SYNOPSIS
    Back up Firefox profiles to acer-ubuntu over Tailscale SSH, then remove local auth state.

.DESCRIPTION
    Intended for public/shared PCs: run it before turning the machine off to leave
    no signed-in accounts behind. It copies every Firefox profile found in
    profiles.ini into a local staging folder, uploads it to the tailnet machine
    acer-ubuntu with scp, verifies the remote copy over ssh, and only then removes
    local credentials:

      - gh auth logout for github.com (plus the hosts.yml file as a fallback)
      - git's GitHub credential helper/username and ~/.git-credentials
      - GitHub entries in Windows Credential Manager
      - SSH private keys under ~/.ssh and the temporary Herdr key folder
      - Firefox logins.json / key4.db from the backed-up profiles

    The SSH user is asked for at runtime (pass -User to skip the prompt). Backups
    land in ~/<RemotePath>/<timestamp>/firefox on acer-ubuntu. Nothing is deleted
    until the remote copy has been verified; if verification fails, the staging
    copy is kept and the script stops. -DryRun previews without changing anything.
    The script never shuts the PC down.

.PARAMETER User
    SSH user on acer-ubuntu. When omitted, the script prompts for it.

.PARAMETER TargetHost
    Tailnet hostname/IP of the backup machine (default 'acer-ubuntu').

.PARAMETER RemotePath
    Destination folder relative to the remote home (default 'skoop-backups/firefox').

.PARAMETER StagingDir
    Local folder used to assemble the backup before upload. Defaults to
    %LOCALAPPDATA%\skoop\backup and is removed after a verified upload.

.PARAMETER LogPath
    File to mirror all log output into. Defaults to
    <StagingDir>\cleanup-<timestamp>.log so a failed upload can be debugged.

.PARAMETER SkipBackup
    Skip the Firefox backup. Requires -Force, so an auth wipe cannot happen
    by accident without a verified copy.

.PARAMETER KeepFirefoxLogins
    Keep Firefox's saved logins/key database after the backup (opt-out).

.PARAMETER BackupOnly
    Upload the backup and stop; do not remove any auth state. Useful for testing.

.PARAMETER DryRun
    Print what would happen; do not copy, upload or delete anything.

.PARAMETER Force
    Allow -SkipBackup.

.EXAMPLE
    .\core\cleanup-before-shutdown.ps1 -DryRun

.EXAMPLE
    .\core\cleanup-before-shutdown.ps1 -User khoi0941
#>
[CmdletBinding()]
param(
    [string] $User,
    [string] $TargetHost = 'acer-ubuntu',
    [string] $RemotePath = 'skoop-backups/firefox',
    [string] $StagingDir,
    [string] $LogPath,
    [switch] $SkipBackup,
    [switch] $KeepFirefoxLogins,
    [switch] $BackupOnly,
    [switch] $DryRun,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'

$script:LogPath = $null

function Write-Log {
    param([string] $Message)

    $line = '[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $Message
    Write-Host $line
    if ($script:LogPath) {
        try {
            Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
        } catch {
            Write-Host ("[cleanup] WARNING: could not write log file: " + $_.Exception.Message)
        }
    }
}

function Resolve-SshUser {
    if ($User) { return $User.Trim() }
    if ($DryRun) { return 'USER' }
    if (-not [Environment]::UserInteractive) {
        throw 'SSH user is required in a non-interactive shell. Re-run with -User <username>.'
    }
    $answer = Read-Host ("SSH user for " + $TargetHost)
    if (-not $answer -or -not $answer.Trim()) {
        throw 'SSH user cannot be empty.'
    }
    return $answer.Trim()
}

function Get-FirefoxProfilePaths {
    $ini = Join-Path $env:APPDATA 'Mozilla\Firefox\profiles.ini'
    if (-not (Test-Path -LiteralPath $ini)) {
        Write-Log 'profiles.ini not found - no Firefox profiles to back up'
        return @()
    }

    $base = Split-Path -Parent $ini
    $sections = @()
    $current = $null
    foreach ($line in (Get-Content -LiteralPath $ini)) {
        if ($line -match '^\[(.+)\]') {
            if ($current) { $sections += $current }
            $current = @{ Section = $Matches[1] }
        } elseif ($current -and $line -match '^([^=]+)=(.*)$') {
            $current[$Matches[1].Trim()] = $Matches[2].Trim()
        }
    }
    if ($current) { $sections += $current }

    $paths = @()
    foreach ($section in $sections) {
        if (-not $section.ContainsKey('Path')) { continue }
        if ($section.ContainsKey('IsRelative') -and $section['IsRelative'] -eq '1') {
            $path = Join-Path $base $section['Path']
        } else {
            $path = $section['Path']
        }
        if ((Test-Path -LiteralPath $path) -and (Test-Path -LiteralPath (Join-Path $path 'prefs.js'))) {
            $paths += $path
        }
    }
    return @($paths | Select-Object -Unique)
}

function Copy-Profile {
    param([string] $Source, [string] $Destination)

    if (Get-Command robocopy -ErrorAction SilentlyContinue) {
        # Firefox keeps parent.lock and some WAL files open; a few skips are fine
        # as long as the critical profile files make it into the backup.
        Write-Log ("robocopy: " + $Source + " -> " + $Destination)
        $copyOutput = (& robocopy $Source $Destination /E /COPY:DAT /R:1 /W:1 /XF parent.lock /NFL /NDL /NJH /NP 2>&1 | Out-String)
        $code = $LASTEXITCODE
        $copyLines = @($copyOutput -split '\r?\n' | Where-Object { $_.Trim() })
        foreach ($copyLine in ($copyLines | Select-Object -Last 20)) {
            Write-Log ("robocopy: " + $copyLine.Trim())
        }
        if ($code -ge 16) {
            throw "robocopy failed with code $code for $Source"
        }
        if ($code -ge 8) {
            Write-Log ("warning: robocopy skipped some locked files in " + $Source)
        }
    } else {
        Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force -ErrorAction SilentlyContinue
    }

    foreach ($required in @('prefs.js', 'places.sqlite')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Destination $required))) {
            throw "Backup verification failed for ${Source}: missing $required"
        }
    }
}

function Invoke-RemoteBackup {
    param([string] $Source, [string] $Stamp, [string] $SshUser)

    foreach ($tool in @('ssh', 'scp')) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            throw "$tool is not installed (enable Windows OpenSSH Client)."
        }
    }

    $sshArgs = @('-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=10', ($SshUser + '@' + $TargetHost))
    $peer = $SshUser + '@' + $TargetHost

    Write-Log ("ssh command: ssh " + ($sshArgs -join ' ') + ' printf %s "$HOME"')
    $homeOutput = & ssh @sshArgs 'printf %s "$HOME"' 2>&1
    foreach ($line in $homeOutput) { Write-Log ("ssh: " + $line.ToString().Trim()) }
    if ($LASTEXITCODE -ne 0) {
        throw ("ssh to " + $peer + " failed: " + ($homeOutput | Out-String))
    }
    $remoteHome = ($homeOutput | Select-Object -Last 1).ToString().Trim()
    if (-not $remoteHome) {
        throw 'Could not determine the remote home directory.'
    }

    $remoteDir = $remoteHome.TrimEnd('/') + '/' + $RemotePath.Trim('/') + '/' + $Stamp
    $scpArgs = @('-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=10', '-r', $Source, ($peer + ':' + $remoteDir + '/'))

    Write-Log ("remote home: " + $remoteHome)
    Write-Log ("remote destination: " + $peer + ':' + $remoteDir)
    Write-Log ("ssh command: ssh " + ($sshArgs -join ' ') + " mkdir -p '" + $remoteDir + "'")
    & ssh @sshArgs ("mkdir -p '" + $remoteDir + "'") 2>&1 | ForEach-Object { Write-Log ("ssh: " + $_.ToString().Trim()) }
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not create the remote backup folder.'
    }

    $remoteHasTar = $false
    try {
        $tarCheck = & ssh @sshArgs 'command -v tar >/dev/null 2>&1; echo $?' 2>$null
        $remoteHasTar = (($tarCheck | Select-Object -Last 1).ToString().Trim() -eq '0')
    } catch { }

    if ((Get-Command tar -ErrorAction SilentlyContinue) -and $remoteHasTar) {
        # One compressed stream avoids per-file overhead (hundreds of small
        # profile files made scp -r take ~10 minutes over the tailnet).
        $sourceParent = Split-Path -Parent $Source
        $sourceLeaf = Split-Path -Leaf $Source
        $extractCmd = "tar -xzf - -C '" + $remoteDir + "'"
        $streamCmd = 'tar -czf - -C "' + $sourceParent + '" ' + $sourceLeaf +
            ' | ssh ' + ($sshArgs -join ' ') + ' "' + $extractCmd + '"'
        Write-Log ("stream command: " + $streamCmd)
        $streamOutput = (& cmd /c $streamCmd 2>&1 | Out-String)
        foreach ($line in ($streamOutput -split '\r?\n' | Where-Object { $_.Trim() } | Select-Object -Last 20)) {
            Write-Log ("tar/ssh: " + $line.Trim())
        }
        if ($LASTEXITCODE -ne 0) {
            throw 'tar-over-ssh upload failed.'
        }
    } else {
        Write-Log ("scp command: scp " + ($scpArgs -join ' '))
        & scp @scpArgs 2>&1 | ForEach-Object { Write-Log ("scp: " + $_.ToString().Trim()) }
        if ($LASTEXITCODE -ne 0) {
            throw 'scp upload failed.'
        }
    }

    # scp copies the whole 'firefox' staging folder, so profiles sit one level deeper.
    $verifyCmd = "d='" + $remoteDir + "/firefox'; p=`$(find `"`$d`" -name prefs.js -print -quit); n=`$(find `"`$d`" -type f | wc -l); if [ -n `"`$p`" ] && [ `"`$n`" -gt 0 ]; then echo `"`$n`"; else exit 1; fi"
    Write-Log ("verify command: ssh " + ($sshArgs -join ' ') + " " + $verifyCmd)
    $check = & ssh @sshArgs $verifyCmd 2>&1
    foreach ($line in $check) { Write-Log ("verify: " + $line.ToString().Trim()) }
    if ($LASTEXITCODE -ne 0) {
        throw 'Remote backup verification failed.'
    }
    $countLine = ($check | Select-Object -Last 1).ToString().Trim()
    $count = 0
    if (-not [int]::TryParse($countLine, [ref] $count) -or $count -lt 1) {
        throw 'Remote backup is empty or unreadable; refusing to remove any auth state.'
    }
    Write-Log ("upload verified: " + $count + " files at " + $peer + ':' + $remoteDir)
    return ($peer + ':' + $remoteDir + '/firefox')
}

function Remove-Path {
    param([string] $Path, [switch] $Recurse)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log ("not present: " + $Path)
        return
    }
    if ($DryRun) {
        Write-Log ("DRYRUN remove: " + $Path)
        return
    }
    Remove-Item -LiteralPath $Path -Force -Recurse:$Recurse
    Write-Log ("removed: " + $Path)
}

function Remove-GitHubAuth {
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        if ($DryRun) {
            Write-Log 'DRYRUN gh auth logout --hostname github.com'
        } else {
            try {
                & gh auth logout --hostname github.com 2>&1 | ForEach-Object { Write-Log $_ }
            } catch {
                Write-Log ("gh logout failed (falling back to file removal): " + $_.Exception.Message)
            }
        }
    }
    foreach ($file in @(
        (Join-Path $env:APPDATA 'GitHub CLI\hosts.yml'),
        (Join-Path $env:LOCALAPPDATA 'GitHub CLI\hosts.yml'),
        (Join-Path $env:USERPROFILE '.git-credentials')
    )) {
        Remove-Path $file
    }

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return }
    $keys = @(
        'credential.https://github.com.helper',
        'credential.https://github.com.username',
        'credential.helper'
    )
    foreach ($key in $keys) {
        $values = @(& git config --global --get-all $key 2>$null)
        foreach ($value in $values) {
            # Keep a non-gh credential manager helper; it may serve other hosts.
            if ($key -eq 'credential.helper' -and $value -notmatch '(?i)gh(\.exe)?|auth git-credential') {
                Write-Log ("keeping unrelated git helper: " + $value)
                continue
            }
            if ($DryRun) {
                Write-Log ("DRYRUN git config --global --unset-all " + $key)
            } else {
                & git config --global --unset-all $key 2>$null | Out-Null
                Write-Log ("unset git config: " + $key)
            }
        }
    }

    if (Get-Command cmdkey -ErrorAction SilentlyContinue) {
        foreach ($line in (& cmdkey /list 2>$null)) {
            $target = $null
            if ($line -match 'Target:\s*(.+)$') {
                $target = $Matches[1].Trim()
            } elseif ($line -match '^\s*(git|github)[^\s]*:\s*(.+)$' -and $line -match '(?i)github|git:') {
                $target = $Matches[2].Trim()
            }
            if (-not $target -or $target -notmatch '(?i)github|git:|gh:') { continue }
            if ($DryRun) {
                Write-Log ("DRYRUN cmdkey /delete:$target")
            } else {
                & cmdkey ("/delete:" + $target) 2>$null | Out-Null
                Write-Log ("removed credential manager entry: " + $target)
            }
        }
    }
}

function Remove-SshKeys {
    $sshDir = Join-Path $env:USERPROFILE '.ssh'
    if (Test-Path -LiteralPath $sshDir) {
        Get-ChildItem -LiteralPath $sshDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '(?i)(^id_|\.ppk$|\.pem$)' -and $_.Extension -ne '.pub' } |
            ForEach-Object { Remove-Path $_.FullName }
    }
    foreach ($dir in @(
        (Join-Path $env:TEMP 'skoop-herdr-ssh'),
        (Join-Path $env:LOCALAPPDATA 'skoop-herdr-ssh')
    )) {
        Remove-Path $dir -Recurse
    }
}

$profiles = @()
$stamp = Get-Date -Format 'yyyy-MM-dd-HHmmss'
$stagingRoot = $null
$remoteBackup = $null

$logDir = if ($StagingDir) { $StagingDir } else { Join-Path $env:LOCALAPPDATA 'skoop\backup' }
$script:LogPath = if ($LogPath) { $LogPath } else { Join-Path $logDir ('cleanup-' + $stamp + '.log') }
$logParent = Split-Path -Parent $script:LogPath
if (-not $logParent) { $logParent = '.' }
New-Item -ItemType Directory -Force -Path $logParent | Out-Null
[System.IO.File]::WriteAllText($script:LogPath, '', (New-Object System.Text.UTF8Encoding($false)))
Write-Log ("log file: " + $script:LogPath)

if ($SkipBackup -and -not $DryRun -and -not $Force) {
    throw 'Refusing to remove auth without a verified backup. Re-run with -Force or omit -SkipBackup.'
}

if (-not $SkipBackup) {
    $sshUser = Resolve-SshUser
    Write-Log ("backup target: " + $sshUser + '@' + $TargetHost)
    $profiles = @(Get-FirefoxProfilePaths)

    $stagingRoot = Join-Path $logDir $stamp
    if ($DryRun) {
        Write-Log 'DRYRUN would stage profiles locally, upload via scp, verify over ssh, then delete staging'
    } else {
        $firefoxRoot = Join-Path $stagingRoot 'firefox'
        New-Item -ItemType Directory -Force -Path $firefoxRoot | Out-Null
        $ini = Join-Path $env:APPDATA 'Mozilla\Firefox\profiles.ini'
        if (Test-Path -LiteralPath $ini) {
            Copy-Item -LiteralPath $ini -Destination (Join-Path $firefoxRoot 'profiles.ini') -Force
        }
        foreach ($profile in $profiles) {
            $target = Join-Path $firefoxRoot (Split-Path -Leaf $profile)
            Write-Log ("staging: " + $profile)
            Copy-Profile -Source $profile -Destination $target
        }
        $stagedFiles = @(Get-ChildItem -LiteralPath $firefoxRoot -Recurse -File -ErrorAction SilentlyContinue)
        $stagedBytes = ($stagedFiles | Measure-Object -Property Length -Sum).Sum
        Write-Log ("local staging complete: " + $stagedFiles.Count + " files, " + ('{0:N1}' -f ($stagedBytes / 1MB)) + ' MB')
        $remoteBackup = Invoke-RemoteBackup -Source $firefoxRoot -Stamp $stamp -SshUser $sshUser
        Write-Log 'remote backup verified - auth cleanup may proceed'
        Remove-Path $stagingRoot -Recurse
    }
}

if ($BackupOnly) {
    Write-Log 'BackupOnly: skipping all auth removal'
} else {
    Remove-GitHubAuth
    Remove-SshKeys

    if (-not $KeepFirefoxLogins) {
        foreach ($profile in $profiles) {
            foreach ($file in @('logins.json', 'key4.db')) {
                Remove-Path (Join-Path $profile $file)
            }
        }
    }
}

if (Get-Process -Name firefox -ErrorAction SilentlyContinue) {
    Write-Log 'Firefox is running - close it and reopen before use so the login changes take effect'
}
if ($DryRun) {
    Write-Log 'DRYRUN complete; nothing was changed'
} else {
    Write-Log ("done. Remote backup: " + $(if ($remoteBackup) { $remoteBackup } else { '(none)' }))
    Write-Log ("log saved: " + $script:LogPath)
}
