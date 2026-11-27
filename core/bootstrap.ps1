# bootstrap.ps1 - restore this Scoop + shell setup on a Windows machine.
# Usage:  powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1
# Installs manifests/scoop.json in the phases from manifests/phases.json: phase 1
# is PowerShell 7 + Rio + Vicinae + the Herdr TUI, the heavy apps come last.
# Re-runs skip Scoop apps that are already installed; -ForceInstall re-imports them.
# Use -ForceUniKey to replace an already installed UniKey with the Scoop build.
# Configures UniKey (Unicode + VNI, Vietnamese on, no startup dialog, autostart)
# via apps\unikey\configure.ps1; -Export / -Restore back up its settings.
# Use -SkipGhLogin to avoid the interactive `gh auth login` prompt.
# Sets the global git author identity to Keios <git@taquangkhoi.com>.
# Also applies the repo-managed Zed config from apps\zed via configure.ps1.
# Also applies the repo-managed Rio config (font size / zoom 16) via apps\rio\configure.ps1.
# After Tailscale starts, apps/herdr/setup-ssh.ps1 asks which tailnet machine to
# add to Herdr (saved via `herdr machine add` over Tailscale SSH).
# Also registers Vicinae to start at login via apps\vicinae\enable-autostart.ps1
# and sets its global shortcut to Ctrl+Space via apps\vicinae\configure.ps1.
# Deploys ~/.config/whkdrc and starts Komorebi/whkd via apps\komorebi\configure.ps1.
# Deploys the YASB status bar config and starts YASB via apps\yasb\configure.ps1.
# Adds `n` for Nushell in PowerShell (profile.ps1) and cmd (apps\nushell\setup.ps1).
# Sets the CurrentUser execution policy to RemoteSigned so the profile hook works.
# Checks the Windows theme and enables Dark Mode (core\set-dark-mode.ps1).
# Creates ~/repos and clones skoopub there when missing (idempotent).
# Installs Rio before Herdr in phase 1, then opens Rio in ~/repos with Herdr
# running (SKOOP_NO_AUTO_HERDR=1 opts out).
# After Tailscale connects, restores Vicinae, Pear Desktop, Firefox and Atuin from
# the backup once per machine via apps\tailscale\configure.ps1 -RestoreVicinae
# -RestorePearDesktop -RestoreFirefox -RestoreAtuin (-BackupUser /
# SKOOP_BACKUP_USER supplies the SSH user). Firefox/Atuin are retried at the end
# of the run; -ForceFirefoxRestore / -ForceAtuinRestore repeat one,
# -SkipFirefoxRestore / -SkipAtuinRestore opt out (also SKOOP_FORCE_* /
# SKOOP_NO_* env vars). OpenCode config/credentials are restored after the app
# phases with -RestoreOpenCode.
[CmdletBinding()]
param(
    [switch]$ForceUniKey,
    [Alias('Force')]
    [switch]$ForceInstall,
    [switch]$SkipGhLogin,
    # Optional wallpaper file; empty means a random image from the cloned collection.
    [string]$Wallpaper = "$env:SKOOP_WALLPAPER",
    [switch]$NoWallpaper,
    [string]$BackupUser = "$env:SKOOP_BACKUP_USER",
    [switch]$ForceFirefoxRestore,
    [switch]$ForceAtuinRestore,
    [switch]$SkipFirefoxRestore,
    [switch]$SkipAtuinRestore
)

if ($env:SKOOP_FORCE_INSTALL -eq '1') { $ForceInstall = $true }
if ($env:SKOOP_FORCE_FIREFOX_RESTORE -eq '1') { $ForceFirefoxRestore = $true }
if ($env:SKOOP_FORCE_ATUIN_RESTORE -eq '1') { $ForceAtuinRestore = $true }
if ($env:SKOOP_NO_FIREFOX_RESTORE -eq '1') { $SkipFirefoxRestore = $true }
if ($env:SKOOP_NO_ATUIN_RESTORE -eq '1') { $SkipAtuinRestore = $true }

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
# Firefox and Atuin restore happens right after Tailscale connects (phase 1) and
# is retried at the end of the run. Markers make the retry a no-op; both apps are
# installed later, but these restores only lay down files (no CLI dependency).
$restoreAppsArgs = @()
if (-not $SkipFirefoxRestore) {
    $restoreAppsArgs += '-RestoreFirefox'
    if ($ForceFirefoxRestore) { $restoreAppsArgs += '-ForceFirefoxRestore' }
}
if (-not $SkipAtuinRestore) {
    $restoreAppsArgs += '-RestoreAtuin'
    if ($ForceAtuinRestore) { $restoreAppsArgs += '-ForceAtuinRestore' }
}

