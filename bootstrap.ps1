# bootstrap.ps1 - restore this Scoop + shell setup on a Windows machine.
# Usage:  powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1
# Use -ForceUniKey to replace an already installed UniKey with the Scoop build.
[CmdletBinding()]
param(
    [switch]$ForceUniKey
)

$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot

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
        Write-Host 'firefox-policies.template.json not found - skipping extension policy.'
        return
    }

    $distDir = Join-Path $firefoxDir 'distribution'
    New-Item -ItemType Directory -Force -Path $distDir | Out-Null
    Copy-Item -LiteralPath $Template -Destination (Join-Path $distDir 'policies.json') -Force
    Write-Host 'Bitwarden policy installed (restart Firefox to apply it).'
    if (Get-Process -Name firefox -ErrorAction SilentlyContinue) {
        Write-Host 'Firefox is running - close and reopen it to load the policy.'
    }
}

function Install-ProfileHook {
    # Wire the repo-managed profile into $PROFILE early so zoxide/atuin are
    # configured even if a later (optional) step fails.
    $loader = Join-Path $repo 'profile.ps1'
    $hook = "# Load the repo-managed shell config. Edit that file, not this one.`n. `"$loader`""

    New-Item -ItemType Directory -Force -Path (Split-Path $PROFILE) | Out-Null
    $lines = if (Test-Path $PROFILE) { @(Get-Content -Path $PROFILE) } else { @() }
    $stale   = 'skoop[\\/]profile\.ps1|\$skoopProfile|^# Load the repo-managed shell config|' + [regex]::Escape($loader)
    $body    = (($lines | Where-Object { $_ -notmatch $stale }) -join "`r`n").TrimEnd()
    $desired = if ($body) { "$body`r`n$hook" } else { $hook }

    $existing = if (Test-Path $PROFILE) { Get-Content -Raw -Path $PROFILE } else { '' }
    if ($existing.TrimEnd() -ne $desired) {
        Set-Content -Path $PROFILE -Value $desired -Encoding UTF8
        Write-Host "Wired profile.ps1 into $PROFILE"
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
Install-FirefoxPolicies (Join-Path $repo 'firefox-policies.template.json')
Set-FirefoxDefaultBrowser
$weztermInstalled = scoop list 2>$null | Select-String -Pattern '^\s*wezterm\b' -Quiet
if (-not $weztermInstalled) { scoop install wezterm } else { Write-Host 'WezTerm already installed.' }
foreach ($app in @('herdr', 'herdr-core')) {
    $installed = scoop list 2>$null | Select-String -Pattern ("^\s*" + [regex]::Escape($app) + '\b') -Quiet
    if (-not $installed) { scoop install $app } else { Write-Host "$app already installed." }
}

# 5. Restore buckets + apps declared in scoop.json.
$manifest = Join-Path $repo 'scoop.json'
if (-not $ForceUniKey -and (Test-UniKeyInstalled)) {
    Write-Host 'UniKey already installed - keeping the existing copy (-ForceUniKey overrides).'
    $json = Get-Content -Raw $manifest | ConvertFrom-Json
    $json.apps = @($json.apps | Where-Object { $_.Name -ne 'unikey' })
    $manifest = Join-Path $env:TEMP 'skoop-scoop-no-unikey.json'
    $json | ConvertTo-Json -Depth 10 | Set-Content -Path $manifest -Encoding UTF8
}
scoop import $manifest

# 6. Default the Rust toolchain to GNU when none is configured yet.
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

# 7. Let ShareX own PrtSc: Windows otherwise hands the key to the Snipping Tool.
$sharexFix = Join-Path $repo 'fix-sharex-printscreen.ps1'
if (Test-Path $sharexFix) {
    try { & $sharexFix }
    catch {
        # Cosmetic fix: never let it abort the bootstrap (z/atuin are already wired).
        Write-Host "ShareX fix failed (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

Write-Host "Done. Open a new PowerShell window, then try: z .." -ForegroundColor Green
