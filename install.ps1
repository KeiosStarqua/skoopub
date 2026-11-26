#Requires -Version 5.1
<#
.SYNOPSIS
    One-shot Windows bootstrap: install Scoop, restore packages, wire up the shell config.

.DESCRIPTION
    - Installs Scoop if it is missing (per-user, or system-wide when run elevated).
    - Makes sure git is available, then installs Firefox before WezTerm and asks
      Firefox to become the default browser (Windows may ask you to confirm).
    - Installs a Firefox policy: auto-installs Bitwarden, mymind and
      "I still don't care about cookies", shows the bookmarks toolbar, adds a
      skoopub bookmarks folder (Hacker News, mymind, Scoop, OpenCode,
      YouTube to Transcript), sets ChatGPT as the
      homepage, and disables Firefox's save-password prompt.
    - Runs `scoop import scoop.json` (buckets + apps).
    - Starts Tailscale after the import (Windows service if present, otherwise
      the Scoop `tailscaled` shim); login is left to you (`tailscale up` or the
      tray icon - the CLI may be missing or unable to reach the daemon on Windows).
    - Offers a one-prompt Herdr remote setup via setup-herdr-ssh.ps1: pick a
      machine from the tailnet list (or type its IP/MagicDNS name when the CLI
      is not usable), then save it in Herdr (`herdr machine add`) over Tailscale
      SSH so it shows up in your Herdr sidebar. No keys, passwords or machine
      addresses are stored in the repo.
    - Keeps a UniKey that is already installed (e.g. on a public PC) instead of
      adding a second copy; -ForceUniKey installs the Scoop build anyway.
    - Adds a dot-source line for profile.ps1 to your PowerShell $PROFILE early on,
      so zoxide/atuin are configured even if a later, optional step fails.
    - Enables Task Manager by clearing DisableTaskMgr for the current user (and
      machine-wide when elevated); a failure is reported but does not abort.
    - Applies fix-sharex-printscreen.ps1 so ShareX owns the PrtSc key; a failure
      there is reported but does not abort the bootstrap.
    - Copies the repo-managed Zed settings/keymap/tasks into %APPDATA%\Zed (old
      files are backed up); Zed installs its declared extensions on next start.
    - Copies the repo-managed Rio config into %LOCALAPPDATA%\rio\config.toml,
      setting the font size (Rio's zoom) to 16; Rio hot-reloads it on change.
    - Offers to run `gh auth login` (only when needed) and runs `gh auth setup-git`
      so `git push` uses the GitHub CLI token instead of prompting for a username.
    - Sets the global git author identity to Keios <git@taquangkhoi.com> via
      setup-git-identity.ps1, so commits are attributed correctly on every repo.
    - Registers `vicinae-server.exe` in the per-user Startup folder and starts it
      now, so the Vicinae global shortcut works after every sign-in.
    - Sets the Vicinae global toggle shortcut to Ctrl+Space via a repo-managed
      config import (existing Vicinae settings are preserved).
    - Deploys a conflict-free whkdrc and a Komorebi config (tight 4px workspace /
      2px container padding plus initial-workspace rules: Rio/Firefox on 1,
      Zed/VS Code/Pear Desktop on 2, Columns on workspace 1) to ~/.config via
      configure-komorebi.ps1, then starts/reloads whkd (and Komorebi when needed)
      and a watcher that keeps Rio left / Firefox right in the Terminal workspace.
    - Deploys the repo-managed YASB status bar (config.yaml, styles.css and a .env
      template) via configure-yasb.ps1 and starts YASB for the Komorebi UI.
    - Adds an `n` alias for Nushell in PowerShell (profile.ps1) and a cmd.exe
      AutoRun doskey macro via setup-nushell.ps1, preserving existing AutoRun entries.

    Interactive CLI: when gum (charm-gum) is available, the script opens a menu
    to choose Full setup / Configure only / Connect Herdr only / Quit. It falls
    back to a numbered prompt, and skips the menu when -NoMenu or any other
    option is given (or the shell is non-interactive).

    Works two ways:
      Local :  .\install.ps1
      Remote:  irm https://raw.githubusercontent.com/KeiosStarqua/skoopub/main/install.ps1 | iex

.PARAMETER RepoRawBase
    Raw URL base used to fetch scoop.json / profile.ps1 when the script is piped in
    and there is no local checkout. Override this if you use a fork.

.PARAMETER ForceUniKey
    Install the Scoop UniKey package even if another UniKey is already installed.

.PARAMETER SkipGhLogin
    Skip the interactive `gh auth login` prompt; only wire up an existing gh login.

.PARAMETER HerdrPeer
    Switch: use the interactive gum picker to choose the Herdr machine
    (no value needed). Use -Peer to supply a name/IP non-interactively.

.PARAMETER Peer
    Tailnet IP or MagicDNS name of the Herdr machine. Skips the picker.
    Defaults to $env:SKOOP_HERDR_PEER for piped runs.

.PARAMETER HerdrUser
    SSH user to use on the Herdr machine (otherwise auto-detected).

.PARAMETER SkipHerdrConnect
    Do not run the Herdr remote step (useful for unattended installs).

.PARAMETER NoMenu
    Skip the interactive gum menu and run the full setup directly. The menu is
    also skipped for non-interactive shells and when any other option is passed.

.PARAMETER NoGum
    Force the numbered prompt instead of gum (or set $env:SKOOP_NO_GUM=1). Useful
    in terminals where gum cannot draw its TUI.

.EXAMPLE
    # One command: configure this machine, then pick a tailnet machine and add it to Herdr.
    powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1

.EXAMPLE
    # Force the interactive peer picker.
    .\install.ps1 -HerdrPeer

    # Same, but with the machine/user supplied so nothing is prompted.
    .\install.ps1 -Peer <machine> -HerdrUser <user> -SkipGhLogin

.EXAMPLE
    irm https://raw.githubusercontent.com/KeiosStarqua/skoopub/main/install.ps1 | iex
#>
[CmdletBinding()]
param(
    [string]$RepoRawBase = 'https://raw.githubusercontent.com/KeiosStarqua/skoopub/main',
    [switch]$ForceUniKey,
    [switch]$SkipGhLogin,
    [switch]$HerdrPeer,
    [string]$Peer = "$env:SKOOP_HERDR_PEER",
    [string]$HerdrUser = "$env:SKOOP_HERDR_USER",
    [switch]$SkipHerdrConnect,
    [switch]$NoMenu,
    [switch]$NoGum,
    [switch]$Help
)

# Env vars let the piped (`irm ... | iex`) form pass the same options.
if ($env:SKOOP_SKIP_HERDR -eq '1') { $SkipHerdrConnect = $true }
if ($NoGum) { $env:SKOOP_NO_GUM = '1' }

# `--help` arrives in $args with CmdletBinding; handle it before any side effect.
# --help binds to the first positional string parameter ($RepoRawBase) when
# the script is invoked as `& .\install.ps1 --help`, so check that too.
if ($Help -or $RepoRawBase -in @('--help', '-h', '/?', 'help') -or
    ($args | Where-Object { $_ -in @('--help', '-h', '/?', 'help') })) {
    Write-Host @'
skoop install.ps1 - interactive Windows setup

Usage:
  .\install.ps1                          # menu: Full / Configure only / Herdr only / Quit
  .\install.ps1 -NoMenu                  # skip the menu, run everything
  .\install.ps1 -HerdrPeer              # interactive peer picker
  .\install.ps1 -Peer <machine> -HerdrUser <user>
  .\install.ps1 -SkipHerdrConnect        # configure only
  irm https://raw.githubusercontent.com/KeiosStarqua/skoopub/main/install.ps1 | iex

Options: -ForceUniKey -SkipGhLogin -HerdrPeer -Peer -HerdrUser -SkipHerdrConnect -NoMenu -NoGum -Help
Piped runs use env vars: SKOOP_HERDR_PEER, SKOOP_HERDR_USER, SKOOP_SKIP_HERDR, SKOOP_NO_MENU, SKOOP_NO_GUM
'@
    return
}

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message)   { Write-Host "    $Message" -ForegroundColor DarkGray }

