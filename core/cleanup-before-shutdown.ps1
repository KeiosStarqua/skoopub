<#
.SYNOPSIS
    Back up Firefox profiles, Vicinae, Atuin, Pear Desktop, OpenCode data and the
    registered repo list to acer-ubuntu over Tailscale SSH, then remove local
    sign-ins (GitHub, Tailscale, Pear Desktop, OpenCode, Firefox).

.DESCRIPTION
    Intended for public/shared PCs: run it before turning the machine off to leave
    no signed-in accounts behind. It copies every Firefox profile found in
    profiles.ini, Vicinae's config/data/state folders plus its master key (a
    Windows Credential Manager entry, required to read the encrypted databases),
    Atuin's config + data
    (history/records/meta databases and the encryption key), Pear Desktop's
    signed-in userData and OpenCode's config/state plus an `opencode auth export`
    credential dump into local staging folders, uploads them to the tailnet machine
    acer-ubuntu with scp, verifies the remote copies over ssh, and only then
    removes local credentials:

      - gh auth logout for github.com (plus the hosts.yml file as a fallback)
      - git's GitHub credential helper/username and ~/.git-credentials
      - GitHub entries in Windows Credential Manager
      - SSH keys (private + public) under ~/.ssh and temporary Herdr keys, but only
      after a verified remote snapshot of the key (unless -NoSsh); known_hosts is
      always removed
      - saved Herdr machines (herdr machine remove for every profile)
      - OpenCode credentials (opencode auth logout + auth.json fallback)
      - Tailscale login (tailscale logout), so the PC is no longer on the tailnet
      - Pear Desktop / YouTube Music user data (backed up first, then removed)
      - Firefox logins.json / key4.db from the backed-up profiles

    The SSH user is asked for at runtime (pass -User to skip the prompt). Firefox
    lands in ~/<RemotePath>/<timestamp>/firefox, Vicinae in
    ~/<VicinaeRemotePath>/<timestamp>/vicinae, Atuin in
    ~/<AtuinRemotePath>/<timestamp>/atuin, Pear Desktop in
    ~/<PearRemotePath>/<timestamp>/pear, OpenCode in
    ~/<OpenCodeRemotePath>/<timestamp>/opencode, the SSH key in
    ~/<SshRemotePath>/<timestamp>/ssh and the registered repo list in
    ~/<ReposRemotePath>/<timestamp>/repos on acer-ubuntu, so
    restore-backup.ps1 can pick the latest of each app independently. Nothing is
    deleted until each remote copy has been verified; if verification fails, the
    staging copy is kept and the script stops. Close active Atuin shells before
    running where possible: SQLite WAL/SHM sidecars are copied alongside the
    databases, but a write during the copy can still leave an inconsistent
    snapshot. -DryRun previews without changing anything. The script never shuts
    the PC down.

.PARAMETER User
    SSH user on acer-ubuntu. When omitted, the script prompts for it.

.PARAMETER TargetHost
    Tailnet hostname/IP of the backup machine (default 'acer-ubuntu').

.PARAMETER RemotePath
    Firefox destination folder relative to the remote home (default 'skoop-backups/firefox').

.PARAMETER VicinaeRemotePath
    Vicinae destination folder relative to the remote home (default 'skoop-backups/vicinae').

.PARAMETER VicinaeDataDir
    Local Vicinae data folder to back up (default: %LOCALAPPDATA%\vicinae). Its
    config, data and state subfolders are copied; the disposable cache is skipped.

.PARAMETER NoVicinae
    Skip the Vicinae snapshot and back up Firefox only.

.PARAMETER AtuinRemotePath
    Atuin destination folder relative to the remote home (default 'skoop-backups/atuin').

.PARAMETER AtuinHome
    Local Atuin data folder to back up (default: %USERPROFILE%\.atuin). config.toml,
    server.toml (when present) and the whole data folder are copied, including the
    encryption key; protect the remote backups accordingly.

.PARAMETER NoAtuin
    Skip the Atuin snapshot.

.PARAMETER PearRemotePath
    Pear Desktop destination folder relative to the remote home (default
    'skoop-backups/pear').

.PARAMETER NoPear
    Leave Pear Desktop alone: skip both its snapshot and the sign-out wipe, so the
    saved Google login stays on this machine.

.PARAMETER OpenCodeRemotePath
    OpenCode destination folder relative to the remote home (default
    'skoop-backups/opencode').

.PARAMETER NoOpenCode
    Leave OpenCode alone: skip both the snapshot and the credential wipe, so the
    stored integration login stays on this machine.

