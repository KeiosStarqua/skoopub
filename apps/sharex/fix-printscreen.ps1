# apps/sharex/fix-printscreen.ps1
# Windows 10/11 reserve the PrtSc key for the Snipping Tool overlay, which
# stops ShareX from owning it. Two more things can break it on a fresh setup:
#   - the first-run welcome screen delays hotkey registration until dismissed;
#   - Explorer caches the Snipping Tool setting until it is restarted.
# This script handles all three, then restarts ShareX so it re-registers.
#
#   powershell -ExecutionPolicy Bypass -File .\apps/sharex/fix-printscreen.ps1
#   powershell -ExecutionPolicy Bypass -File .\apps/sharex/fix-printscreen.ps1 -RestartExplorer
[CmdletBinding()]
param(
    # Only change the setting/config, do not touch a running ShareX.
    [switch]$NoRestart,
    # Restart Explorer so it drops a cached Snipping Tool PrtSc binding.
    [switch]$RestartExplorer
)

$ErrorActionPreference = 'Stop'

# --- 1. Release PrtSc from the Snipping Tool ---------------------------------
$keyPath = 'HKCU:\Control Panel\Keyboard'
$valueName = 'PrintScreenKeyForSnippingEnabled'

$before = '<not set>'
try {
    $before = (Get-ItemProperty -Path $keyPath -Name $valueName -ErrorAction Stop).$valueName
} catch {
    # Value absent: the OS treats it as disabled, but set it explicitly anyway.
}

if (-not (Test-Path $keyPath)) {
    New-Item -Path $keyPath -Force | Out-Null
}
New-ItemProperty -Path $keyPath -Name $valueName -Value 0 -PropertyType DWord -Force | Out-Null
Write-Host "PrintScreenKeyForSnippingEnabled: $before -> 0" -ForegroundColor Green

if ($RestartExplorer) {
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
        Start-Process explorer.exe
    }
    Write-Host 'Explorer restarted (cached PrtSc binding cleared).' -ForegroundColor Green
}

# --- 2. Pre-seed ShareX config so hotkeys register immediately ----------------
$scoopDir = $null
foreach ($candidate in @($env:SCOOP, (Join-Path $env:USERPROFILE 'scoop'), (Join-Path $env:ProgramData 'scoop'))) {
    if ($candidate -and (Test-Path (Join-Path $candidate 'apps\sharex'))) {
        $scoopDir = $candidate
        break
    }
}

if ($scoopDir) {
    $personal = Join-Path $scoopDir 'persist\sharex\ShareX'
    New-Item -ItemType Directory -Force -Path $personal | Out-Null

    $appConfig = Join-Path $personal 'ApplicationConfig.json'
    if (-not (Test-Path $appConfig)) {
        $seed = '{"ShowStartScreen":false,"ShowIconPackPrompt":false,"DisableHotkeys":false,"DisableHotkeysOnFullscreen":false}'
        Set-Content -Path $appConfig -Value $seed -Encoding UTF8
        Write-Host "Seeded $appConfig (welcome screen skipped)." -ForegroundColor Green
    }

    $hotkeys  = Join-Path $personal 'HotkeysConfig.json'
    $template = Join-Path $PSScriptRoot 'hotkeys.template.json'
    if (-not (Test-Path $hotkeys) -and (Test-Path $template)) {
        Copy-Item -LiteralPath $template -Destination $hotkeys
        Write-Host "Seeded $hotkeys (PrtSc -> full screen, Ctrl+PrtSc -> region)." -ForegroundColor Green
    }
} else {
    Write-Host 'Scoop/ShareX directory not found; skipped config seeding.' -ForegroundColor Yellow
}

# --- 3. Restart ShareX so it registers the hotkeys ---------------------------
$sharex = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -in @('ShareX', 'sharex') } | Select-Object -First 1
if ($NoRestart) {
    Write-Host 'Skipped ShareX restart (-NoRestart). Restart it manually if it is running.'
} elseif ($sharex) {
    $exe = $sharex.Path
    $sharex | Stop-Process -Force
    Start-Sleep -Milliseconds 800
    if ($exe -and (Test-Path $exe)) {
        Start-Process -FilePath $exe
        Start-Sleep -Seconds 3
        Write-Host "ShareX restarted: $exe" -ForegroundColor Green
    } else {
        Write-Host 'ShareX was running but its path is unknown; start it manually.' -ForegroundColor Yellow
    }
} else {
    Write-Host 'ShareX is not running; start it and it will register Print Screen.' -ForegroundColor Yellow
}

Write-Host ''
Write-Host 'Test: press PrtSc, then paste into Paint (Ctrl+V) or check the Screenshots folder.'
Write-Host 'If it still fails, try -RestartExplorer, then check for Snipping Tool / OneDrive / Lightshot.'
