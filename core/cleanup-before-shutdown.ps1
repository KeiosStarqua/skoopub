<#
.SYNOPSIS
    Back up Firefox profiles to Google Drive, then remove machine-local auth state.

.DESCRIPTION
    Intended for public/shared PCs: run it before turning the machine off to leave
    no signed-in accounts behind. It first copies every Firefox profile found in
    profiles.ini into a timestamped folder under Google Drive, verifies the copy,
    and only then removes local credentials:

      - gh auth logout for github.com (plus the hosts.yml file as a fallback)
      - git's GitHub credential helper/username and ~/.git-credentials
      - GitHub entries in Windows Credential Manager
      - SSH private keys under ~/.ssh and the temporary Herdr key folder
      - Firefox logins.json / key4.db from the backed-up profiles

    Nothing is deleted until the backup has been verified. Use -DryRun to preview
    without changing anything. The script never shuts the PC down.

.PARAMETER BackupDir
    Google Drive folder to write the backup into. Auto-detected when omitted.

.PARAMETER SkipBackup
    Skip the Firefox backup. Requires -Force, so an auth wipe cannot happen
    by accident without a verified copy.

.PARAMETER KeepFirefoxLogins
    Keep Firefox's saved logins/key database after the backup (opt-out).

.PARAMETER DryRun
    Print what would happen; do not copy or delete anything.

.PARAMETER Force
    Allow -SkipBackup.

.EXAMPLE
    .\core\cleanup-before-shutdown.ps1 -DryRun

.EXAMPLE
    .\core\cleanup-before-shutdown.ps1 -BackupDir 'D:\Google Drive'
#>
[CmdletBinding()]
param(
    [string] $BackupDir,
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

function Resolve-BackupDirectory {
    param([string] $Explicit)

    if ($Explicit) {
        if (-not (Test-Path -LiteralPath $Explicit)) {
            throw "BackupDir does not exist: $Explicit"
        }
        return $Explicit
    }

    $candidates = @()
    if ($env:GOOGLE_DRIVE_PATH) { $candidates += $env:GOOGLE_DRIVE_PATH }
    $candidates += (Join-Path $env:USERPROFILE 'Google Drive')
    $candidates += (Join-Path $env:USERPROFILE 'Google Drive\My Drive')
    $candidates += (Join-Path $env:USERPROFILE 'GoogleDrive')
    $candidates += (Join-Path $env:USERPROFILE 'Drive')

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }
    throw 'Google Drive folder not found. Pass -BackupDir or set $env:GOOGLE_DRIVE_PATH.'
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
$backupRoot = $null

if ($SkipBackup -and -not $DryRun -and -not $Force) {
    throw 'Refusing to remove auth without a verified backup. Re-run with -Force or omit -SkipBackup.'
}

if (-not $SkipBackup) {
    $drive = Resolve-BackupDirectory $BackupDir
    Write-Log ("Google Drive: " + $drive)
    $profiles = @(Get-FirefoxProfilePaths)
    if ($DryRun) {
        Write-Log 'DRYRUN would copy Firefox profiles to a timestamped folder under the Drive folder'
    } else {
        $backupRoot = Join-Path $drive ('skoop-cleanup-' + (Get-Date -Format 'yyyy-MM-dd-HHmmss'))
        $firefoxRoot = Join-Path $backupRoot 'firefox'
        New-Item -ItemType Directory -Force -Path $firefoxRoot | Out-Null
        $ini = Join-Path $env:APPDATA 'Mozilla\Firefox\profiles.ini'
        if (Test-Path -LiteralPath $ini) {
            Copy-Item -LiteralPath $ini -Destination (Join-Path $firefoxRoot 'profiles.ini') -Force
        }
        foreach ($profile in $profiles) {
            $target = Join-Path $firefoxRoot (Split-Path -Leaf $profile)
            Write-Log ("backing up: " + $profile)
            Copy-Profile -Source $profile -Destination $target
        }
        Write-Log ("backup verified: " + $firefoxRoot)
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
    Write-Log ("done. Backup location: " + $(if ($backupRoot) { $backupRoot } else { '(none)' }))
}
