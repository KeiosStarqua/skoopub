#Requires -Version 5.1
<#
.SYNOPSIS
    Install UniKey and apply a no-GUI Vietnamese typing setup: Unicode + VNI.

.DESCRIPTION
    UniKey 4.6 RC2 (the Scoop build from the zeldrisho bucket) keeps its settings
    in HKCU\SOFTWARE\PkLong\UniKey -- not HKCU\Software\UniKey, which older
    builds used. The values below were verified against the upstream engine
    enums: CodeTable=0 is Unicode, InputMethod=1 is VNI (0 is Telex),
    Vietnamese=1 turns Vietnamese typing on and ShowDlg=0 suppresses the
    startup dialog. AutoUpdate=0 leaves version control to Scoop.

    The script is idempotent: it stops a running UniKey (so the process cannot
    overwrite the registry on exit), imports apps/unikey/unikey.reg as a
    machine-independent baseline, enforces the requested options, adds a
    per-user Startup shortcut and starts UniKey in the current session. If an
    existing (e.g. preinstalled on a public PC) UniKey is found, it is reused
    instead of installing a second copy; -Force installs the Scoop build anyway.

    -Export writes a sanitized .reg snapshot of the current settings (no
    absolute paths) to %LOCALAPPDATA%\skoop\unikey\backups by default.
    -Restore imports a .reg file (the repo baseline or the newest backup) and
    still enforces Unicode / Vietnamese / the requested input method.

.PARAMETER InputMethod
    VNI (default) or Telex.

.PARAMETER Force
    Install the Scoop build even when another UniKey is already installed.

.PARAMETER NoAutostart
    Do not create/update the per-user Startup shortcut.

.PARAMETER RemoveAutostart
    Delete the Startup shortcut and exit. Does not stop a running UniKey.

.PARAMETER NoLaunch
    Apply the configuration but do not start UniKey in this session.

.PARAMETER Export
    Back up the current registry settings to a sanitized .reg file and exit.

.PARAMETER Restore
    Import a .reg file instead of the repo baseline (see -Path).

.PARAMETER Path
    Target .reg file for -Export, or source .reg file for -Restore.

.EXAMPLE
    .\apps\unikey\configure.ps1

.EXAMPLE
    .\apps\unikey\configure.ps1 -InputMethod Telex -NoLaunch

.EXAMPLE
    .\apps\unikey\configure.ps1 -Export

.EXAMPLE
    .\apps\unikey\configure.ps1 -Restore -Path .\unikey-backup.reg
#>
[CmdletBinding()]
param(
    [ValidateSet('VNI', 'Telex')][string]$InputMethod = 'VNI',
    [switch]$Force,
    [switch]$NoAutostart,
    [switch]$RemoveAutostart,
    [switch]$NoLaunch,
    [switch]$Export,
    [switch]$Restore,
    [string]$Path
)

$ErrorActionPreference = 'Stop'

$regPath     = 'HKCU:\SOFTWARE\PkLong\UniKey'
$legacyPath  = 'HKCU:\SOFTWARE\UniKey'
$regFile     = Join-Path $PSScriptRoot 'unikey.reg'
$backupRoot  = Join-Path $env:LOCALAPPDATA 'skoop\unikey\backups'
$startupDir  = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
$linkPath    = Join-Path $startupDir 'UniKey.lnk'

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message)   { Write-Host "    $Message" -ForegroundColor DarkGray }