.PARAMETER SshRemotePath
    SSH key destination folder relative to the remote home (default
    'skoop-backups/ssh'). The private key is uploaded only after a successful,
    verified copy; -NoSsh skips both the snapshot and the local key wipe.

.PARAMETER NoSsh
    Leave ~/.ssh alone: skip both the SSH key snapshot and the local wipe.

.PARAMETER ReposRemotePath
    Repo-list destination folder relative to the remote home (default
    'skoop-backups/repos'). The registered repos manifest (manifests/repos.json)
    is uploaded there so a fresh machine can restore the clone list.

.PARAMETER NoRepos
    Skip the repo-list snapshot.

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
    [string] $VicinaeRemotePath = 'skoop-backups/vicinae',
    [string] $VicinaeDataDir = (Join-Path $env:LOCALAPPDATA 'vicinae'),
    [string] $AtuinRemotePath = 'skoop-backups/atuin',
    [string] $AtuinHome = (Join-Path $env:USERPROFILE '.atuin'),
    [string] $PearRemotePath = 'skoop-backups/pear',
    [string] $OpenCodeRemotePath = 'skoop-backups/opencode',
    [string] $SshRemotePath = 'skoop-backups/ssh',
    [string] $ReposRemotePath = 'skoop-backups/repos',
    [string] $StagingDir,
    [string] $LogPath,
    [switch] $NoVicinae,
    [switch] $NoAtuin,
    [switch] $NoPear,
    [switch] $NoOpenCode,
    [switch] $NoSsh,
    [switch] $NoRepos,
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

