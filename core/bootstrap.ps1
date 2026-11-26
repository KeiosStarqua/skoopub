# bootstrap.ps1 - restore this Scoop + shell setup on a Windows machine.
# Usage:  powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1
# Use -ForceUniKey to replace an already installed UniKey with the Scoop build.
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
[CmdletBinding()]
param(
    [switch]$ForceUniKey,
    [switch]$SkipGhLogin
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot

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

# 2. Hook the repo-managed profile into $PROFILE before anything can fail.
Install-ProfileHook

# 3. Clear the Task Manager policy.
Enable-TaskManager

# 4. Install Firefox, then WezTerm, then Herdr.
$extrasBucket = scoop bucket list 2>$null | Select-String -Pattern '^\s*extras\b' -Quiet
if (-not $extrasBucket) { scoop bucket add extras }
$firefoxInstalled = scoop list 2>$null | Select-String -Pattern '^\s*firefox\b' -Quiet
if (-not $firefoxInstalled) { scoop install extras/firefox } else { Write-Host 'Firefox already installed.' }
Install-FirefoxPolicies (Join-Path $repo 'apps\firefox\policies.template.json')
Set-FirefoxDefaultBrowser
$weztermInstalled = scoop list 2>$null | Select-String -Pattern '^\s*wezterm\b' -Quiet
if (-not $weztermInstalled) { scoop install wezterm } else { Write-Host 'WezTerm already installed.' }
foreach ($app in @('herdr', 'herdr-core')) {
    $installed = scoop list 2>$null | Select-String -Pattern ("^\s*" + [regex]::Escape($app) + '\b') -Quiet
    if (-not $installed) { scoop install $app } else { Write-Host "$app already installed." }
}

# 5. Restore buckets + apps declared in scoop.json.
$manifest = Join-Path $repo 'manifests\scoop.json'
if (-not $ForceUniKey -and (Test-UniKeyInstalled)) {
    Write-Host 'UniKey already installed - keeping the existing copy (-ForceUniKey overrides).'
    $json = Get-Content -Raw $manifest | ConvertFrom-Json
    $json.apps = @($json.apps | Where-Object { $_.Name -ne 'unikey' })
    $manifest = Join-Path $env:TEMP 'skoop-scoop-no-unikey.json'
    $json | ConvertTo-Json -Depth 10 | Set-Content -Path $manifest -Encoding UTF8
}
scoop import $manifest

# 6. Start Tailscale (daemon/service only; login stays manual), then tag this
#    device in the tailnet (idempotent and non-fatal when not signed in).
Start-TailscaleDaemon
$tailscaleConfig = Join-Path $repo 'apps\tailscale\configure.ps1'
if (Test-Path $tailscaleConfig) {
    try { & $tailscaleConfig }
    catch { Write-Host "Tailnet tagging failed (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow }
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

# 9. Let ShareX own PrtSc: Windows otherwise hands the key to the Snipping Tool.
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

# 13. Apply the repo-managed Rio config (font size / zoom 16).
$rioConfig = Join-Path $repo 'apps\rio\configure.ps1'
if (Test-Path $rioConfig) {
    try { & $rioConfig }
    catch { Write-Host "Rio config failed (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow }
}

# 14. Auto-start Vicinae (Startup shortcut + start the server now).
$vicinae = Join-Path $repo 'apps\vicinae\enable-autostart.ps1'
if (Test-Path $vicinae) {
    try { & $vicinae }
    catch { Write-Host "Vicinae autostart setup failed (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow }
}

# 15. Set the Vicinae global shortcut to Ctrl+Space (config import).
$vicinaeConfig = Join-Path $repo 'apps\vicinae\configure.ps1'
if (Test-Path $vicinaeConfig) {
    try { & $vicinaeConfig }
    catch { Write-Host "Vicinae shortcut setup failed (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow }
}

# 16. Deploy ~/.config/whkdrc and start/reload Komorebi's hotkey daemon.
$komorebiConfig = Join-Path $repo 'apps\komorebi\configure.ps1'
if (Test-Path $komorebiConfig) {
    try { & $komorebiConfig }
    catch { Write-Host "Komorebi hotkey setup failed (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow }
}

# 17. Deploy the repo-managed YASB status bar config and start YASB.
$yasbConfig = Join-Path $repo 'apps\yasb\configure.ps1'
if (Test-Path $yasbConfig) {
    try { & $yasbConfig }
    catch { Write-Host "YASB config failed (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow }
}

# 18. Add the `n` Nushell shortcut for PowerShell (profile.ps1) and cmd (AutoRun).
$nuSetup = Join-Path $repo 'apps\nushell\setup.ps1'
if (Test-Path $nuSetup) {
    try { & $nuSetup }
    catch { Write-Host "Nushell shortcut setup failed (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow }
}

# 19. Deploy the Starship prompt (config for PowerShell, Clink loader for cmd).
$starshipConfig = Join-Path $repo 'apps\starship\configure.ps1'
if (Test-Path $starshipConfig) {
    try { & $starshipConfig }
    catch { Write-Host "Starship setup failed (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow }
}

Write-Host "Done. Open a new PowerShell window, then try: z .." -ForegroundColor Green
Write-Host "git push will use your gh login (no username prompt)." -ForegroundColor Green
Write-Host "Commits will be authored as Keios <git@taquangkhoi.com>." -ForegroundColor Green
Write-Host "Vicinae starts at login; press Ctrl+Space to open the launcher." -ForegroundColor Green
Write-Host "Rio font size / zoom is 16." -ForegroundColor Green
Write-Host "Komorebi hotkeys are ready (see komorebi\whkdrc)." -ForegroundColor Green
Write-Host "YASB status bar is configured; fill ~\.config\yasb\.env for weather/wallpapers." -ForegroundColor Green
Write-Host "Type 'n' in PowerShell or cmd to open Nushell." -ForegroundColor Green
Write-Host "Starship is the prompt in new PowerShell and cmd windows." -ForegroundColor Green
Write-Host "Start Zed once to install its extensions (PowerShell, HTML, Dockerfile, Compose, TOML, Nix, SQL)." -ForegroundColor Green
