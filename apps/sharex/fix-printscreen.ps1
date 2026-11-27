# apps/sharex/fix-printscreen.ps1
# Windows 10/11 reserve the PrtSc key for the Snipping Tool overlay, which
# stops ShareX from owning it. Two more things can break it on a fresh setup:
#   - the first-run welcome screen delays hotkey registration until dismissed;
#   - Explorer caches the Snipping Tool setting until it is restarted.
# This script handles all three, then restarts ShareX so it re-registers.
# It checks current state first and is a no-op when everything is already set:
# re-running an applied fix never rewrites the registry or restarts ShareX.
#
#   powershell -ExecutionPolicy Bypass -File .\apps\sharex\fix-printscreen.ps1
#   powershell -ExecutionPolicy Bypass -File .\apps\sharex\fix-printscreen.ps1 -Force
#   powershell -ExecutionPolicy Bypass -File .\apps\sharex\fix-printscreen.ps1 -RestartExplorer
[CmdletBinding()]
param(
    # Only change the setting/config, do not touch a running ShareX.
    [switch]$NoRestart,
    # Restart Explorer so it drops a cached Snipping Tool PrtSc binding.
    [switch]$RestartExplorer,
    # Re-apply the registry value and restart ShareX even when already configured.
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# --- 0. Check first: touch only state that is actually missing ----------------
$keyPath = 'HKCU:\Control Panel\Keyboard'
$valueName = 'PrintScreenKeyForSnippingEnabled'

$before = '<not set>'
$valueKind = $null
try {
    $key = Get-Item -LiteralPath $keyPath -ErrorAction Stop
    $before = $key.GetValue($valueName, '<not set>')
    $valueKind = $key.GetValueKind($valueName)
} catch {
    # Key or value absent (or not a DWORD): it needs to be written.
}
$registryOk = ($valueKind -eq [Microsoft.Win32.RegistryValueKind]::DWord) -and ($before -eq 0)

$scoopDir = $null
foreach ($candidate in @($env:SCOOP, (Join-Path $env:USERPROFILE 'scoop'), (Join-Path $env:ProgramData 'scoop'))) {
    if ($candidate -and (Test-Path (Join-Path $candidate 'apps\sharex'))) {
        $scoopDir = $candidate
        break
    }
}

$personal = $null
$appConfig = $null
$hotkeys = $null
$template = Join-Path $PSScriptRoot 'hotkeys.template.json'
$needsAppConfig = $false
$needsHotkeys = $false
if ($scoopDir) {
    $personal = Join-Path $scoopDir 'persist\sharex\ShareX'
    $appConfig = Join-Path $personal 'ApplicationConfig.json'
    $hotkeys = Join-Path $personal 'HotkeysConfig.json'
    $needsAppConfig = -not (Test-Path -LiteralPath $appConfig)
    $needsHotkeys = (-not (Test-Path -LiteralPath $hotkeys)) -and (Test-Path -LiteralPath $template)
}

$sharex = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -in @('ShareX', 'sharex') } | Select-Object -First 1)

if (-not $Force -and -not $RestartExplorer -and $registryOk -and
    -not $needsAppConfig -and -not $needsHotkeys) {
    Write-Host 'ShareX PrtSc fix already applied - no changes needed.' -ForegroundColor DarkGray
    if ($sharex.Count -eq 0) {
        Write-Host 'ShareX is not running; start it and it will register Print Screen.' -ForegroundColor Yellow
    }
    return
}

# --- 1. Release PrtSc from the Snipping Tool ---------------------------------
if ($registryOk -and -not $Force) {
    Write-Host 'PrintScreenKeyForSnippingEnabled already 0 (no registry change).' -ForegroundColor DarkGray
} else {
    if (-not (Test-Path $keyPath)) {
        New-Item -Path $keyPath -Force | Out-Null
    }
    New-ItemProperty -Path $keyPath -Name $valueName -Value 0 -PropertyType DWord -Force | Out-Null
    Write-Host "PrintScreenKeyForSnippingEnabled: $before -> 0" -ForegroundColor Green
}

if ($RestartExplorer) {
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
        Start-Process explorer.exe
    }
    Write-Host 'Explorer restarted (cached PrtSc binding cleared).' -ForegroundColor Green
}

# --- 2. Pre-seed ShareX config so hotkeys register immediately ----------------
if ($scoopDir) {
    New-Item -ItemType Directory -Force -Path $personal | Out-Null

    if ($needsAppConfig) {
        $seed = '{"ShowStartScreen":false,"ShowIconPackPrompt":false,"DisableHotkeys":false,"DisableHotkeysOnFullscreen":false}'
        Set-Content -Path $appConfig -Value $seed -Encoding UTF8
        Write-Host "Seeded $appConfig (welcome screen skipped)." -ForegroundColor Green
    } else {
        Write-Host 'ShareX ApplicationConfig.json already present (left untouched).' -ForegroundColor DarkGray
    }

    if ($needsHotkeys) {
        Copy-Item -LiteralPath $template -Destination $hotkeys
        Write-Host "Seeded $hotkeys (PrtSc -> full screen, Ctrl+PrtSc -> region)." -ForegroundColor Green
    } elseif (Test-Path -LiteralPath $template) {
        Write-Host 'ShareX HotkeysConfig.json already present (left untouched).' -ForegroundColor DarkGray
    }
} else {
    Write-Host 'Scoop/ShareX directory not found; skipped config seeding.' -ForegroundColor Yellow
}

# --- 3. Restart ShareX so it registers the hotkeys ---------------------------
if ($NoRestart) {
    Write-Host 'Skipped ShareX restart (-NoRestart). Restart it manually if it is running.'
} elseif ($sharex.Count -gt 0) {
    $exe = $sharex[0].Path
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