function Initialize-CredentialApi {
    if ('SkoopCredential' -as [type]) { return }
    # QKeychain (v0.14.0, USE_CREDENTIAL_STORE) keeps Vicinae's master key as a
    # generic credential named after the key, so only CredReadW/CredWriteW can
    # export or restore it.
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class SkoopCredential {
    [StructLayout(LayoutKind.Sequential)]
    private struct FileTime { public int Low; public int High; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct Credential {
        public int Flags; public int Type; public string TargetName; public string Comment;
        public FileTime LastWritten; public int CredentialBlobSize; public IntPtr CredentialBlob;
        public int Persist; public int AttributeCount; public IntPtr Attributes;
        public string TargetAlias; public string UserName;
    }

    [DllImport("advapi32", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredReadW(string target, int type, int flags, out IntPtr credential);
    [DllImport("advapi32", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredWriteW(ref Credential credential, int flags);
    [DllImport("advapi32")]
    private static extern void CredFree(IntPtr buffer);

    public static byte[] Read(string target) {
        IntPtr pointer;
        if (!CredReadW(target, 1, 0, out pointer)) return null;
        try {
            Credential credential = (Credential)Marshal.PtrToStructure(pointer, typeof(Credential));
            byte[] data = new byte[credential.CredentialBlobSize];
            Marshal.Copy(credential.CredentialBlob, data, 0, data.Length);
            return data;
        } finally {
            CredFree(pointer);
        }
    }

    public static void Write(string target, byte[] data) {
        IntPtr blob = Marshal.AllocHGlobal(data.Length);
        try {
            Marshal.Copy(data, 0, blob, data.Length);
            Credential credential = new Credential();
            credential.Type = 1;
            credential.TargetName = target;
            credential.CredentialBlob = blob;
            credential.CredentialBlobSize = data.Length;
            credential.Persist = 3;
            if (!CredWriteW(ref credential, 0)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
        } finally {
            Marshal.FreeHGlobal(blob);
        }
    }
}
'@
}

function Copy-VicinaeData {
    param([string] $Source, [string] $Destination)

    if (-not (Test-Path -LiteralPath $Source)) {
        Write-Log ("Vicinae data folder not found, skipping: " + $Source)
        return $false
    }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    foreach ($name in @('config', 'data', 'state')) {
        $sub = Join-Path $Source $name
        if (-not (Test-Path -LiteralPath $sub)) { continue }
        $target = Join-Path $Destination $name
        Write-Log ("staging vicinae/" + $name)
        if (Get-Command robocopy -ErrorAction SilentlyContinue) {
            $copyOutput = (& robocopy $sub $target /E /COPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NP 2>&1 | Out-String)
            $code = $LASTEXITCODE
            foreach ($line in (@($copyOutput -split '\r?\n' | Where-Object { $_.Trim() }) | Select-Object -Last 10)) {
                Write-Log ("robocopy: " + $line.Trim())
            }
            if ($code -ge 16) { throw "robocopy failed with code $code for $sub" }
            if ($code -ge 8) { Write-Log ("warning: robocopy skipped some files in " + $sub) }
        } else {
            Copy-Item -LiteralPath $sub -Destination $target -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Initialize-CredentialApi
    $masterKey = [SkoopCredential]::Read('vicinae-master-key')
    if ($masterKey) {
        # Encrypted clipboard.db / vicinae.db are useless without this key, so it
        # travels with the folders. Without it a restore hits the FATAL "database
        # is encrypted but its key is missing from the keychain".
        $keyDir = Join-Path $Destination 'keychain'
        New-Item -ItemType Directory -Force -Path $keyDir | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $keyDir 'vicinae-master-key'), $masterKey)
        Write-Log ("staging vicinae/keychain/vicinae-master-key (" + $masterKey.Length + " bytes)")
    } else {
        Write-Log 'Vicinae master key not in Windows Credential Manager; nothing to stage'
    }

    $files = @(Get-ChildItem -LiteralPath $Destination -Recurse -File -ErrorAction SilentlyContinue)
    if ($files.Count -lt 1) {
        Write-Log 'Vicinae data had no files to back up; no snapshot will be uploaded'
        return $false
    }
    return $true
}

function Copy-AtuinData {
    param([string] $Source, [string] $Destination)

    if (-not (Test-Path -LiteralPath $Source)) {
        Write-Log ("Atuin data folder not found, skipping: " + $Source)
        return $false
    }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null

    foreach ($name in @('config.toml', 'server.toml')) {
        $file = Join-Path $Source $name
        if (Test-Path -LiteralPath $file) {
            Copy-Item -LiteralPath $file -Destination (Join-Path $Destination $name) -Force
            Write-Log ("staging atuin/" + $name)
        }
    }

    $data = Join-Path $Source 'data'
    if (Test-Path -LiteralPath $data) {
        $target = Join-Path $Destination 'data'
        Write-Log 'staging atuin/data (history/records/meta databases + key)'
        if (Get-Command robocopy -ErrorAction SilentlyContinue) {
            # Include the SQLite -wal/-shm sidecars: together with the .db files they
            # form a consistent snapshot when no shell is writing during the copy.
            $copyOutput = (& robocopy $data $target /E /COPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NP 2>&1 | Out-String)
            $code = $LASTEXITCODE
            foreach ($line in (@($copyOutput -split '\r?\n' | Where-Object { $_.Trim() }) | Select-Object -Last 10)) {
                Write-Log ("robocopy: " + $line.Trim())
            }
            if ($code -ge 16) { throw "robocopy failed with code $code for $data" }
            if ($code -ge 8) { Write-Log ("warning: robocopy skipped some files in " + $data) }
        } else {
            Copy-Item -LiteralPath $data -Destination $target -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not (Test-Path -LiteralPath (Join-Path $Destination 'data\history.db'))) {
        Write-Log 'Atuin history.db not found in staging; no snapshot will be uploaded'
        return $false
    }
    return $true
}

function Get-PearDesktopDataRoots {
    # Pear Desktop is an Electron app. Its signed-in userData (Network\Cookies,
    # Local State, storage) lives under %APPDATA%; the %LOCALAPPDATA% folders are
    # logs/caches. Both scopes and both product names are handled so a rename
    # (YouTube Music -> Pear Desktop) still gets captured.
    $roots = @()
    foreach ($scope in @(
        @{ Name = 'roaming'; Path = $env:APPDATA },
        @{ Name = 'local'; Path = $env:LOCALAPPDATA }
    )) {
        if (-not $scope.Path) { continue }
        foreach ($app in @('YouTube Music', 'Pear Desktop')) {
            $path = Join-Path $scope.Path $app
            if (Test-Path -LiteralPath $path) {
                $roots += [pscustomobject]@{ Scope = $scope.Name; App = $app; Path = $path }
            }
        }
    }
    return @($roots)
}

function Copy-PearDesktopData {
    param([string] $Destination)

    $roots = @(Get-PearDesktopDataRoots)
    if ($roots.Count -eq 0) {
        Write-Log 'Pear Desktop user data not found, skipping'
        return $false
    }

    # Chromium keeps its cookie database locked while the app runs, and the caller
    # wipes this data afterwards, so stop it before copying.
    $running = @(Get-Process -Name 'YouTube Music', 'Pear Desktop' -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        Write-Log 'stopping Pear Desktop so its cookie database can be backed up'
        $running | Stop-Process -Force
        Start-Sleep -Seconds 2
    }

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null

    # Chromium caches are disposable and dominate the folder size; the login lives
    # in Network\Cookies, Local State and the storage folders, which are kept.
    $excludeDirs = @('Cache', 'Code Cache', 'GPUCache', 'GPUPersistentCache',
        'GrShaderCache', 'ShaderCache', 'DawnGraphiteCache', 'DawnWebGPUCache',
        'VideoDecodeStats')

    $copied = 0
    foreach ($root in $roots) {
        $target = Join-Path (Join-Path $Destination $root.Scope) $root.App
        Write-Log ("staging pear/" + $root.Scope + "/" + $root.App)
        if (Get-Command robocopy -ErrorAction SilentlyContinue) {
            $copyOutput = (& robocopy $root.Path $target /E /COPY:DAT /R:1 /W:1 /XD $excludeDirs /XF lockfile /NFL /NDL /NJH /NP 2>&1 | Out-String)
            $code = $LASTEXITCODE
            foreach ($line in (@($copyOutput -split '\r?\n' | Where-Object { $_.Trim() }) | Select-Object -Last 10)) {
                Write-Log ("robocopy: " + $line.Trim())
            }
            if ($code -ge 16) { throw "robocopy failed with code $code for " + $root.Path }
            if ($code -ge 8) { Write-Log ("warning: robocopy skipped some files in " + $root.Path) }
        } else {
            Copy-Item -LiteralPath $root.Path -Destination $target -Recurse -Force -ErrorAction SilentlyContinue
        }
        # A cookie database present at the source must make it into the snapshot;
        # otherwise the sign-out below would destroy a login we did not save.
        foreach ($required in @('Network\Cookies', 'Local State')) {
            if ((Test-Path -LiteralPath (Join-Path $root.Path $required)) -and
                -not (Test-Path -LiteralPath (Join-Path $target $required))) {
                throw ("Pear Desktop backup is missing " + $required + " from " + $root.Path + " (is the app still running?)")
            }
        }
        $files = @(Get-ChildItem -LiteralPath $target -Recurse -File -ErrorAction SilentlyContinue)
        if ($files.Count -lt 1) {
            Write-Log ("Pear Desktop data at " + $root.Path + " had no files to back up")
            continue
        }
        $copied++
    }
    return ($copied -gt 0)
}

function Get-OpenCodePaths {
    # Resolve the CLI's own view first (it honours XDG_* overrides), falling back
    # to OpenCode's documented defaults on this platform.
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
            Write-Log ('could not read opencode paths, using defaults: ' + $_.Exception.Message)
        }
    }
    return [pscustomobject] $paths
}

function Test-OpenCodeHasCredentials {
    $opencode = Get-Command opencode -ErrorAction SilentlyContinue
    if (-not $opencode) { return $false }
    try {
        $raw = & cmd /c ('"{0}" auth list --format json 2>nul' -f $opencode.Source) | Out-String
        if (-not $raw.Trim()) { return $false }
        foreach ($integration in @($raw | ConvertFrom-Json -ErrorAction Stop)) {
            if ($integration -and @($integration.connections | Where-Object { $_ }).Count -gt 0) { return $true }
        }
    } catch {
        Write-Log ('could not read opencode auth list: ' + $_.Exception.Message)
    }
    return $false
}

function Export-OpenCodeAuth {
    param([string] $Destination)

    $opencode = Get-Command opencode -ErrorAction SilentlyContinue
    if (-not $opencode) {
        Write-Log 'opencode CLI not found - skipping credential export'
        return $false
    }
    if (-not (Test-OpenCodeHasCredentials)) {
        Write-Log 'opencode has no stored credentials - skipping credential export'
        return $false
    }

    $file = Join-Path $Destination 'export.json'
    # The background service may already be gone during shutdown; retry with a
    # private server before giving up on the credentials.
    foreach ($prefix in @('', '--standalone ')) {
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
        & cmd /c ('"{0}" {1}auth export > "{2}" 2>nul' -f $opencode.Source, $prefix, $file)
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $file)) {
            $raw = [System.IO.File]::ReadAllText($file)
            if ($raw.Trim()) {
                # Never log the contents: this file contains the access token.
                Write-Log 'staged opencode/auth/export.json'
                return $true
            }
        }
    }
    throw 'opencode auth export failed; refusing to remove credentials without a verified backup.'
}

function Copy-OpenCodeData {
    param([string] $Destination)

    $paths = Get-OpenCodePaths
    $copied = $false

    foreach ($tree in @(
        [pscustomobject] @{
            Name = 'config'
            Source = $paths.Config
            ExcludeDirs = @()
            # service.json holds a runtime server password; one of these files is
            # the legacy v1 credential store, captured separately below.
            ExcludeFiles = @('service.json', 'auth.json')
        },
        [pscustomobject] @{
            Name = 'state'
            Source = $paths.State
            ExcludeDirs = @('locks', 'pty')
            ExcludeFiles = @('service.json')
        }
    )) {
        if (-not (Test-Path -LiteralPath $tree.Source)) { continue }
        $target = Join-Path $Destination $tree.Name
        Write-Log ("staging opencode/" + $tree.Name)
        New-Item -ItemType Directory -Force -Path $target | Out-Null
        if (Get-Command robocopy -ErrorAction SilentlyContinue) {
            $copyArgs = @($tree.Source, $target, '/E', '/COPY:DAT', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NP')
            if ($tree.ExcludeDirs.Count) { $copyArgs += @('/XD') + $tree.ExcludeDirs }
            if ($tree.ExcludeFiles.Count) { $copyArgs += @('/XF') + $tree.ExcludeFiles }
            $copyOutput = (& robocopy @copyArgs 2>&1 | Out-String)
            $code = $LASTEXITCODE
            foreach ($line in (@($copyOutput -split '\r?\n' | Where-Object { $_.Trim() }) | Select-Object -Last 8)) {
                Write-Log ("robocopy: " + $line.Trim())
            }
            if ($code -ge 16) { throw "robocopy failed with code $code for " + $tree.Source }
            if ($code -ge 8) { Write-Log ("warning: robocopy skipped some files in " + $tree.Source) }
        } else {
            Copy-Item -LiteralPath $tree.Source -Destination $target -Recurse -Force -ErrorAction SilentlyContinue
        }
        $files = @(Get-ChildItem -LiteralPath $target -Recurse -File -ErrorAction SilentlyContinue)
        if ($files.Count -gt 0) { $copied = $true }
    }

    $authTarget = Join-Path $Destination 'auth'
    New-Item -ItemType Directory -Force -Path $authTarget | Out-Null
    if (Export-OpenCodeAuth -Destination $authTarget) { $copied = $true }

    # v1 builds kept auth.json under config/data instead of the current database.
    foreach ($legacy in @(
        @{ Name = 'config-auth.json'; Path = (Join-Path $paths.Config 'auth.json') },
        @{ Name = 'data-auth.json'; Path = (Join-Path $paths.Data 'auth.json') },
        @{ Name = 'localappdata-auth.json'; Path = (Join-Path $paths.LocalAppData 'auth.json') }
    )) {
        if (Test-Path -LiteralPath $legacy.Path) {
            Copy-Item -LiteralPath $legacy.Path -Destination (Join-Path $authTarget $legacy.Name) -Force
            Write-Log ("staging opencode/auth/" + $legacy.Name)
            $copied = $true
        }
    }

    return $copied
}

function Copy-SshKeys {
    param([string] $Destination)

    $sshDir = Join-Path $env:USERPROFILE '.ssh'
    if (-not (Test-Path -LiteralPath $sshDir)) {
        Write-Log '~/.ssh not found - skipping SSH key snapshot'
        return $false
    }
    # Private keys, their .pub counterparts and the client config. known_hosts
    # is deliberately excluded: it is host metadata, not reusable key material.
    $keys = @(Get-ChildItem -LiteralPath $sshDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '(?i)(^id_|\.pub$|^config$|^key)' })
    if ($keys.Count -eq 0) {
        Write-Log 'no SSH keys found in ~/.ssh - skipping snapshot'
        return $false
    }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    foreach ($key in $keys) {
        Write-Log ("staging ssh/" + $key.Name)
        Copy-Item -LiteralPath $key.FullName -Destination (Join-Path $Destination $key.Name) -Force
    }
    return $true
}

function Copy-ReposManifest {
    param([string] $Destination)

    $source = Join-Path (Split-Path -Parent $PSScriptRoot) 'manifests\repos.json'
    if (-not (Test-Path -LiteralPath $source)) {
        Write-Log 'manifests/repos.json not found - skipping repo-list snapshot'
        return $false
    }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Copy-Item -LiteralPath $source -Destination (Join-Path $Destination 'repos.json') -Force
    Write-Log 'staged repos/repos.json (registered repo list)'
    return $true
}

function Invoke-RemoteBackup {
    param(
        [string] $Source,
        [string] $Stamp,
        [string] $SshUser,
        [string] $RemotePath,
        [string[]] $RequiredPaths,
        [int] $MinFiles = 1
    )

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

    $folderName = Split-Path -Leaf $Source
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

    # The staging folder is copied into $remoteDir, so files sit one level deeper.
    $checks = ''
    foreach ($path in $RequiredPaths) {
        $checks += 'if [ ! -e "$d/' + $path + '" ]; then exit 2; fi; '
    }
    $verifyCmd = @'
d='__DIR__'; __CHECKS__ n=$(find "$d" -type f | wc -l); if [ "$n" -lt __MIN__ ]; then exit 3; fi; echo "$n"
'@
    $verifyDir = $remoteDir + '/' + $folderName
    $verifyCmd = $verifyCmd.Replace('__DIR__', $verifyDir).Replace('__CHECKS__', $checks).Replace('__MIN__', [string] $MinFiles)
    Write-Log ("verify command: ssh " + ($sshArgs -join ' ') + " " + $verifyCmd)
    $check = & ssh @sshArgs $verifyCmd 2>&1
    foreach ($line in $check) { Write-Log ("verify: " + $line.ToString().Trim()) }
    if ($LASTEXITCODE -ne 0) {
        throw "Remote backup verification failed for $folderName."
    }
    $countLine = ($check | Select-Object -Last 1).ToString().Trim()
    $count = 0
    if (-not [int]::TryParse($countLine, [ref] $count) -or $count -lt $MinFiles) {
        throw "Remote backup for $folderName is empty or unreadable; refusing to remove any auth state."
    }
    Write-Log ("upload verified: " + $folderName + " " + $count + " files at " + $peer + ':' + $remoteDir)
    return ($peer + ':' + $remoteDir + '/' + $folderName)
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
        # Private keys, public keys and certs: leave no reusable key material.
        Get-ChildItem -LiteralPath $sshDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '(?i)(^id_|^key|^\w+_[a-z0-9]+$|\.ppk$|\.pem$|\.pub$|-cert\.pub$)' } |
            ForEach-Object { Remove-Path $_.FullName }
        Remove-Path (Join-Path $sshDir 'known_hosts')
    }
    foreach ($dir in @(
        (Join-Path $env:TEMP 'skoop-herdr-ssh'),
        (Join-Path $env:LOCALAPPDATA 'skoop-herdr-ssh')
    )) {
        Remove-Path $dir -Recurse
    }
}

function Remove-HerdrMachines {
    $herdr = Get-Command herdr -ErrorAction SilentlyContinue
    if (-not $herdr) {
        Write-Log 'herdr not found - skipping saved-machine removal'
        return
    }
    if ($DryRun) {
        Write-Log 'DRYRUN would remove every saved herdr machine'
        return
    }
    $machines = @(& herdr machine list 2>$null)
    foreach ($line in $machines) {
        $id = ($line -split "`t")[0].Trim()
        if (-not $id -or $id -match '(?i)^profile|^id') { continue }
        try {
            & herdr machine remove $id 2>&1 | ForEach-Object { Write-Log $_ }
            Write-Log ("removed herdr machine: " + $id)
        } catch {
            Write-Log ("could not remove herdr machine $id : " + $_.Exception.Message)
        }
    }
}

function Remove-OpenCodeAuth {
    $opencode = Get-Command opencode -ErrorAction SilentlyContinue
    if ($opencode) {
        if ($DryRun) {
            Write-Log 'DRYRUN would log out all opencode credentials'
        } else {
            $targets = @()
            # Current builds expose stable IDs through --format json; the plain
            # table is kept as a fallback for older CLIs.
            try {
                $raw = & cmd /c ('"{0}" auth list --format json 2>nul' -f $opencode.Source) | Out-String
                if ($raw.Trim()) {
                    foreach ($integration in @($raw | ConvertFrom-Json -ErrorAction Stop)) {
                        if (-not $integration -or -not $integration.id) { continue }
                        foreach ($connection in @($integration.connections)) {
                            if (-not $connection -or -not $connection.id) { continue }
                            $targets += [pscustomobject] @{ Integration = $integration.id; Credential = $connection.id }
                        }
                    }
                }
            } catch {
                Write-Log ('could not read opencode credentials as JSON, using the table output: ' + $_.Exception.Message)
            }
            if ($targets.Count -eq 0) {
                $accounts = @(& cmd /c ('"{0}" auth list 2>nul' -f $opencode.Source))
                foreach ($line in $accounts) {
                    $parts = @($line -split '\s{2,}') | Where-Object { $_.Trim() }
                    if ($parts.Count -lt 2) { continue }
                    $targets += [pscustomobject] @{ Integration = $parts[0].Trim(); Credential = $parts[1].Trim() }
                }
            }
            foreach ($target in $targets) {
                try {
                    & cmd /c ('"{0}" auth logout "{1}" "{2}" 2>&1' -f $opencode.Source, $target.Integration, $target.Credential) |
                        ForEach-Object { Write-Log $_ }
                    Write-Log ("opencode logout: " + $target.Integration + ' / ' + $target.Credential)
                } catch {
                    Write-Log ("opencode logout failed for " + $target.Integration + '/' + $target.Credential + ' : ' + $_.Exception.Message)
                }
            }
        }
    }
    # Fallback for credential files used by older/alternate opencode builds.
    foreach ($file in @(
        (Join-Path $env:USERPROFILE '.config\opencode\auth.json'),
        (Join-Path $env:USERPROFILE '.local\share\opencode\auth.json'),
        (Join-Path $env:LOCALAPPDATA 'opencode\auth.json')
    )) {
        Remove-Path $file
    }
}

function Resolve-TailscaleCli {
    # The official Windows installer does not add tailscale.exe to PATH.
    $cmd = Get-Command tailscale -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $candidates = @()
    if ($env:ProgramFiles) { $candidates += Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe' }
    if (${env:ProgramFiles(x86)}) { $candidates += Join-Path ${env:ProgramFiles(x86)} 'Tailscale\tailscale.exe' }
    if ($env:LOCALAPPDATA) { $candidates += Join-Path $env:LOCALAPPDATA 'Tailscale\tailscale.exe' }
    $scoopRoot = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $env:USERPROFILE 'scoop' }
    $candidates += Join-Path $scoopRoot 'apps\tailscale\current\tailscale.exe'
    $candidates += Join-Path $scoopRoot 'shims\tailscale.exe'
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

function Remove-TailscaleAuth {
    $cli = Resolve-TailscaleCli
    if ($DryRun) {
        Write-Log ("DRYRUN " + $(if ($cli) { $cli } else { 'tailscale.exe' }) + " logout")
        return
    }
    if (-not $cli) {
        Write-Log 'tailscale.exe not found (PATH, Program Files or Scoop) - skipping Tailscale logout'
        return
    }
    try {
        # cmd /c merges stderr so PS 5.1 does not raise a terminating NativeCommandError.
        $output = (& cmd /c ('"{0}" logout 2>&1' -f $cli) | Out-String)
        foreach ($line in ($output -split '\r?\n' | Where-Object { $_.Trim() } | Select-Object -Last 10)) {
            Write-Log ("tailscale: " + $line.Trim())
        }
        if ($LASTEXITCODE -ne 0) {
            Write-Log ("WARNING: tailscale logout exited with code " + $LASTEXITCODE)
        } else {
            Write-Log 'Tailscale logged out - this device is no longer signed in to the tailnet'
        }
    } catch {
        Write-Log ("WARNING: tailscale logout failed: " + $_.Exception.Message)
    }
}

function Remove-PearDesktopData {
    # Pear Desktop is an Electron app; its userData folder holds the saved Google
    # login (Cookies/Local State), storage and cache. The snapshot is uploaded and
    # verified before this runs.
    foreach ($root in @(Get-PearDesktopDataRoots)) {
        Remove-Path $root.Path -Recurse
    }
}

$profiles = @()
$stamp = Get-Date -Format 'yyyy-MM-dd-HHmmss'
$stagingRoot = $null
$remoteBackups = @()

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
        Write-Log 'DRYRUN would stage Firefox + Vicinae + Atuin + Pear Desktop + OpenCode locally, upload each, verify over ssh, then delete staging'
    } else {
        $firefoxRoot = Join-Path $stagingRoot 'firefox'
        New-Item -ItemType Directory -Force -Path $firefoxRoot | Out-Null
        $firefoxBase = Join-Path $env:APPDATA 'Mozilla\Firefox'
        foreach ($name in @('profiles.ini', 'installs.ini')) {
            $ini = Join-Path $firefoxBase $name
            if (Test-Path -LiteralPath $ini) {
                Copy-Item -LiteralPath $ini -Destination (Join-Path $firefoxRoot $name) -Force
            }
        }
        foreach ($profile in $profiles) {
            $target = Join-Path $firefoxRoot (Split-Path -Leaf $profile)
            Write-Log ("staging: " + $profile)
            Copy-Profile -Source $profile -Destination $target
        }
        $stagedFiles = @(Get-ChildItem -LiteralPath $firefoxRoot -Recurse -File -ErrorAction SilentlyContinue)
        $stagedBytes = ($stagedFiles | Measure-Object -Property Length -Sum).Sum
        Write-Log ("local staging complete: " + $stagedFiles.Count + " files, " + ('{0:N1}' -f ($stagedBytes / 1MB)) + ' MB')
        $remoteBackups += Invoke-RemoteBackup -Source $firefoxRoot -Stamp $stamp -SshUser $sshUser `
            -RemotePath $RemotePath -RequiredPaths @('profiles.ini') -MinFiles 2

        if (-not $NoVicinae) {
            $vicinaeRoot = Join-Path $stagingRoot 'vicinae'
            if (Copy-VicinaeData -Source $VicinaeDataDir -Destination $vicinaeRoot) {
                $remoteBackups += Invoke-RemoteBackup -Source $vicinaeRoot -Stamp $stamp -SshUser $sshUser `
                    -RemotePath $VicinaeRemotePath -RequiredPaths @('config') -MinFiles 1
            }
        }

        if (-not $NoAtuin) {
            $atuinRoot = Join-Path $stagingRoot 'atuin'
            if (Copy-AtuinData -Source $AtuinHome -Destination $atuinRoot) {
                $remoteBackups += Invoke-RemoteBackup -Source $atuinRoot -Stamp $stamp -SshUser $sshUser `
                    -RemotePath $AtuinRemotePath -RequiredPaths @('data/history.db') -MinFiles 2
            }
        }

        if (-not $NoPear) {
            $pearRoot = Join-Path $stagingRoot 'pear'
            if (Copy-PearDesktopData -Destination $pearRoot) {
                $remoteBackups += Invoke-RemoteBackup -Source $pearRoot -Stamp $stamp -SshUser $sshUser `
                    -RemotePath $PearRemotePath -RequiredPaths @() -MinFiles 2
            }
        }

        if (-not $NoOpenCode) {
            $openCodeRoot = Join-Path $stagingRoot 'opencode'
            if (Copy-OpenCodeData -Destination $openCodeRoot) {
                $required = @()
                if (Test-Path -LiteralPath (Join-Path $openCodeRoot 'auth\export.json')) {
                    $required += 'auth/export.json'
                }
                $remoteBackups += Invoke-RemoteBackup -Source $openCodeRoot -Stamp $stamp -SshUser $sshUser `
                    -RemotePath $OpenCodeRemotePath -RequiredPaths $required -MinFiles 2
            }
        }
        if (-not $NoSsh) {
            $sshRoot = Join-Path $stagingRoot 'ssh'
            if (Copy-SshKeys -Destination $sshRoot) {
                $remoteBackups += Invoke-RemoteBackup -Source $sshRoot -Stamp $stamp -SshUser $sshUser `
                    -RemotePath $SshRemotePath -RequiredPaths @() -MinFiles 1
            }
        }

        if (-not $NoRepos) {
            $reposRoot = Join-Path $stagingRoot 'repos'
            if (Copy-ReposManifest -Destination $reposRoot) {
                $remoteBackups += Invoke-RemoteBackup -Source $reposRoot -Stamp $stamp -SshUser $sshUser `
                    -RemotePath $ReposRemotePath -RequiredPaths @('repos.json') -MinFiles 1
            }
        }

        Write-Log 'remote backups verified - auth cleanup may proceed'
        Remove-Path $stagingRoot -Recurse
    }
}

if ($BackupOnly) {
    Write-Log 'BackupOnly: skipping all auth removal'
} else {
    Remove-GitHubAuth
    if (-not $NoSsh) { Remove-SshKeys }
    Remove-HerdrMachines
    if (-not $NoOpenCode) { Remove-OpenCodeAuth }
    Remove-TailscaleAuth
    if (-not $NoPear) { Remove-PearDesktopData }

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
if (Get-Process -Name 'YouTube Music' -ErrorAction SilentlyContinue) {
    Write-Log 'Pear Desktop is running - close it and reopen before use so the login changes take effect'
}
if ($DryRun) {
    Write-Log 'DRYRUN complete; nothing was changed'
} else {
    Write-Log ("done. Remote backups: " + $(if ($remoteBackups) { $remoteBackups -join ', ' } else { '(none)' }))
    Write-Log ("log saved: " + $script:LogPath)

    if (-not $BackupOnly) {
        # The shutdown guard uses this stamp to skip a duplicate cleanup when a
        # full run already finished a few minutes ago.
        $stampPath = Join-Path $logDir 'last-cleanup.json'
        $marker = [ordered] @{
            timestamp = (Get-Date).ToString('o')
            backups   = @($remoteBackups)
            log       = $script:LogPath
            host      = $env:COMPUTERNAME
        }
        [System.IO.File]::WriteAllText($stampPath, ($marker | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
        Write-Log ("last cleanup stamp: " + $stampPath)

        $history = Join-Path $logDir 'cleanup-history.log'
        Add-Content -LiteralPath $history -Value ((Get-Date -Format 'o') + "`tOK`tauth-removed`tbackups=" + ($remoteBackups -join '; ')) -Encoding UTF8
    }
}
