# show-taskbar-clock.ps1
# Make sure Windows always shows the clock on the taskbar. Per-user, no admin.
#
#   powershell -ExecutionPolicy Bypass -File .\show-taskbar-clock.ps1
#   powershell -ExecutionPolicy Bypass -File .\show-taskbar-clock.ps1 -Seconds
[CmdletBinding()]
param(
    # Also show seconds in the taskbar clock.
    [switch]$Seconds,
    # Set the registry values but leave the current Explorer session alone.
    [switch]$NoRestartExplorer
)

$ErrorActionPreference = 'Stop'

$keyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
if (-not (Test-Path $keyPath)) {
    New-Item -Path $keyPath -Force | Out-Null
}

$beforeClock = '<not set>'
try { $beforeClock = (Get-ItemProperty -Path $keyPath -Name ShowClock -ErrorAction Stop).ShowClock } catch {}
New-ItemProperty -Path $keyPath -Name ShowClock -Value 1 -PropertyType DWord -Force | Out-Null
Write-Host "ShowClock: $beforeClock -> 1" -ForegroundColor Green

if ($Seconds) {
    $beforeSeconds = '<not set>'
    try {
        $beforeSeconds = (Get-ItemProperty -Path $keyPath -Name ShowSecondsInSystemClock -ErrorAction Stop).ShowSecondsInSystemClock
    } catch {}
    New-ItemProperty -Path $keyPath -Name ShowSecondsInSystemClock -Value 1 -PropertyType DWord -Force | Out-Null
    Write-Host "ShowSecondsInSystemClock: $beforeSeconds -> 1" -ForegroundColor Green
}

if ($NoRestartExplorer) {
    Write-Host 'Explorer not restarted; sign out/in (or restart explorer) to see the change.'
} else {
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
        Start-Process explorer.exe
    }
    Write-Host 'Explorer restarted; the taskbar clock is now shown.' -ForegroundColor Green
}