function Ensure-SkoopClone {
    # Keep every checkout under ~/repos, including this repo. A piped install
    # has no local checkout, so leave one for later re-runs and Herdr. Never
    # overwrite a directory that is already there.
    $reposDir = Join-Path $env:USERPROFILE 'repos'
    $cloneDir = Join-Path $reposDir 'skoopub'
    try {
        if (-not (Test-Path -LiteralPath $reposDir)) {
            Write-Host "Creating $reposDir"
            New-Item -ItemType Directory -Force -Path $reposDir | Out-Null
        }
        if (Test-Path -LiteralPath (Join-Path $cloneDir '.git')) {
            Write-Host "skoopub checkout already exists at $cloneDir."
            return
        }
        if (Test-Path -LiteralPath $cloneDir) {
            Write-Host "$cloneDir exists but is not a git checkout - skipping clone." -ForegroundColor Yellow
            return
        }
        $cloneUrl = 'https://github.com/KeiosStarqua/skoopub.git'
        Write-Host "Cloning skoopub into $cloneDir"
        $out = (& cmd /c "`"$((Get-Command git -ErrorAction Stop).Source)`" clone `"$cloneUrl`" `"$cloneDir`" 2>&1" | Out-String)
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $cloneDir '.git'))) {
            throw "git clone failed (exit $LASTEXITCODE): $(($out -split "`r?`n" | Select-Object -Last 3) -join ' ')"
        }
        Write-Host "skoopub cloned into $cloneDir."
    } catch {
        Write-Host "Could not prepare $cloneDir (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Start-HerdrInRio {
    # Open the terminal with Herdr already running, so a fresh machine is ready
    # to use right after the essentials phase. Skipped for unattended/embedded
    # runs and kept non-fatal.
    if ($env:SKOOP_NO_AUTO_HERDR -eq '1' -or -not [Environment]::UserInteractive -or $env:HERDR_ENV -eq '1') {
        return
    }
    $rio = Get-Command rio -ErrorAction SilentlyContinue
    $pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if (-not $rio -or -not $pwshCmd) { return }
    $reposDir = Join-Path $env:USERPROFILE 'repos'
    if (-not (Test-Path -LiteralPath $reposDir)) { New-Item -ItemType Directory -Force -Path $reposDir | Out-Null }
    # Pane markers inherited from a Herdr session make `herdr` refuse to start.
    foreach ($name in @(
        'HERDR_ENV', 'HERDR_PANE_ID', 'HERDR_TAB_ID',
        'HERDR_WORKSPACE_ID', 'HERDR_SOCKET_PATH', 'HERDR_BIN_PATH'
    )) {
        Remove-Item "Env:$name" -ErrorAction SilentlyContinue
    }
    try {
        $rioArgs = @('-w', "`"$reposDir`"", '-e', "`"$($pwshCmd.Source)`"", '-NoLogo', '-NoExit', '-Command', 'herdr')
        Start-Process -FilePath $rio.Source -ArgumentList $rioArgs -WorkingDirectory $reposDir | Out-Null
        Write-Host "Opened Rio in $reposDir with Herdr."
    } catch {
        Write-Host "Could not open Rio/Herdr (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Test-UniKeyInstalled {
    # Public PCs often ship a manually installed UniKey; installing the Scoop
    # copy as well would leave two IMEs fighting over the same hotkeys.
    if (Get-Process -Name UniKeyNT -ErrorAction SilentlyContinue) { return $true }
    $uninstallKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($key in $uninstallKeys) {
        if (Get-ItemProperty -Path $key -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match 'UniKey' }) { return $true }
    }
    $scoopRoots = @($env:SCOOP, (Join-Path $env:USERPROFILE 'scoop'), (Join-Path $env:ProgramData 'scoop'))
    foreach ($root in $scoopRoots) {
        if ($root -and (Test-Path (Join-Path $root 'apps\unikey\current'))) { return $true }
    }
    return $false
}

function Set-FirefoxDefaultBrowser {
    # Let Firefox set its own UserChoice entries; direct registry writes are
    # blocked on modern Windows. Windows 11 may still open Settings to confirm.
    $firefox = Get-Command firefox -ErrorAction SilentlyContinue
    if (-not $firefox) { Write-Host 'Firefox not on PATH - skipping default browser step.'; return }

    $httpChoice = 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\http\UserChoice'
    $progId = (Get-ItemProperty -Path $httpChoice -ErrorAction SilentlyContinue).ProgId
    if ($progId -match '^Firefox') { Write-Host 'Firefox is already the default browser.'; return }

    try {
        Start-Process -FilePath $firefox.Source -ArgumentList '--setDefaultBrowser' | Out-Null
        Write-Host 'Requested Firefox as default browser (confirm in Settings if prompted).'
    } catch {
        Write-Host "Could not set Firefox as default browser (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Install-FirefoxPolicies {
    param([string]$Template)

    # Scoop persists Firefox's distribution folder, so policies.json survives
    # Firefox updates. Firefox reads it at startup (about:policies shows it).
    $scoopRoot = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $env:USERPROFILE 'scoop' }
    $firefoxDir = Join-Path $scoopRoot 'apps\firefox\current'
    if (-not (Test-Path (Join-Path $firefoxDir 'firefox.exe'))) {
        Write-Host 'Scoop Firefox install not found - skipping extension policy.'
        return
    }
    if (-not (Test-Path $Template)) {
        Write-Host 'apps/firefox/policies.template.json not found - skipping extension policy.'
        return
    }

    $distDir = Join-Path $firefoxDir 'distribution'
    New-Item -ItemType Directory -Force -Path $distDir | Out-Null
    Copy-Item -LiteralPath $Template -Destination (Join-Path $distDir 'policies.json') -Force
    Write-Host 'Firefox policy installed (restart Firefox to apply it).'
    if (Get-Process -Name firefox -ErrorAction SilentlyContinue) {
        Write-Host 'Firefox is running - close and reopen it to load the policy.'
    }
}

function Get-ProfileTargets {
    # PowerShell 5.1 and 7+ use separate profile files; hook both so the shell
    # config works in either edition, not just the one running this script.
    $targets = @($PROFILE)
    $documents = [Environment]::GetFolderPath('MyDocuments')
    if ($documents) {
        $other = if ($PSVersionTable.PSEdition -eq 'Desktop') { 'PowerShell' } else { 'WindowsPowerShell' }
        $targets += Join-Path (Join-Path $documents $other) 'Microsoft.PowerShell_profile.ps1'
    }
    return @($targets | Where-Object { $_ } | Select-Object -Unique)
}

function Set-SkoopExecutionPolicy {
    # Windows defaults to Restricted, so the dot-source below would make every
    # new shell print "running scripts is disabled on this system". Allow local
    # scripts for this user; downloaded files still need a signature. Non-fatal
    # when Group Policy locks the scope down.
    try {
        $current = Get-ExecutionPolicy -Scope CurrentUser -ErrorAction Stop
        if ($current -in @('RemoteSigned', 'Unrestricted', 'Bypass')) {
            Write-Host "Execution policy for CurrentUser is already $current."
            return
        }
    } catch {
        Write-Host "Could not read the execution policy (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
        return
    }

    try {
        Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force -ErrorAction SilentlyContinue | Out-Null
    } catch {
        # A process launched with -ExecutionPolicy Bypass can raise
        # ExecutionPolicyOverride even though CurrentUser was written; verify
        # with a read-back below instead of trusting the exception.
    }
    $after = Get-ExecutionPolicy -Scope CurrentUser -ErrorAction SilentlyContinue
    if ($after -eq 'RemoteSigned') {
        Write-Host 'Execution policy for CurrentUser set to RemoteSigned.'
    } else {
        Write-Host "Could not set the execution policy (non-fatal, CurrentUser is $after)" -ForegroundColor Yellow
    }
}

function Test-SkoopProfileLoads {
    # Regression guard for the two things that broke before: a Restricted
    # execution policy and a stale/missing dot-source hook. A fresh Windows
    # PowerShell process must load $PROFILE and expose Clear-HerdrEnv from
    # shell/profile.ps1. No -NoProfile, and no inherited process-scope Bypass.
    $shell51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $shell51)) { return $true }
    try {
        $probe = 'if (Get-Command Clear-HerdrEnv -ErrorAction SilentlyContinue) { ''ok'' }'
        $out = & $shell51 -NoLogo -Command $probe 2>$null
        return (((@($out) -join "`n") -match '\bok\b'))
    } catch {
        return $false
    }
}

