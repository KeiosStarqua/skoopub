#Requires -Version 5.1
<#
.SYNOPSIS
    Install the skoop backup/cleanup tray icon and start it at login.

.DESCRIPTION
    Creates a per-user Startup shortcut that runs apps/tray/tray.ps1 with
    powershell.exe (hidden window) and starts it in the current session unless
    -NoLaunch is given. Right-clicking the icon runs a backup or the backup +
    sign-out cleanup without opening a terminal. Re-running repairs an outdated
    shortcut.

.PARAMETER NoLaunch
    Only write the Startup shortcut; do not start the icon in this session.

.PARAMETER Remove
    Remove the Startup shortcut and stop a running tray.

.EXAMPLE
    .\apps\tray\configure.ps1

.EXAMPLE
    .\apps\tray\configure.ps1 -Remove
#>
[CmdletBinding()]
param(
    [switch] $NoLaunch,
    [switch] $Remove
)

$ErrorActionPreference = 'Stop'

function Write-Step([string] $Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok([string] $Message) { Write-Host "    $Message" -ForegroundColor DarkGray }

$trayScript = Join-Path $PSScriptRoot 'tray.ps1'
if (-not (Test-Path -LiteralPath $trayScript)) {
    throw "apps/tray/tray.ps1 not found at $trayScript"
}

$startupDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
$linkPath = Join-Path $startupDir 'Skoop Tray.lnk'
$exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $trayScript

function Get-TrayProcess {
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like "*$trayScript*" }
}

if ($Remove) {
    foreach ($process in @(Get-TrayProcess)) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $linkPath) {
        Remove-Item -LiteralPath $linkPath -Force
        Write-Ok "removed $linkPath (the tray will not start at login)"
    } else {
        Write-Ok 'no Skoop Tray Startup shortcut to remove'
    }
    return
}

New-Item -ItemType Directory -Force -Path $startupDir | Out-Null
$shell = New-Object -ComObject WScript.Shell
try {
    $shortcut = $shell.CreateShortcut($linkPath)
    try {
        if ([string]::Equals($shortcut.TargetPath, $exe, [StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals($shortcut.Arguments, $arguments, [StringComparison]::OrdinalIgnoreCase)) {
            Write-Ok "already enabled: $linkPath"
        } else {
            $shortcut.TargetPath = $exe
            $shortcut.Arguments = $arguments
            $shortcut.WorkingDirectory = $PSScriptRoot
            $shortcut.WindowStyle = 7   # minimized: the tray has no window
            $shortcut.Description = 'skoop backup and cleanup tray icon'
            $shortcut.Save()
            Write-Ok "created $linkPath"
        }
    } finally {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut)
    }
} finally {
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
}

if ($NoLaunch) {
    Write-Ok 'skipped launching (right-click the icon after the next login)'
    return
}

if (Get-TrayProcess) {
    Write-Ok 'Skoop tray is already running'
    return
}

Write-Step 'Starting the skoop backup and cleanup tray icon'
Start-Process -FilePath $exe -ArgumentList $arguments -WindowStyle Hidden
Start-Sleep -Seconds 2
if (Get-TrayProcess) {
    Write-Ok 'tray started - right-click the shield icon for backup and cleanup'
} else {
    Write-Host '    Tray did not stay running; run .\apps\tray\tray.ps1 to see the error.' -ForegroundColor Yellow
}

Write-Host ''
Write-Host 'Skoop tray will start at login; its menu backs up or cleans up without a terminal.' -ForegroundColor Green