function Get-UniKeyExe {
    # Prefer the running process, then Scoop's stable `current` folder / shim,
    # then PATH, uninstall metadata and the usual install locations.
    $candidates = @()

    $running = Get-Process -Name 'UniKeyNT', 'UniKey' -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty Path
    if ($running) { $candidates += $running }

    foreach ($root in @($env:SCOOP, (Join-Path $env:USERPROFILE 'scoop'), (Join-Path $env:ProgramData 'scoop'))) {
        if (-not $root) { continue }
        $candidates += (Join-Path $root 'apps\unikey\current\UniKeyNT.exe')
        $candidates += (Join-Path $root 'shims\UniKey.exe')
    }

    $found = Get-Command -Name 'UniKeyNT.exe', 'UniKey.exe' -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandType -ne 'Alias' }
    if ($found) { $candidates += @($found | ForEach-Object { $_.Source }) }

    $uninstallKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($key in $uninstallKeys) {
        $items = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match 'UniKey' }
        foreach ($item in $items) {
            if ($item.InstallLocation) { $candidates += (Join-Path $item.InstallLocation 'UniKeyNT.exe') }
            if ($item.DisplayIcon) {
                $icon = ($item.DisplayIcon -split ',')[0].Trim('"')
                if ($icon -match '\.exe$') { $candidates += $icon }
            }
        }
    }

    foreach ($base in @(${env:ProgramFiles}, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
        if ($base) { $candidates += (Join-Path $base 'UniKey\UniKeyNT.exe') }
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    return $null
}

function Stop-UniKey {
    $processes = Get-Process -Name 'UniKeyNT', 'UniKey' -ErrorAction SilentlyContinue
    if ($processes) {
        $processes | Stop-Process -Force -ErrorAction SilentlyContinue
        # UniKey writes its settings on exit; give it time to finish before we
        # import the baseline, otherwise the old values are written back.
        Start-Sleep -Milliseconds 800
    }
}

function Install-UniKeyFromScoop {
    $scoop = Get-Command -Name scoop -ErrorAction SilentlyContinue | Select-Object -First 1
    $source = if ($scoop) { $scoop.Source } else { $null }
    if (-not $source) {
        foreach ($candidate in @(
            (Join-Path $env:USERPROFILE 'scoop\shims\scoop.cmd'),
            (Join-Path $env:ProgramData 'scoop\shims\scoop.cmd')
        )) {
            if (Test-Path -LiteralPath $candidate) { $source = $candidate; break }
        }
    }
    if (-not $source) { throw 'Scoop was not found; install Scoop before running this script.' }

    Write-Step 'Installing UniKey with Scoop (zeldrisho bucket)'
    & $source install unikey
    if ($LASTEXITCODE -ne 0) { throw "scoop install unikey failed (exit $LASTEXITCODE)" }
}

function Import-UniKeyReg {
    param([string]$File)
    if (-not (Test-Path -LiteralPath $File)) { throw "UniKey .reg file not found: $File" }
    & reg import $File
    if ($LASTEXITCODE -ne 0) { throw "reg import failed for $File (exit $LASTEXITCODE)" }
    Write-Ok "imported $File"
}

function Export-UniKeyReg {
    param([string]$File)
    if (-not (Test-Path -LiteralPath $regPath)) { throw "No UniKey settings found at $regPath" }

    # Only DWORD settings are exported. REG_SZ values such as MacroPath are
    # machine-specific and would point at another PC's Scoop directory.
    $properties = Get-ItemProperty -LiteralPath $regPath
    $lines = @('Windows Registry Editor Version 5.00', '', '[HKEY_CURRENT_USER\SOFTWARE\PkLong\UniKey]')
    foreach ($name in $properties.PSObject.Properties.Name) {
        if ($name -like 'PS*' -or $name -eq 'MacroPath') { continue }
        $value = $properties.$name
        if ($value -is [int] -or $value -is [long]) {
            $lines += ('"{0}"=dword:{1:X8}' -f $name, $value)
        }
    }

    New-Item -ItemType Directory -Force -Path (Split-Path $File -Parent) | Out-Null
    [System.IO.File]::WriteAllText($File, ($lines -join "`r`n") + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "UniKey settings exported to $File" -ForegroundColor Green
}

function Set-UniKeySettings {
    param([int]$Method)

    $desired = @{
        'ShowDlg'    = 0
        'Vietnamese' = 1
        'CodeTable'  = 0
        'InputMethod' = $Method
        'AutoUpdate' = 0
    }

    # 4.6 RC2 uses PkLong\UniKey. Mirror into the older path only when a legacy
    # UniKey already created it, so we never invent an unused registry key.
    $paths = @($regPath)
    if (Test-Path -LiteralPath $legacyPath) { $paths += $legacyPath }

    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }
        foreach ($name in $desired.Keys) {
            New-ItemProperty -LiteralPath $path -Name $name -PropertyType DWord `
                -Value $desired[$name] -Force | Out-Null
        }
        $macroPath = (Get-ItemProperty -LiteralPath $path -Name 'MacroPath' -ErrorAction SilentlyContinue).MacroPath
        if ($macroPath -and -not (Test-Path -LiteralPath $macroPath)) {
            Remove-ItemProperty -LiteralPath $path -Name 'MacroPath' -ErrorAction SilentlyContinue
            Write-Ok "removed stale MacroPath ($macroPath)"
        }
    }
}

function Enable-UniKeyAutostart {
    param([string]$Exe)
    New-Item -ItemType Directory -Force -Path $startupDir | Out-Null
    $shell = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $shell.CreateShortcut($linkPath)
        try {
            $target = if (Test-Path -LiteralPath $linkPath) { $shortcut.TargetPath } else { '' }
            if ([string]::Equals($target, $Exe, [StringComparison]::OrdinalIgnoreCase)) {
                Write-Ok "already enabled: $linkPath"
            } else {
                $shortcut.TargetPath       = $Exe
                $shortcut.Arguments        = ''
                $shortcut.WorkingDirectory = Split-Path $Exe -Parent
                $shortcut.WindowStyle      = 7   # minimized: UniKey is a tray app
                $shortcut.Description      = 'Start UniKey (Vietnamese IME) at login'
                $shortcut.Save()
                Write-Ok "created $linkPath -> $Exe"
            }
        } finally {
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut)
        }
    } finally {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
}

if ($RemoveAutostart) {
    if (Test-Path -LiteralPath $linkPath) {
        Remove-Item -LiteralPath $linkPath -Force
        Write-Ok "removed $linkPath (UniKey will not start at login)"
    } else {
        Write-Ok 'no UniKey Startup shortcut to remove'
    }
    return
}

if ($Export) {
    $destination = if ($Path) { $Path } else {
        Join-Path $backupRoot ('unikey-{0}.reg' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    }
    Export-UniKeyReg -File $destination
    return
}

$method = if ($InputMethod -eq 'VNI') { 1 } else { 0 }

$exe = Get-UniKeyExe
if ($Force -or -not $exe) {
    Install-UniKeyFromScoop
    $exe = Get-UniKeyExe
}
if (-not $exe) {
    throw 'UniKey was not found after installation. Check `scoop list unikey` and your PATH.'
}
Write-Ok "UniKey: $exe"

Stop-UniKey

if ($Restore) {
    $source = if ($Path) { $Path } elseif (Test-Path -LiteralPath $regFile) { $regFile } else {
        Get-ChildItem -LiteralPath $backupRoot -Filter 'unikey-*.reg' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $source) { throw 'No .reg file to restore. Pass -Path or run -Export first.' }
    Import-UniKeyReg -File $source
} elseif (Test-Path -LiteralPath $regFile) {
    Import-UniKeyReg -File $regFile
} else {
    Write-Ok 'apps/unikey/unikey.reg not found - applying settings directly'
}

Set-UniKeySettings -Method $method

if (-not $NoAutostart) { Enable-UniKeyAutostart -Exe $exe }

if ($NoLaunch) {
    Write-Ok 'skipped starting UniKey in this session (-NoLaunch)'
} elseif (Get-Process -Name 'UniKeyNT', 'UniKey' -ErrorAction SilentlyContinue) {
    Write-Ok 'UniKey is already running'
} else {
    Write-Step 'Starting UniKey'
    Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe -Parent)
    Start-Sleep -Milliseconds 800
    if (Get-Process -Name 'UniKeyNT', 'UniKey' -ErrorAction SilentlyContinue) {
        Write-Ok 'UniKey started'
    } else {
        Write-Host '    UniKey did not stay running; start it from the Start Menu to check for an error.' -ForegroundColor Yellow
    }
}

Write-Host ''
Write-Host ('UniKey ready: Unicode, {0}, Vietnamese typing on, no startup dialog, starts at login.' -f $InputMethod) -ForegroundColor Green
Write-Host 'Backup with .\apps\unikey\configure.ps1 -Export; restore with -Restore [-Path <file>].' -ForegroundColor Green