function Invoke-SetupMenu {
    # Interactive CLI entry point. gum is used when available (charm-gum from
    # scoop.json); otherwise fall back to a numbered prompt. Returns a mode.
    $items = @(
        @{ Key = 'full';      Label = 'Full setup + connect Herdr' },
        @{ Key = 'configure'; Label = 'Configure only (skip Herdr)' },
        @{ Key = 'herdr';     Label = 'Connect Herdr only' },
        @{ Key = 'quit';      Label = 'Quit' }
    )
    if (-not [Environment]::UserInteractive) {
        Write-Ok 'Non-interactive shell - running the full setup (use -NoMenu to silence this)'
        return 'full'
    }

    $gum = Get-Command gum -ErrorAction SilentlyContinue
    if ($gum -and $env:SKOOP_NO_GUM -ne '1') {
        # gum draws its UI on stderr and writes only the answer to stdout.
        # PowerShell pipes stderr for native commands (and PS 5.1 turns it into a
        # terminating NativeCommandError under $ErrorActionPreference='Stop'), so
        # merging it with 2>&1 leaves gum with no terminal to draw on and it
        # returns nothing. Let cmd send stderr to the console and collect stdout
        # through a temp file, so the picker can actually render.
        Write-Host 'Choose an action:' -ForegroundColor Cyan
        $labels  = @($items.Label | ForEach-Object { '"' + $_ + '"' }) -join ' '
        $answerFile = [System.IO.Path]::GetTempFileName()
        try {
            $cmdLine = '"{0}" choose --header "skoop setup" {1} > "{2}" 2> CON' -f $gum.Source, $labels, $answerFile
            $null = & cmd /c $cmdLine
            $gumExit = $LASTEXITCODE
            $raw = ''
            if (Test-Path -LiteralPath $answerFile) {
                $raw = [System.IO.File]::ReadAllText($answerFile, [System.Text.Encoding]::UTF8)
            }
            $lines = @($raw -split "`r?`n" | ForEach-Object { $_ -replace "`e\[[0-9;?]*[a-zA-Z]", '' })
            $choice = ''
            foreach ($line in $lines) {
                foreach ($item in $items) {
                    if ($line.Trim() -eq $item.Label) { $choice = $item.Label; break }
                }
                if ($choice) { break }
            }
            if ($gumExit -eq 0 -and $choice) {
                foreach ($item in $items) { if ($choice -eq $item.Label) { return $item.Key } }
                return 'full'
            }
            Write-Ok 'gum menu did not return a choice - using the numbered prompt'
        } catch {
            Write-Ok "gum menu failed ($($_.Exception.Message)) - using the numbered prompt"
        } finally {
            Remove-Item -LiteralPath $answerFile -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host 'Choose an action (install gum for a nicer menu):' -ForegroundColor Cyan
    for ($i = 0; $i -lt $items.Count; $i++) {
        Write-Host ('  [{0}] {1}' -f ($i + 1), $items[$i].Label)
    }
    $answer = Read-Host 'Action [1 = full, Enter = full]'
    if (-not $answer) { return 'full' }
    if ($answer -notmatch '^\d+$') { return 'quit' }
    $n = [int]$answer
    if ($n -lt 1 -or $n -gt $items.Count) { return 'quit' }
    return $items[$n - 1].Key
}

function Connect-HerdrRemote {
    if ($SkipHerdrConnect) { Write-Ok 'Skipping the Herdr remote step'; return }
    if (-not (Test-Path $herdrSsh)) { Write-Ok 'setup-herdr-ssh.ps1 not found - skipping'; return }
    Write-Step 'Picking a tailnet machine for Herdr'
    $herdrArgs = @()
    if ($Peer) { $herdrArgs += @('-Peer', $Peer) }
    if ($HerdrUser) { $herdrArgs += @('-User', $HerdrUser) }
    try {
        & $herdrSsh @herdrArgs
    } catch {
        Write-Host "    Herdr remote setup failed (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Enable-TaskManager {
    # Locked-down/public PCs can disable Task Manager with a policy. Clear it
    # for this user; HKLM is only touched when the shell is already elevated.
    Write-Step 'Enabling Task Manager (clearing DisableTaskMgr)'
    $elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    $paths = @('HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System')
    if ($elevated) {
        $paths += 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    } else {
        Write-Ok 'not elevated - HKCU only (re-run elevated to clear the machine-wide policy)'
    }

    foreach ($path in $paths) {
        try {
            if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }
            New-ItemProperty -LiteralPath $path -Name 'DisableTaskMgr' -PropertyType DWord -Value 0 -Force | Out-Null
            Write-Ok "DisableTaskMgr=0 at $path"
        } catch {
            # Best-effort: a locked key should not abort the rest of the setup.
            Write-Host "    Could not update $path - $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

function Show-TailscaleSignInHint {
    # Tailscale's daemon and tray app work without the CLI; only peer listing
    # needs it. Probe the CLI so the sign-in advice matches this machine, and
    # never let a broken CLI fail the bootstrap.
    $tailscale = Get-Command tailscale -ErrorAction SilentlyContinue
    if (-not $tailscale) {
        Write-Host '    Tailscale CLI not found - sign in from the Tailscale tray icon.' -ForegroundColor Yellow
        return
    }
    $raw = (& cmd /c ('"{0}" status 2>&1' -f $tailscale.Source) | Out-String)
    if ($LASTEXITCODE -ne 0) {
        $line = ($raw -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
        if (-not $line) { $line = "exit code $LASTEXITCODE" }
        Write-Host "    Tailscale CLI cannot reach the daemon ($($line.Trim())); use the tray icon to sign in." -ForegroundColor Yellow
        return
    }
    if ($raw -match 'Logged out|NeedsLogin|not logged in|stopped') {
        Write-Ok 'Tailscale is running but not signed in - sign in from the tray icon or run `tailscale up`'
    } else {
        Write-Ok 'Tailscale is connected'
    }
}

function Start-TailscaleDaemon {
    # Scoop ships tailscaled but not the Windows service. Prefer the service
    # when the official installer created it; otherwise run the shim directly.
    # Login is interactive (tray icon or `tailscale up`), so it is left to you.
    Write-Step 'Starting Tailscale'
    $service = Get-Service -Name 'Tailscale' -ErrorAction SilentlyContinue
    if ($service) {
        try {
            if ($service.Status -ne 'Running') { Start-Service -Name 'Tailscale' }
            Write-Ok 'Tailscale service is running'
        } catch {
            Write-Host "    Could not start the Tailscale service (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
        }
        try {
            if ((Get-Service -Name 'Tailscale' -ErrorAction SilentlyContinue).StartType -ne 'Automatic') {
                Set-Service -Name 'Tailscale' -StartupType Automatic
                Write-Ok 'Tailscale service set to Automatic'
            }
        } catch {
            Write-Host "    Could not set Tailscale to Automatic (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
        }
    } else {
        $tailscaled = Get-Command tailscaled -ErrorAction SilentlyContinue
        if (-not $tailscaled) {
            Write-Ok 'tailscaled not on PATH - skipping'
        } elseif (Get-Process -Name 'tailscaled' -ErrorAction SilentlyContinue) {
            Write-Ok 'tailscaled is already running'
        } else {
            try {
                Start-Process -FilePath $tailscaled.Source -WindowStyle Hidden
                Write-Ok 'launched tailscaled from Scoop'
            } catch {
                Write-Host "    Could not launch tailscaled (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    }
    Show-TailscaleSignInHint
}

function Set-FirefoxDefaultBrowser {
    # Firefox owns its UserChoice hashes; writing them by hand is blocked on
    # modern Windows, so let Firefox set http/https/.htm/.html itself. Windows 11
    # may still open Settings for confirmation - that is fine, not a bootstrap error.
    $firefox = Get-Command firefox -ErrorAction SilentlyContinue
    if (-not $firefox) { Write-Ok 'firefox not on PATH - skipping default browser step'; return }

    $httpChoice = 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\http\UserChoice'
    $progId = (Get-ItemProperty -Path $httpChoice -ErrorAction SilentlyContinue).ProgId
    if ($progId -match '^Firefox') {
        Write-Ok 'Firefox is already the default browser'
        return
    }

    try {
        Start-Process -FilePath $firefox.Source -ArgumentList '--setDefaultBrowser' | Out-Null
        Write-Ok 'requested Firefox as default browser (confirm in Settings if prompted)'
    } catch {
        Write-Host "    Could not set Firefox as default browser (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Install-FirefoxPolicies {
    param([string]$Template)

    # Scoop persists Firefox's distribution folder, so policies.json survives
    # Firefox updates. Firefox reads it at startup (about:policies shows it).
    $firefoxDir = Join-Path $env:SCOOP 'apps\firefox\current'
    if (-not (Test-Path (Join-Path $firefoxDir 'firefox.exe'))) {
        Write-Ok 'Scoop Firefox install not found - skipping extension policy'
        return
    }
    if (-not (Test-Path $Template)) {
        Write-Ok 'firefox-policies.template.json not found - skipping extension policy'
        return
    }

    $distDir = Join-Path $firefoxDir 'distribution'
    New-Item -ItemType Directory -Force -Path $distDir | Out-Null
    Copy-Item -LiteralPath $Template -Destination (Join-Path $distDir 'policies.json') -Force
    Write-Ok 'Firefox policy installed (restart Firefox to apply it)'
    if (Get-Process -Name firefox -ErrorAction SilentlyContinue) {
        Write-Ok 'Firefox is running - close and reopen it to load the policy'
    }
}

function Install-ProfileHook {
    # Wire the repo-managed profile into $PROFILE. Run early so zoxide/atuin are
    # configured even if a later (optional) step fails and aborts the bootstrap.
    Write-Step 'Wiring profile.ps1 into your PowerShell profile'
    $hook = "# Load the repo-managed shell config. Edit that file, not this one.`n. `"$profileScript`""

    New-Item -ItemType Directory -Force -Path (Split-Path $PROFILE) | Out-Null
    $lines = if (Test-Path $PROFILE) { @(Get-Content -Path $PROFILE) } else { @() }

    # Replace any earlier hook instead of trusting it: a stale one can point at a
    # profile.ps1 that no longer exists (e.g. ~\skoop\profile.ps1) and then silently
    # load nothing, which looks like the packages are missing.
    $stale   = 'skoop[\\/]profile\.ps1|\$skoopProfile|^# Load the repo-managed shell config|' + [regex]::Escape($profileScript)
    $body    = (($lines | Where-Object { $_ -notmatch $stale }) -join "`r`n").TrimEnd()
    $desired = if ($body) { "$body`r`n$hook" } else { $hook }

    $existing = if (Test-Path $PROFILE) { Get-Content -Raw -Path $PROFILE } else { '' }
    if ($existing.TrimEnd() -eq $desired) {
        Write-Ok "already present in $PROFILE"
    } else {
        Set-Content -Path $PROFILE -Value $desired -Encoding UTF8
        Write-Ok "wired into $PROFILE"
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

function Find-ScoopShims {
    @(
        (Join-Path $env:USERPROFILE 'scoop\shims'),
        (Join-Path $env:ProgramData 'scoop\shims')
    ) | Where-Object { Test-Path (Join-Path $_ 'scoop.cmd') } | Select-Object -First 1
}

# --- 0. Interactive CLI menu (gum when available) ----------------------------
$runMode = 'full'
if (-not $NoMenu -and -not $HerdrPeer -and $env:SKOOP_NO_MENU -ne '1' -and
    -not ($ForceUniKey -or $SkipGhLogin -or $SkipHerdrConnect -or $Peer -or $HerdrUser)) {
    $runMode = Invoke-SetupMenu
}
if ($HerdrPeer) { $runMode = 'herdr' }
if ($runMode -eq 'quit') {
    Write-Host 'Cancelled - nothing changed.' -ForegroundColor Yellow
    return
}
if ($runMode -eq 'configure') { $SkipHerdrConnect = $true }

# --- 1. Locate the repo files ------------------------------------------------
$repoRoot = $null
foreach ($candidate in @($PSScriptRoot, (Get-Location).Path)) {
    if ($candidate -and (Test-Path (Join-Path $candidate 'scoop.json'))) {
        $repoRoot = $candidate
        break
    }
}

if (-not $repoRoot) {
    Write-Step 'No local checkout found - downloading repo files'
    $repoRoot = Join-Path $env:LOCALAPPDATA 'skoop'
    New-Item -ItemType Directory -Force -Path $repoRoot | Out-Null
    $repoFiles = @(
        'scoop.json', 'profile.ps1', 'fix-sharex-printscreen.ps1',
        'sharex-hotkeys.template.json', 'firefox-policies.template.json',
        'setup-gh-auth.ps1', 'configure-zed.ps1', 'setup-herdr-ssh.ps1',
        'setup-git-identity.ps1',
        'enable-vicinae-autostart.ps1', 'configure-vicinae.ps1',
        'configure-rio.ps1', 'configure-komorebi.ps1', 'configure-yasb.ps1',
        'setup-nushell.ps1',
        'configure-starship.ps1', 'starship/starship.toml',
        'zed/settings.json', 'zed/keymap.json', 'zed/tasks.json',
        'vicinae/keybinds.json', 'rio/config.toml', 'komorebi/whkdrc',
        'komorebi/komorebi.json', 'komorebi/pin-terminal-layout.ps1',
        'yasb/config.yaml', 'yasb/styles.css', 'yasb/.env.example'
    )
    foreach ($file in $repoFiles) {
        $dest = Join-Path $repoRoot $file
        New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
        Invoke-WebRequest -UseBasicParsing -Uri "$RepoRawBase/$file" -OutFile $dest
        Unblock-File $dest
        Write-Ok "fetched $file"
    }
}

$manifest       = Join-Path $repoRoot 'scoop.json'
$profileScript  = Join-Path $repoRoot 'profile.ps1'
$sharexFix      = Join-Path $repoRoot 'fix-sharex-printscreen.ps1'
$firefoxPolicies = Join-Path $repoRoot 'firefox-policies.template.json'
$ghAuth          = Join-Path $repoRoot 'setup-gh-auth.ps1'
$gitIdentity     = Join-Path $repoRoot 'setup-git-identity.ps1'
$zedConfig       = Join-Path $repoRoot 'configure-zed.ps1'
$rioConfig       = Join-Path $repoRoot 'configure-rio.ps1'
$herdrSsh        = Join-Path $repoRoot 'setup-herdr-ssh.ps1'
$vicinae         = Join-Path $repoRoot 'enable-vicinae-autostart.ps1'
$vicinaeConfig   = Join-Path $repoRoot 'configure-vicinae.ps1'
$komorebiConfig  = Join-Path $repoRoot 'configure-komorebi.ps1'
$yasbConfig      = Join-Path $repoRoot 'configure-yasb.ps1'
$nuSetup         = Join-Path $repoRoot 'setup-nushell.ps1'
$starshipConfig  = Join-Path $repoRoot 'configure-starship.ps1'
Write-Ok "repo root: $repoRoot"

if ($runMode -eq 'herdr') {
    Start-TailscaleDaemon
    Connect-HerdrRemote
    Write-Host ''
    Write-Host 'Done. Herdr machine saved - open Herdr and pick it from the sidebar; run the full setup to configure this machine.' -ForegroundColor Green
    return
}

# --- 2. Hook the repo-managed profile into $PROFILE --------------------------
# Done before anything that can fail, so `z`/`atuin` are always configured.
Install-ProfileHook

# --- 3. Clear the Task Manager policy ---------------------------------------
Enable-TaskManager

# --- 4. Install Scoop if its shims are missing -------------------------------
$shimDir = Find-ScoopShims
if (-not $shimDir) {
    Write-Step 'Installing Scoop'
    $installer = Join-Path $env:TEMP 'install-scoop.ps1'
    Invoke-WebRequest -UseBasicParsing 'https://get.scoop.sh' -OutFile $installer
    Unblock-File $installer

    $elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($elevated) {
        Write-Ok 'elevated shell detected - installing Scoop system-wide (C:\ProgramData\scoop)'
    }

    & $installer -RunAsAdmin:$elevated
    $shimDir = Find-ScoopShims
} else {
    Write-Ok "Scoop already installed ($shimDir)"
}

if (-not $shimDir) { throw 'Scoop installed but its shims directory was not found.' }

# --- 5. Put the shims on PATH for this process -------------------------------
$env:SCOOP = Split-Path $shimDir -Parent
$env:Path  = "$shimDir;$env:Path"
$scoop     = Join-Path $shimDir 'scoop.cmd'
Write-Ok "shims: $shimDir"

# --- 6. Buckets are git repos, so git must exist before scoop import ---------
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Step 'Installing git (required for Scoop buckets)'
    & $scoop install git
}

# --- 7. Install Firefox, then WezTerm, then Herdr --------------------------
Write-Step 'Installing Firefox first'
$extrasBucket = & $scoop bucket list 2>$null | Select-String -Pattern '^\s*extras\b' -Quiet
if (-not $extrasBucket) {
    & $scoop bucket add extras
    if ($LASTEXITCODE -ne 0) { throw "scoop bucket add extras failed with exit code $LASTEXITCODE." }
}
$firefoxInstalled = & $scoop list 2>$null | Select-String -Pattern '^\s*firefox\b' -Quiet
if (-not $firefoxInstalled) {
    & $scoop install extras/firefox
    if ($LASTEXITCODE -ne 0) { throw "scoop install extras/firefox failed with exit code $LASTEXITCODE." }
} else {
    Write-Ok 'Firefox already installed'
}
Install-FirefoxPolicies $firefoxPolicies
Set-FirefoxDefaultBrowser

Write-Step 'Installing WezTerm'
$weztermInstalled = & $scoop list 2>$null | Select-String -Pattern '^\s*wezterm\b' -Quiet
if (-not $weztermInstalled) {
    & $scoop install wezterm
    if ($LASTEXITCODE -ne 0) { throw "scoop install wezterm failed with exit code $LASTEXITCODE." }
} else {
    Write-Ok 'WezTerm already installed'
}

Write-Step 'Installing Herdr'
foreach ($app in @('herdr', 'herdr-core')) {
    $installed = & $scoop list 2>$null | Select-String -Pattern ("^\s*" + [regex]::Escape($app) + '\b') -Quiet
    if (-not $installed) {
        & $scoop install $app
        if ($LASTEXITCODE -ne 0) { throw "scoop install $app failed with exit code $LASTEXITCODE." }
    } else {
        Write-Ok "$app already installed"
    }
}

# --- 8. Restore buckets + apps ----------------------------------------------
$manifestToImport = $manifest
if (-not $ForceUniKey -and (Test-UniKeyInstalled)) {
    Write-Step 'UniKey already installed - keeping the existing copy'
    $json = Get-Content -Raw $manifest | ConvertFrom-Json
    $json.apps = @($json.apps | Where-Object { $_.Name -ne 'unikey' })
    $manifestToImport = Join-Path $env:TEMP 'skoop-scoop-no-unikey.json'
    $json | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestToImport -Encoding UTF8
    Write-Ok "importing without unikey ($manifestToImport)"
}

Write-Step "Importing $manifestToImport"
& $scoop import $manifestToImport
if ($LASTEXITCODE -ne 0) { throw "scoop import failed with exit code $LASTEXITCODE." }

# --- 9. Start Tailscale ------------------------------------------------------
Start-TailscaleDaemon

# --- 10. Tailnet machine selection + Herdr remote (interactive) -------------
Connect-HerdrRemote

# --- 11. Default Rust toolchain: GNU (no Visual Studio Build Tools needed) ---
$cargoBin = Join-Path $env:SCOOP 'persist\rustup\.cargo\bin'
if (Test-Path $cargoBin) { $env:Path = "$cargoBin;$env:Path" }
if (Get-Command rustup -ErrorAction SilentlyContinue) {
    # A fresh rustup has no active toolchain: it writes "error: no active toolchain"
    # to stderr and exits 1. Under $ErrorActionPreference='Stop', PowerShell 5.1
    # turns native stderr into a terminating NativeCommandError (even with
    # `2>$null`), which aborts the bootstrap before GNU is set. Run it through cmd
    # with stderr merged into stdout and inspect $LASTEXITCODE instead.
    $null = & cmd /c 'rustup show active-toolchain 2>&1'
    if ($LASTEXITCODE -ne 0) {
        Write-Step 'Setting GNU toolchain as the default Rust toolchain'
        & cmd /c 'rustup default stable-x86_64-pc-windows-gnu 2>&1'
        if ($LASTEXITCODE -ne 0) {
            Write-Host "    Could not set the Rust toolchain (non-fatal): exit $LASTEXITCODE" -ForegroundColor Yellow
        }
    } else {
        Write-Ok "Rust toolchain already set; keeping it"
    }
}

# --- 12. Let ShareX own the PrtSc key ---------------------------------------
if (Test-Path $sharexFix) {
    Write-Step 'Applying ShareX PrtSc fix'
    try {
        & $sharexFix
    } catch {
        # Cosmetic fix: never let it abort the bootstrap (z/atuin are already wired).
        Write-Host "    ShareX fix failed (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
    }
} else {
    Write-Ok 'fix-sharex-printscreen.ps1 not found - skipping'
}

# --- 13. GitHub CLI auth for git push (interactive unless -SkipGhLogin) -------
if (Test-Path $ghAuth) {
    Write-Step 'Setting up GitHub authentication for git'
    try {
        & $ghAuth -SkipLogin:$SkipGhLogin
    } catch {
        # Cosmetic/convenience step: never let it abort the rest of the setup.
        Write-Host "    GitHub auth setup failed (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
    }
} else {
    Write-Ok 'setup-gh-auth.ps1 not found - skipping'
}

# --- 14. Set the git author identity for commits ----------------------------
if (Test-Path $gitIdentity) {
    Write-Step 'Setting the git author identity (Keios)'
    try {
        & $gitIdentity
    } catch {
        Write-Host "    Git identity setup failed (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
    }
} else {
    Write-Ok 'setup-git-identity.ps1 not found - skipping'
}

# --- 15. Apply the repo-managed Zed config ----------------------------------
if (Test-Path $zedConfig) {
    Write-Step 'Applying Zed settings, keymap and tasks'
    try {
        & $zedConfig
    } catch {
        # Editor config is cosmetic: never let it abort the bootstrap.
        Write-Host "    Zed config failed (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
    }
} else {
    Write-Ok 'configure-zed.ps1 not found - skipping'
}

# --- 16. Apply the repo-managed Rio config (zoom 16) -------------------------
if (Test-Path $rioConfig) {
    Write-Step 'Applying the Rio config (font size / zoom 16)'
    try {
        & $rioConfig
    } catch {
        Write-Host "    Rio config failed (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
    }
} else {
    Write-Ok 'configure-rio.ps1 not found - skipping'
}

# --- 17. Auto-start Vicinae --------------------------------------------------
if (Test-Path $vicinae) {
    Write-Step 'Enabling Vicinae to start at login'
    try {
        & $vicinae
    } catch {
        Write-Host "    Vicinae autostart setup failed (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
    }
} else {
    Write-Ok 'enable-vicinae-autostart.ps1 not found - skipping'
}

# --- 18. Set the Vicinae global shortcut to Ctrl+Space ------------------------
if (Test-Path $vicinaeConfig) {
    Write-Step 'Setting the Vicinae global shortcut (Ctrl+Space)'
    try {
        & $vicinaeConfig
    } catch {
        Write-Host "    Vicinae shortcut setup failed (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
    }
} else {
    Write-Ok 'configure-vicinae.ps1 not found - skipping'
}

# --- 19. Apply the repo-managed Komorebi hotkeys -------------------------------
if (Test-Path $komorebiConfig) {
    Write-Step 'Deploying the Komorebi whkdrc and starting the hotkey daemon'
    try {
        & $komorebiConfig
    } catch {
        # Cosmetic/convenience step: never let it abort the bootstrap.
        Write-Host "    Komorebi hotkey setup failed (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
    }
} else {
    Write-Ok 'configure-komorebi.ps1 not found - skipping'
}

# --- 20. Apply the repo-managed YASB status bar config ------------------------
if (Test-Path $yasbConfig) {
    Write-Step 'Deploying the YASB status bar and starting it'
    try {
        & $yasbConfig
    } catch {
        # Cosmetic/convenience step: never let it abort the bootstrap.
        Write-Host "    YASB config failed (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
    }
} else {
    Write-Ok 'configure-yasb.ps1 not found - skipping'
}

# --- 21. Set up the Nushell shortcut for PowerShell and cmd -------------------
if (Test-Path $nuSetup) {
    Write-Step 'Adding the Nushell `n` shortcut for PowerShell and cmd'
    try {
        & $nuSetup
    } catch {
        # Convenience step: never let it abort the bootstrap.
        Write-Host "    Nushell shortcut setup failed (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
    }
} else {
    Write-Ok 'setup-nushell.ps1 not found - skipping'
}

# --- 22. Deploy the Starship prompt for PowerShell and cmd --------------------
if (Test-Path $starshipConfig) {
    Write-Step 'Deploying the Starship prompt for PowerShell and cmd'
    try {
        & $starshipConfig
    } catch {
        # Prompt config: never let it abort the bootstrap.
        Write-Host "    Starship setup failed (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
    }
} else {
    Write-Ok 'configure-starship.ps1 not found - skipping'
}

Write-Host ''
Write-Host 'Done. Open a new PowerShell window, then try: z ..' -ForegroundColor Green
Write-Host 'git push will use your gh login (no username prompt).' -ForegroundColor Green
Write-Host 'Commits will be authored as Keios <git@taquangkhoi.com>.' -ForegroundColor Green
Write-Host 'Vicinae starts at login; press Ctrl+Space to open the launcher.' -ForegroundColor Green
Write-Host 'Rio font size / zoom is 16.' -ForegroundColor Green
Write-Host 'Start Zed once to install its extensions (PowerShell, HTML, Dockerfile, Compose, TOML, Nix, SQL).' -ForegroundColor Green
Write-Host 'Komorebi hotkeys are ready (see komorebi/whkdrc).' -ForegroundColor Green
Write-Host 'YASB status bar is configured; fill ~/.config/yasb/.env for weather/wallpapers.' -ForegroundColor Green
Write-Host 'Type `n` in PowerShell or cmd to open Nushell.' -ForegroundColor Green
Write-Host 'Starship is the prompt in new PowerShell and cmd windows.' -ForegroundColor Green
