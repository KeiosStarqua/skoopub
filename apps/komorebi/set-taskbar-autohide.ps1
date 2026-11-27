# apps/komorebi/set-taskbar-autohide.ps1
# Auto-hide the Windows taskbar so Komorebi-managed windows can use the full
# screen (YASB supplies the visible bar). Idempotent: the registry value is
# only written - and Explorer only restarted - when the state actually changes.
#
#   powershell -ExecutionPolicy Bypass -File .\apps\komorebi\set-taskbar-autohide.ps1
#   powershell -ExecutionPolicy Bypass -File .\apps\komorebi\set-taskbar-autohide.ps1 -Disable
#   powershell -ExecutionPolicy Bypass -File .\apps\komorebi\set-taskbar-autohide.ps1 -NoRestart
[CmdletBinding()]
param(
    # Restore the taskbar to always-on-top instead of auto-hiding it.
    [switch]$Disable,
    # Write the registry value but leave Explorer alone (applies at next sign-in).
    [switch]$NoRestart
)

$ErrorActionPreference = 'Stop'

$taskbarKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StuckRects3'

try {
    $settings = (Get-ItemProperty -Path $taskbarKey -Name Settings -ErrorAction Stop).Settings
} catch {
    Write-Host "Taskbar settings (StuckRects3) not found - skipping: $($_.Exception.Message)" -ForegroundColor Yellow
    return
}

if ($null -eq $settings -or $settings.Count -le 8) {
    Write-Host 'Unexpected StuckRects3 Settings layout - not changing the taskbar.' -ForegroundColor Yellow
    return
}

# StuckRects3\Settings byte 8: 0x02 = always-on-top, 0x03 = auto-hide.
$desired = if ($Disable) { 0x02 } else { 0x03 }
$current = [int]$settings[8]

if ($current -eq $desired) {
    if ($Disable) {
        Write-Host 'Taskbar is already always-on-top; nothing to do.'
    } else {
        Write-Host 'Taskbar is already set to auto-hide; nothing to do.'
    }
    return
}

$settings[8] = [byte]$desired
Set-ItemProperty -Path $taskbarKey -Name Settings -Value $settings -Type Binary

if ($Disable) {
    Write-Host 'Taskbar auto-hide disabled (always-on-top restored).'
} else {
    Write-Host 'Taskbar set to auto-hide.'
}

if ($NoRestart) {
    Write-Host 'Explorer not restarted (-NoRestart); the change applies at next sign-in.' -ForegroundColor DarkGray
    return
}

# Explorer reads this value at startup, so restart it to apply immediately.
Write-Host 'Restarting Explorer to apply the taskbar setting...'
Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
    Start-Process explorer.exe
    Start-Sleep -Seconds 2
}
if (Get-Process -Name explorer -ErrorAction SilentlyContinue) {
    Write-Host 'Explorer restarted; taskbar auto-hide is active.' -ForegroundColor Green
} else {
    Write-Host 'Explorer did not come back - sign out/in to apply the taskbar setting.' -ForegroundColor Yellow
}