function Install-ProfileHook {
    # Wire the repo-managed profile into both profiles early so zoxide/atuin are
    # configured even if a later (optional) step fails.
    $loader = Join-Path $repo 'shell\profile.ps1'
    $hook = "# Load the repo-managed shell config. Edit that file, not this one.`r`n. `"$loader`""
    $normalize = { param([string]$Text) ($Text -replace "`r`n", "`n").TrimEnd() }

    foreach ($target in Get-ProfileTargets) {
        New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
        $lines = if (Test-Path $target) { @(Get-Content -Path $target) } else { @() }
        # Replace any hook we previously installed instead of trusting it. A
        # stale one can point at a profile.ps1 that no longer exists (e.g. the
        # old repo-root path from before the move into `shell`) and then silently
        # load nothing, which looks like the packages are missing. Match our
        # marker comment plus the dot-source line after it, so this works no
        # matter where the repo is cloned or what its folder was renamed from.
        $kept = [System.Collections.Generic.List[string]]::new()
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = [string]$lines[$i]
            if ($line -match '^# Load the repo-managed shell config') {
                if ($i + 1 -lt $lines.Count -and
                    $lines[$i + 1] -match '^\s*\.\s+[''"]' -and
                    $lines[$i + 1] -match 'profile\.ps1') {
                    $i++
                }
                continue
            }
            if ($line -match '\$skoopProfile' -or
                $line -match [regex]::Escape($loader) -or
                ($line -match '^\s*\.\s+[''"]' -and
                 $line -match [regex]::Escape($repo) -and
                 $line -match 'profile\.ps1')) {
                continue
            }
            $kept.Add($line)
        }
        $body = ($kept -join "`r`n").TrimEnd()
        $desired = if ($body) { "$body`r`n$hook" } else { $hook }

        $existing = if (Test-Path $target) { Get-Content -Raw -Path $target } else { '' }
        if ((& $normalize $existing) -ne (& $normalize $desired)) {
            Set-Content -Path $target -Value $desired -Encoding UTF8
            Write-Host "Wired profile.ps1 into $target"
        }
    }
}

