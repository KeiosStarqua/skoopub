# show-taskbar-clock.ps1
# Make sure Windows always shows the clock on the taskbar. Per-user, no admin.
# Sets ShowClock / ShowSecondsInSystemClock to 1 and removes the HideClock policy override.
#
#   powershell -ExecutionPolicy Bypass -File .\show-taskbar-clock.ps1
[CmdletBinding()]
param(
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

$beforeSeconds = '<not set>'
try {
    $beforeSeconds = (Get-ItemProperty -Path $keyPath -Name ShowSecondsInSystemClock -ErrorAction Stop).ShowSecondsInSystemClock
} catch {}
New-ItemProperty -Path $keyPath -Name ShowSecondsInSystemClock -Value 1 -PropertyType DWord -Force | Out-Null
Write-Host "ShowSecondsInSystemClock: $beforeSeconds -> 1" -ForegroundColor Green

# Remove HideClock instead of setting 0 — a present DWORD can still lock the Settings toggle / tray clock.
$policyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'
if (Test-Path $policyPath) {
    $hadHide = $false
    try {
        $null = Get-ItemProperty -Path $policyPath -Name HideClock -ErrorAction Stop
        $hadHide = $true
    } catch {}
    if ($hadHide) {
        Remove-ItemProperty -Path $policyPath -Name HideClock -Force
        Write-Host 'HideClock (policy): removed' -ForegroundColor Green
    } else {
        Write-Host 'HideClock (policy): not present' -ForegroundColor Green
    }
    $remaining = (Get-Item -Path $policyPath).Property | Where-Object { $_ -notmatch '^PS' }
    if (-not $remaining) {
        Remove-Item -Path $policyPath -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-Host 'HideClock (policy): not present' -ForegroundColor Green
}

if ($NoRestartExplorer) {
    Write-Host 'Explorer not restarted; sign out/in (or restart explorer) to see the change.'
} else {
    foreach ($proc in @('ShellExperienceHost', 'StartMenuExperienceHost')) {
        Get-Process -Name $proc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
        Start-Process explorer.exe
    }
    Start-Sleep -Seconds 1
    Write-Host 'Explorer restarted; the taskbar clock should be visible now.' -ForegroundColor Green
    Write-Host 'If it is still missing, sign out and back in once (policy keys are cached at logon).' -ForegroundColor Yellow
}