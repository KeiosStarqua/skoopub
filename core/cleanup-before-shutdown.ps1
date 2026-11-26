<#
.SYNOPSIS
    Back up Firefox profiles to Google Drive with rclone, then remove local auth state.

.DESCRIPTION
    Intended for public/shared PCs: run it before turning the machine off to leave
    no signed-in accounts behind. It copies every Firefox profile found in
    profiles.ini into a local staging folder, uploads it with `rclone copy`, and
    verifies the remote copy before removing local credentials:

      - gh auth logout for github.com (plus the hosts.yml file as a fallback)
      - git's GitHub credential helper/username and ~/.git-credentials
      - GitHub entries in Windows Credential Manager
      - SSH private keys under ~/.ssh and the temporary Herdr key folder
      - Firefox logins.json / key4.db from the backed-up profiles

    Configure the remote once with `rclone config` (e.g. name it gdrive). Nothing is
    deleted until the upload has been verified; if verification fails, the staging
    copy is kept and the script stops. -DryRun previews without changing anything.
    The script never shuts the PC down.

.PARAMETER Remote
    rclone remote to upload to, e.g. 'gdrive:' (default). A trailing ':' is added
    when omitted.

.PARAMETER RemotePath
    Folder on the remote (default 'skoop-cleanup'). Backups land in
    <Remote><RemotePath>/<timestamp>/firefox/.

.PARAMETER StagingDir
    Local folder used to assemble the backup before upload. Defaults to
    %LOCALAPPDATA%\skoop\backup and is removed after a verified upload.

.PARAMETER SkipBackup
    Skip the Firefox backup. Requires -Force, so an auth wipe cannot happen
    by accident without a verified copy.

.PARAMETER KeepFirefoxLogins
    Keep Firefox's saved logins/key database after the backup (opt-out).

.PARAMETER DryRun
    Print what would happen; do not copy, upload or delete anything.

.PARAMETER Force
    Allow -SkipBackup.

.EXAMPLE
    .\core\cleanup-before-shutdown.ps1 -DryRun

.EXAMPLE
    .\core\cleanup-before-shutdown.ps1 -Remote gdrive: -RemotePath skoop-cleanup
#>
[CmdletBinding()]
param(
    [string] $Remote = 'gdrive:',
    [string] $RemotePath = 'skoop-cleanup',
    [string] $StagingDir,
    [switch] $SkipBackup,
    [switch] $KeepFirefoxLogins,
    [switch] $DryRun,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string] $Message)
    Write-Host ("[cleanup] " + $Message)
}

function Get-RcloneDestination {
    param([string] $Stamp)

    $name = $Remote
    if ($name -notmatch ':$') { $name += ':' }
    return ($name + $RemotePath.Trim('/') + '/' + $Stamp + '/firefox')
}

function Assert-RcloneReady {
    $cli = Get-Command rclone -ErrorAction SilentlyContinue
    if (-not $cli) {
        throw 'rclone is not installed. Install it with: scoop install main/rclone'
    }
    if ($DryRun) {
        Write-Log 'DRYRUN skipping rclone remote check'
        return $cli.Source
    }

    $name = $Remote -replace ':$', ''
    $configured = @(& rclone listremotes 2>$null | ForEach-Object { $_ -replace ':$', '' })
    if ($configured -notcontains $name) {
        throw ("rclone remote '$name' is not configured. Run: rclone config (then re-run this script).")
    }
    return $cli.Source
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
        & robocopy $Source $Destination /E /COPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
        $code = $LASTEXITCODE
        if ($code -gt 7) {
            throw "robocopy failed with code $code for $Source"
        }
    } else {
        Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
    }

    if (-not (Test-Path -LiteralPath (Join-Path $Destination 'prefs.js'))) {
        throw "Backup verification failed for $Source"
    }
}

function Invoke-RcloneUpload {
    param([string] $Source, [string] $Destination)

    & rclone copy $Source $Destination 2>&1 | ForEach-Object { Write-Log $_ }
    if ($LASTEXITCODE -ne 0) {
        throw "rclone copy failed with exit code $LASTEXITCODE"
    }

    $sizeJson = & rclone size --json $Destination 2>$null | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw 'rclone size could not verify the uploaded backup'
    }
    try {
        $size = $sizeJson | ConvertFrom-Json
    } catch {
        throw 'rclone size returned unreadable JSON; upload verification failed'
    }
    $files = 0
    if ($size.PSObject.Properties.Name -contains 'count') { $files = [int] $size.count }
    if ($files -lt 1) {
        throw 'Uploaded backup is empty; refusing to remove any auth state'
    }
    Write-Log ("upload verified: " + $Destination + " (" + $files + " files)")
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
$remoteTarget = $null

if ($SkipBackup -and -not $DryRun -and -not $Force) {
    throw 'Refusing to remove auth without a verified backup. Re-run with -Force or omit -SkipBackup.'
}

if (-not $SkipBackup) {
    Assert-RcloneReady | Out-Null
    $remoteTarget = Get-RcloneDestination $stamp
    Write-Log ("rclone destination: " + $remoteTarget)
    $profiles = @(Get-FirefoxProfilePaths)

    $stagingBase = if ($StagingDir) { $StagingDir } else { Join-Path $env:LOCALAPPDATA 'skoop\backup' }
    $stagingRoot = Join-Path $stagingBase $stamp
    if ($DryRun) {
        Write-Log 'DRYRUN would stage profiles locally, upload with rclone, verify, then delete staging'
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
        Write-Log 'local staging complete'
        Invoke-RcloneUpload -Source $firefoxRoot -Destination $remoteTarget
        Write-Log 'upload verified - auth cleanup may proceed'
        Remove-Path $stagingRoot -Recurse
    }
}

Remove-GitHubAuth
Remove-SshKeys

if (-not $KeepFirefoxLogins) {
    foreach ($profile in $profiles) {
        foreach ($file in @('logins.json', 'key4.db')) {
            Remove-Path (Join-Path $profile $file)
        }
    }
}

if (Get-Process -Name firefox -ErrorAction SilentlyContinue) {
    Write-Log 'Firefox is running - close it and reopen before use so the login changes take effect'
}
if ($DryRun) {
    Write-Log 'DRYRUN complete; nothing was changed'
} else {
    Write-Log ("done. Remote backup: " + $(if ($remoteTarget) { $remoteTarget } else { '(none)' }))
}