function Enable-TaskManager {
    # Locked-down/public PCs can disable Task Manager with a policy. Clear it
    # for this user; HKLM is only touched when the shell is already elevated.
    Write-Host 'Enabling Task Manager (clearing DisableTaskMgr)...'
    $elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    $paths = @('HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System')
    if ($elevated) {
        $paths += 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    } else {
        Write-Host 'Not elevated - HKCU only; run elevated to clear the machine-wide policy.'
    }

    foreach ($path in $paths) {
        try {
            if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }
            New-ItemProperty -LiteralPath $path -Name 'DisableTaskMgr' -PropertyType DWord -Value 0 -Force | Out-Null
            Write-Host "  DisableTaskMgr=0 at $path"
        } catch {
            # Best-effort: a locked key should not abort the bootstrap.
            Write-Host "Could not update $path (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

function Enable-WallpaperChanges {
    # Clear policy values that block wallpaper changes (HKCU always, HKLM when
    # elevated) so SystemParametersInfo can set the desktop wallpaper.
    $elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    $roots = @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies')
    if ($elevated) {
        $roots += 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies'
    } else {
        Write-Host 'Not elevated - HKCU wallpaper policy only; run elevated to clear the machine-wide policy.'
    }
    foreach ($root in $roots) {
        $activeDesktop = Join-Path $root 'ActiveDesktop'
        $system = Join-Path $root 'System'
        foreach ($path in @($activeDesktop, $system)) {
            try { if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null } }
            catch { Write-Host "Could not create $path (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow }
        }
        foreach ($item in @(
            @{ Path = $activeDesktop; Name = 'NoChangingWallPaper' },
            @{ Path = $system;        Name = 'NoDispBackgroundPage' }
        )) {
            try {
                New-ItemProperty -LiteralPath $item.Path -Name $item.Name -PropertyType DWord -Value 0 -Force | Out-Null
                Write-Host "  $($item.Name)=0 at $($item.Path)"
            } catch {
                Write-Host "Could not clear $($item.Name) at $($item.Path) (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
        foreach ($name in @('Wallpaper', 'WallpaperStyle', 'TileWallpaper')) {
            try { Remove-ItemProperty -LiteralPath $system -Name $name -ErrorAction Stop; Write-Host "  removed forced $name policy" }
            catch { }
        }
    }
}

function Set-SkoopWallpaper {
    param([string]$Path)
    if (-not $Path) {
        $imagesDir = Join-Path $env:LOCALAPPDATA 'skoop\wallpapers\aesthetic-wallpapers\images'
        if (Test-Path -LiteralPath $imagesDir) {
            $images = @(Get-ChildItem -LiteralPath $imagesDir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -match '^\.(jpg|jpeg|png|webp|bmp)$' })
            if ($images.Count -gt 0) { $Path = ($images | Get-Random).FullName }
        }
    }
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        Write-Host 'No wallpaper image available - skipping desktop wallpaper.'
        return
    }
    if (-not ('SkoopWallpaper' -as [type])) {
        Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public class SkoopWallpaper {
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
}
'@
    }
    if ([SkoopWallpaper]::SystemParametersInfo(0x0014, 0, $Path, 0x03) -eq 0) {
        Write-Host "Could not set wallpaper '$Path' (Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))." -ForegroundColor Yellow
        return
    }
    $desktop = 'HKCU:\Control Panel\Desktop'
    try {
        New-ItemProperty -LiteralPath $desktop -Name 'Wallpaper' -PropertyType String -Value $Path -Force | Out-Null
        New-ItemProperty -LiteralPath $desktop -Name 'WallpaperStyle' -PropertyType String -Value '10' -Force | Out-Null
        New-ItemProperty -LiteralPath $desktop -Name 'TileWallpaper' -PropertyType String -Value '0' -Force | Out-Null
    } catch {
        Write-Host "Wallpaper set, but the style could not be persisted (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
    }
    Write-Host "Desktop wallpaper set: $Path"
}

function Show-TailscaleSignInHint {
    # The daemon and tray app work without the CLI; only peer listing needs it.
    # Probe it so the sign-in advice is right, and never fail the bootstrap on it.
    $tailscale = Get-Command tailscale -ErrorAction SilentlyContinue
    if (-not $tailscale) {
        Write-Host 'Tailscale CLI not found - sign in from the Tailscale tray icon.' -ForegroundColor Yellow
        return
    }
    $raw = (& cmd /c ('"{0}" status 2>&1' -f $tailscale.Source) | Out-String)
    if ($LASTEXITCODE -ne 0) {
        $line = ($raw -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
        if (-not $line) { $line = "exit code $LASTEXITCODE" }
        Write-Host "Tailscale CLI cannot reach the daemon ($($line.Trim())); use the tray icon to sign in." -ForegroundColor Yellow
        return
    }
    if ($raw -match 'Logged out|NeedsLogin|not logged in|stopped') {
        Write-Host 'Tailscale is running but not signed in - sign in from the tray icon or run `tailscale up`.' -ForegroundColor Yellow
    } else {
        Write-Host 'Tailscale is connected.'
    }
}

function Start-TailscaleDaemon {
    # Scoop ships tailscaled but not the Windows service. Prefer the service
    # when the official installer created it; otherwise run the shim directly.
    # Login is interactive (tray icon or `tailscale up`), so it is left to you.
    Write-Host 'Starting Tailscale...'
    $service = Get-Service -Name 'Tailscale' -ErrorAction SilentlyContinue
    if ($service) {
        try {
            if ($service.Status -ne 'Running') { Start-Service -Name 'Tailscale' }
            Write-Host 'Tailscale service is running.'
        } catch {
            Write-Host "Could not start the Tailscale service (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
        }
        try {
            if ((Get-Service -Name 'Tailscale' -ErrorAction SilentlyContinue).StartType -ne 'Automatic') {
                Set-Service -Name 'Tailscale' -StartupType Automatic
                Write-Host 'Tailscale service set to Automatic.'
            }
        } catch {
            Write-Host "Could not set Tailscale to Automatic (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
        }
    } else {
        $tailscaled = Get-Command tailscaled -ErrorAction SilentlyContinue
        if (-not $tailscaled) { Write-Host 'tailscaled not on PATH - skipping.' }
        elseif (Get-Process -Name 'tailscaled' -ErrorAction SilentlyContinue) {
            Write-Host 'tailscaled is already running.'
        } else {
            try {
                Start-Process -FilePath $tailscaled.Source -WindowStyle Hidden
                Write-Host 'Launched tailscaled from Scoop.'
            } catch {
                Write-Host "Could not launch tailscaled (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    }
    Show-TailscaleSignInHint
}

# 1. Install Scoop if it is missing (no admin needed unless already elevated).
if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
    $installer = Join-Path $env:TEMP 'install-scoop.ps1'
    Invoke-WebRequest -UseBasicParsing 'https://get.scoop.sh' -OutFile $installer
    Unblock-File $installer
    $elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    & $installer -RunAsAdmin:$elevated
}
$env:Path = "$env:USERPROFILE\scoop\shims;$env:Path"

# 2. Allow local scripts, then hook the repo-managed profile into $PROFILE.
Set-SkoopExecutionPolicy
Install-ProfileHook
if (-not (Test-SkoopProfileLoads)) {
    Write-Host 'Profile did not load in a fresh shell - check Get-ExecutionPolicy -List and your $PROFILE.' -ForegroundColor Red
}

# 3. Clear the Task Manager policy.
Enable-TaskManager

# 4. Buckets are git repos, so git must exist before the phase import.
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { scoop install git }
Ensure-SkoopClone

# 5. Install manifests/scoop.json in phases: phase 1 is the fast essentials
#    (PowerShell 7, Rio first, then Herdr, Vicinae and Tailscale), heavy downloads last.
. (Join-Path $repo 'core\scoop-phases.ps1')
$skipUniKey = (-not $ForceUniKey) -and (Test-UniKeyInstalled)
if ($skipUniKey) {
    Write-Host 'UniKey already installed - keeping the existing copy (-ForceUniKey overrides).'
}
$phaseResult = Invoke-SkoopPhases -Scoop 'scoop' `
    -ManifestPath (Join-Path $repo 'manifests\scoop.json') `
    -PhasesPath (Join-Path $repo 'manifests\phases.json') `
    -ExcludeApps $(if ($skipUniKey) { @('unikey') } else { @() }) `
    -SkipInstalled -Force:$ForceInstall `
    -AfterPhase {
        param($phase)
        if ($phase.Name -ne 'core-terminal') { return }
        # Finish Rio and Vicinae before the slower phases start.
        foreach ($script in @('apps\rio\configure.ps1', 'apps\vicinae\configure.ps1', 'apps\vicinae\enable-autostart.ps1')) {
            $path = Join-Path $repo $script
            if (-not (Test-Path $path)) { continue }
            try { & $path }
            catch { Write-Host "  $script failed (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow }
        }
        # Tailscale is in this phase so the QR/URL sign-in happens before Firefox.
        # Once connected, restore Vicinae, Pear Desktop, Firefox and Atuin from the
        # shutdown backup (once per machine) and open Rio with Herdr in ~/repos.
        Start-TailscaleDaemon
        $tailscaleConfig = Join-Path $repo 'apps\tailscale\configure.ps1'
        if (Test-Path $tailscaleConfig) {
            try { & $tailscaleConfig -SignIn -RestoreVicinae -RestorePearDesktop -BackupUser $BackupUser @restoreAppsArgs }
            catch { Write-Host "  Tailscale sign-in / restore failed (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow }
        }
        Start-HerdrInRio
    }

Install-FirefoxPolicies (Join-Path $repo 'apps\firefox\policies.template.json')
Set-FirefoxDefaultBrowser

# 5a. Configure UniKey without the GUI (Unicode + VNI, Vietnamese on, autostart).
$unikeyConfig = Join-Path $repo 'apps\unikey\configure.ps1'
if (Test-Path $unikeyConfig) {
    try { & $unikeyConfig -Force:$ForceUniKey }
    catch { Write-Host "UniKey config failed (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow }
}

# 6. Start Tailscale (daemon/service only; login stays manual), restore OpenCode
#    config/credentials from the shutdown backup (the app phases installed its
#    CLI) and retry the Firefox/Atuin restores from phase 1 (markers make an
#    earlier success a no-op), then tag this device in the tailnet (idempotent
#    and non-fatal when not signed in).
Start-TailscaleDaemon
$tailscaleConfig = Join-Path $repo 'apps\tailscale\configure.ps1'
if (Test-Path $tailscaleConfig) {
    try { & $tailscaleConfig -RestoreOpenCode -BackupUser $BackupUser @restoreAppsArgs }
    catch { Write-Host "OpenCode / Firefox / Atuin restore or tailnet tagging failed (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow }
}

# 7. Offer a temporary SSH key + Herdr remote setup (interactive).
$herdrSsh = Join-Path $repo 'apps\herdr\setup-ssh.ps1'
if (Test-Path $herdrSsh) {
    try { & $herdrSsh }
    catch { Write-Host "Herdr SSH setup failed (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow }
}

# 8. Default the Rust toolchain to GNU when none is configured yet.
$scoopRoot = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $env:USERPROFILE 'scoop' }
$cargoBin = Join-Path $scoopRoot 'persist\rustup\.cargo\bin'
if (Test-Path $cargoBin) { $env:Path = "$cargoBin;$env:Path" }
if (Get-Command rustup -ErrorAction SilentlyContinue) {
    # A fresh rustup has no active toolchain: it writes to stderr and exits 1.
    # Under $ErrorActionPreference='Stop', PowerShell 5.1 turns that into a
    # terminating NativeCommandError, so go through cmd and check $LASTEXITCODE.
    $null = & cmd /c 'rustup show active-toolchain 2>&1'
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'Setting GNU toolchain as the default Rust toolchain.'
        & cmd /c 'rustup default stable-x86_64-pc-windows-gnu 2>&1'
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Rust toolchain setup failed (non-fatal): exit $LASTEXITCODE" -ForegroundColor Yellow
        }
    } else {
        Write-Host 'Rust toolchain already set; keeping it.'
    }
}

# 9. Check (and only if needed) let ShareX own PrtSc: Windows otherwise hands
#    the key to the Snipping Tool. Re-runs leave an applied fix untouched.
$sharexFix = Join-Path $repo 'apps\sharex\fix-printscreen.ps1'
if (Test-Path $sharexFix) {
    try { & $sharexFix }
    catch {
        # Cosmetic fix: never let it abort the bootstrap (z/atuin are already wired).
        Write-Host "ShareX fix failed (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# 10. Offer gh auth login (if needed), then wire gh into git as credential helper.
$ghAuth = Join-Path $repo 'apps\github\setup-auth.ps1'
if (Test-Path $ghAuth) {
    try { & $ghAuth -SkipLogin:$SkipGhLogin }
    catch { Write-Host "GitHub auth setup failed (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow }
}

# 11. Set the git author identity used for commits.
$gitIdentity = Join-Path $repo 'apps\git\setup-identity.ps1'
if (Test-Path $gitIdentity) {
    try { & $gitIdentity }
    catch { Write-Host "Git identity setup failed (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow }
}

# 12. Apply the repo-managed Zed config (settings/keymap/tasks).
$zedConfig = Join-Path $repo 'apps\zed\configure.ps1'
if (Test-Path $zedConfig) {
    try { & $zedConfig }
    catch { Write-Host "Zed config failed (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow }
}

# 13. Deploy ~/.config/whkdrc, start/reload Komorebi's hotkey daemon and
#     auto-hide the Windows taskbar via apps\komorebi\configure.ps1.
$komorebiConfig = Join-Path $repo 'apps\komorebi\configure.ps1'
if (Test-Path $komorebiConfig) {
    try { & $komorebiConfig }
    catch { Write-Host "Komorebi hotkey setup failed (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow }
}

# 14. Deploy the repo-managed YASB status bar config and start YASB.
$yasbConfig = Join-Path $repo 'apps\yasb\configure.ps1'
if (Test-Path $yasbConfig) {
    try { & $yasbConfig }
    catch { Write-Host "YASB config failed (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow }
}

# 14b. Clear wallpaper restrictions and set a desktop wallpaper.
if ($NoWallpaper -or $env:SKOOP_NO_WALLPAPER -eq '1') {
    Write-Host 'Skipping wallpaper change (-NoWallpaper).'
} else {
    try {
        Enable-WallpaperChanges
        Set-SkoopWallpaper -Path $Wallpaper
    } catch {
        Write-Host "Wallpaper setup failed (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# 15. Add the `n` Nushell shortcut for PowerShell (profile.ps1) and cmd (AutoRun).
$nuSetup = Join-Path $repo 'apps\nushell\setup.ps1'
if (Test-Path $nuSetup) {
    try { & $nuSetup }
    catch { Write-Host "Nushell shortcut setup failed (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow }
}

# 16. Deploy the Starship prompt (config for PowerShell, Clink loader for cmd).
$starshipConfig = Join-Path $repo 'apps\starship\configure.ps1'
if (Test-Path $starshipConfig) {
    try { & $starshipConfig }
    catch { Write-Host "Starship setup failed (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow }
}

# 16b. Set marimo's permanent display theme to dark, preserving other settings.
$marimoConfig = Join-Path $repo 'apps\marimo\configure.ps1'
if (Test-Path $marimoConfig) {
    try { & $marimoConfig }
    catch { Write-Host "marimo config failed (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow }
}

# 17. Check the Windows theme and enable Dark Mode (apps + system), idempotently.
$darkMode = Join-Path $repo 'core\set-dark-mode.ps1'
if (Test-Path $darkMode) {
    try { & $darkMode }
    catch { Write-Host "Dark Mode setup failed (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow }
}

Write-Host "Done. Open a new PowerShell window, then try: z .." -ForegroundColor Green
Write-Host "git push will use your gh login (no username prompt)." -ForegroundColor Green
Write-Host "Commits will be authored as Keios <git@taquangkhoi.com>." -ForegroundColor Green
Write-Host "Vicinae starts at login; press Ctrl+Space to open the launcher." -ForegroundColor Green
Write-Host "Rio font size / zoom is 16." -ForegroundColor Green
Write-Host "UniKey: Unicode + VNI, Vietnamese on, no startup dialog, starts at login." -ForegroundColor Green
Write-Host "Komorebi hotkeys are ready (see komorebi\whkdrc)." -ForegroundColor Green
Write-Host "YASB status bar is configured; fill ~\.config\yasb\.env for weather/wallpapers." -ForegroundColor Green
Write-Host "Type 'n' in PowerShell or cmd to open Nushell." -ForegroundColor Green
Write-Host "Starship is the prompt in new PowerShell and cmd windows." -ForegroundColor Green
Write-Host "marimo uses dark mode (theme set in ~\.marimo.toml)." -ForegroundColor Green
Write-Host "Dark Mode is on for apps and the system." -ForegroundColor Green
Write-Host "Firefox profile and Atuin history restored from acer-ubuntu once per machine (markers firefox-restore.done / atuin-restore.done; -ForceFirefoxRestore / -ForceAtuinRestore repeat, -SkipFirefoxRestore / -SkipAtuinRestore opt out)." -ForegroundColor Green
Write-Host "Start Zed once to install its extensions (PowerShell, HTML, Dockerfile, Compose, TOML, Nix, SQL)." -ForegroundColor Green
