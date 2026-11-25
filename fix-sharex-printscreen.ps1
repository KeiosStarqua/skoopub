# fix-sharex-printscreen.ps1
# Windows 10/11 reserve the PrtSc key for the Snipping Tool overlay
# ("Use the Print screen key to open screen snipping"). While that is on,
# ShareX cannot register its own Print Screen hotkey.
#
# This flips the setting off (per-user, no admin required) and restarts
# ShareX so it grabs the key again. Run it with:
#   powershell -ExecutionPolicy Bypass -File .\fix-sharex-printscreen.ps1
[CmdletBinding()]
param(
    # Only change the setting, do not touch a running ShareX.
    [switch]$NoRestart
)

$ErrorActionPreference = 'Stop'

$keyPath = 'HKCU:\Control Panel\Keyboard'
$valueName = 'PrintScreenKeyForSnippingEnabled'

$before = '<not set>'
try {
    $current = Get-ItemProperty -Path $keyPath -Name $valueName -ErrorAction Stop
    $before = $current.$valueName
} catch {
    # Value absent: the OS treats it as disabled, but set it explicitly anyway.
}

if (-not (Test-Path $keyPath)) {
    New-Item -Path $keyPath -Force | Out-Null
}
New-ItemProperty -Path $keyPath -Name $valueName -Value 0 -PropertyType DWord -Force | Out-Null

Write-Host "PrintScreenKeyForSnippingEnabled: $before -> 0" -ForegroundColor Green

# ShareX only picks the key up when it (re)registers its hotkeys at startup.
$sharex = Get-Process -Name ShareX -ErrorAction SilentlyContinue | Select-Object -First 1
if ($NoRestart) {
    Write-Host "Skipped ShareX restart (-NoRestart). Restart it manually if it is running."
} elseif ($sharex) {
    $exe = $sharex.Path
    $sharex | Stop-Process -Force
    Start-Sleep -Milliseconds 800
    if ($exe -and (Test-Path $exe)) {
        Start-Process -FilePath $exe
        Write-Host "ShareX restarted: $exe" -ForegroundColor Green
    } else {
        Write-Host "ShareX was running but its path is unknown; start it manually." -ForegroundColor Yellow
    }
} else {
    Write-Host "ShareX is not running; start it and it will register Print Screen." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Next: in ShareX -> Hotkey settings, bind 'Screen capture' to PrintScreen."
Write-Host "If the key still does nothing, check for another app holding PrtSc (Snipping Tool, OneDrive, Lightshot)."
