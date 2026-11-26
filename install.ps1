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
      skoopub bookmarks folder (Hacker News, mymind, Scoop, OpenCode), sets ChatGPT as the
      homepage, and disables Firefox's save-password prompt.
    - Runs `scoop import scoop.json` (buckets + apps).
    - Starts Tailscale after the import (Windows service if present, otherwise
      the Scoop `tailscaled` shim); the interactive `tailscale up` login is left to you.
    - Offers a temporary SSH key + Herdr remote setup via setup-herdr-ssh.ps1:
      pick a tailnet machine, generate a throwaway key, authorize it with your
      SSH password, add an SSH alias and register it with Herdr.
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
    - Copies alacritty/alacritty.toml into %APPDATA%\alacritty (old file is backed
      up): JetBrainsMono NF at 12pt for Herdr TUI glyphs and hide-when-typing.
      No mouse bindings are set, so clicks reach Herdr/lazygit mouse capture;
      Shift+click still bypasses a TUI for text selection.
    - Offers to run `gh auth login` (only when needed) and runs `gh auth setup-git`
      so `git push` uses the GitHub CLI token instead of prompting for a username.

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

.EXAMPLE
    irm https://raw.githubusercontent.com/KeiosStarqua/skoopub/main/install.ps1 | iex

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
#>
[CmdletBinding()]
param(
    [string]$RepoRawBase = 'https://raw.githubusercontent.com/KeiosStarqua/skoopub/main',
    [switch]$ForceUniKey,
    [switch]$SkipGhLogin
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message)   { Write-Host "    $Message" -ForegroundColor DarkGray }

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

function Start-TailscaleDaemon {
    # Scoop ships tailscaled but not the Windows service. Prefer the service
    # when the official installer created it; otherwise run the shim directly.
    # Login (`tailscale up`) is interactive, so it is left to the user.
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
        return
    }

    $tailscaled = Get-Command tailscaled -ErrorAction SilentlyContinue
    if (-not $tailscaled) {
        Write-Ok 'tailscaled not on PATH - skipping'
        return
    }
    if (Get-Process -Name 'tailscaled' -ErrorAction SilentlyContinue) {
        Write-Ok 'tailscaled is already running'
        return
    }
    try {
        Start-Process -FilePath $tailscaled.Source -WindowStyle Hidden
        Write-Ok 'launched tailscaled from Scoop (run `tailscale up` to sign in)'
    } catch {
        Write-Host "    Could not launch tailscaled (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
    }
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
        'zed/settings.json', 'zed/keymap.json', 'zed/tasks.json'
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
$zedConfig       = Join-Path $repoRoot 'configure-zed.ps1'
$herdrSsh        = Join-Path $repoRoot 'setup-herdr-ssh.ps1'
Write-Ok "repo root: $repoRoot"

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

# --- 10. Temporary SSH + Herdr remote setup (interactive) -------------------
if (Test-Path $herdrSsh) {
    Write-Step 'Setting up a temporary SSH key for a Herdr remote machine'
    try {
        & $herdrSsh
    } catch {
        Write-Host "    Herdr SSH setup failed (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
    }
} else {
    Write-Ok 'setup-herdr-ssh.ps1 not found - skipping'
}

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

# --- 14. Apply the repo-managed Zed config ----------------------------------
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

Write-Host ''
Write-Host 'Done. Open a new PowerShell window, then try: z ..' -ForegroundColor Green
Write-Host 'git push will use your gh login (no username prompt).' -ForegroundColor Green
Write-Host 'Start Zed once to install its extensions (PowerShell, HTML, Dockerfile, Compose, TOML, Nix, SQL).' -ForegroundColor Green
