# configure-komorebi.ps1
# Deploy the repo-managed whkdrc and komorebi.json to ~/.config, then start
# (or reconfigure) Komorebi and start/reload whkd so hotkeys are active.
#
#   powershell -ExecutionPolicy Bypass -File .\configure-komorebi.ps1
#   powershell -ExecutionPolicy Bypass -File .\configure-komorebi.ps1 -Restart
#   powershell -ExecutionPolicy Bypass -File .\configure-komorebi.ps1 -NoStart
[CmdletBinding()]
param(
    # Resolved in the body: $PSScriptRoot is empty during param binding in PS 5.1.
    [string]$SourceDir = '',
    [string]$ConfigDir = '',
    # Overwrite changed files directly instead of keeping a timestamped .bak.
    [switch]$NoBackup,
    # Deploy files only; do not start or restart komorebi/whkd.
    [switch]$NoStart,
    # Restart whkd and reapply the Komorebi config even when files did not change.
    [switch]$Restart,
    # Do not deploy/start the watcher that keeps Rio left and Firefox right.
    [switch]$NoPin,
    # Restart the background pin watcher.
    [switch]$RestartPin
)

$ErrorActionPreference = 'Stop'

if (-not $SourceDir) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    if (-not $scriptDir) { $scriptDir = $PSScriptRoot }
    $SourceDir = Join-Path $scriptDir 'komorebi'
}

if (-not $ConfigDir) {
    if ($env:USERPROFILE) { $ConfigDir = Join-Path $env:USERPROFILE '.config' }
    else { $ConfigDir = Join-Path $env:APPDATA 'Komorebi' }
}

New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null

function Read-Normalized {
    param([string]$Path)
    return ((Get-Content -Raw -LiteralPath $Path) -replace "`r`n", "`n").TrimEnd()
}

function Deploy-File {
    param([string]$Source, [string]$Destination)
    if (-not (Test-Path -LiteralPath $Source)) {
        Write-Host "$(Split-Path -Leaf $Source) not found at $Source - skipping" -ForegroundColor Yellow
        return $false
    }
    $changed = $true
    if (Test-Path -LiteralPath $Destination) {
        $changed = (Read-Normalized $Destination) -ne (Read-Normalized $Source)
        if (-not $changed) {
            Write-Host "$(Split-Path -Leaf $Destination) already up to date: $Destination"
        } else {
            if (-not $NoBackup) {
                $backup = '{0}.bak.{1}' -f $Destination, (Get-Date -Format 'yyyyMMdd-HHmmss')
                Copy-Item -LiteralPath $Destination -Destination $backup -Force
                Write-Host "Backed up $Destination -> $backup"
            }
        }
    } else {
        Write-Host "Installing $Destination (first run)"
    }
    if ($changed) {
        Copy-Item -LiteralPath $Source -Destination $Destination -Force
    }
    return $changed
}

$hotkeysChanged = Deploy-File (Join-Path $SourceDir 'whkdrc') (Join-Path $ConfigDir 'whkdrc')
$komorebiConfig = Join-Path $ConfigDir 'komorebi.json'
$configChanged = Deploy-File (Join-Path $SourceDir 'komorebi.json') $komorebiConfig
$pinScript = Join-Path $ConfigDir 'komorebi-pin.ps1'
$pinChanged = $false
if (-not $NoPin) {
    $pinChanged = Deploy-File (Join-Path $SourceDir 'pin-terminal-layout.ps1') $pinScript
}

function Resolve-Tool {
    param([string]$Name)
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    foreach ($root in @($env:SCOOP, (Join-Path $env:USERPROFILE 'scoop'))) {
        if (-not $root) { continue }
        $shim = Join-Path $root "shims\$Name.exe"
        if (Test-Path -LiteralPath $shim) { return $shim }
    }
    return $null
}

function Get-PinWatcherProcesses {
    return @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*-File*komorebi-pin.ps1*' -and $_.CommandLine -notlike '*-Command*' })
}

function Start-PinWatcher {
    param([switch]$Force)
    if (-not (Test-Path -LiteralPath $pinScript)) { return }
    # Wrap in @(): a single CIM instance has no .Count in PowerShell 5.1.
    $existing = @(Get-PinWatcherProcesses)
    if ($existing.Count -gt 0) {
        if (-not $Force) {
            Write-Host 'Terminal layout watcher is already running.'
        } else {
            $existing | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
            Start-Sleep -Milliseconds 400
        }
    }
    if ($Force -or $existing.Count -eq 0) {
        $powershellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path -LiteralPath $powershellExe)) { $powershellExe = 'powershell.exe' }
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $pinScript
        Start-Process -FilePath $powershellExe -ArgumentList $arguments -WindowStyle Hidden
        Write-Host 'Started Terminal layout watcher (Rio left, Firefox right).'
    }

    $startup = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
    New-Item -ItemType Directory -Force -Path $startup | Out-Null
    $shortcut = Join-Path $startup 'Skoop Komorebi Pin.lnk'
    try {
        $shell = New-Object -ComObject WScript.Shell
        $link = $shell.CreateShortcut($shortcut)
        $link.TargetPath = $powershellExe
        $link.Arguments = $arguments
        $link.WorkingDirectory = Split-Path -Parent $pinScript
        $link.WindowStyle = 7
        $link.Description = 'Keep Rio on the left and Firefox on the right in Komorebi Terminal'
        $link.Save()
    } catch {
        Write-Host "    Pin watcher autostart shortcut failed (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

if ($NoStart) {
    Write-Host 'Skipping process start/reload (-NoStart).' -ForegroundColor DarkGray
    return
}

$komorebic = Resolve-Tool 'komorebic'
$whkd = Resolve-Tool 'whkd'

if (-not (Get-Process -Name komorebi -ErrorAction SilentlyContinue)) {
    if ($komorebic) {
        $startArgs = @('start')
        if (Test-Path -LiteralPath $komorebiConfig) { $startArgs += @('-c', $komorebiConfig) }
        Write-Host 'Starting Komorebi...'
        & $komorebic @startArgs 2>&1 | ForEach-Object { Write-Host "    $_" }
    } else {
        Write-Host 'komorebic not found; cannot start Komorebi.' -ForegroundColor Yellow
    }
} elseif ($komorebic -and (Test-Path -LiteralPath $komorebiConfig)) {
    # Reapply on every run: the config may differ from a session started before
    # this repo managed it. It is safe/idempotent and keeps padding consistent.
    Write-Host 'Applying Komorebi config (padding, layout, workspace rules)...'
    & $komorebic replace-configuration $komorebiConfig 2>&1 | ForEach-Object { Write-Host "    $_" }
}

$whkdRunning = [bool](Get-Process -Name whkd -ErrorAction SilentlyContinue)
if ($whkdRunning -and ($hotkeysChanged -or $Restart)) {
    Write-Host 'Restarting whkd to load the new hotkeys...'
    Stop-Process -Name whkd -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    $whkdRunning = $false
}

if (-not $whkdRunning -and $whkd) {
    Write-Host 'Starting whkd...'
    Start-Process -FilePath $whkd -WindowStyle Hidden
    Start-Sleep -Seconds 1
}

if (-not (Get-Process -Name whkd -ErrorAction SilentlyContinue)) {
    Write-Host 'whkd did not stay running - check ~/.config/whkdrc for syntax errors.' -ForegroundColor Yellow
} else {
    Write-Host "Komorebi hotkeys are active (whkdrc: $(Join-Path $ConfigDir 'whkdrc'))." -ForegroundColor Green
}

if (-not $NoPin) {
    Start-PinWatcher -Force:($RestartPin -or $pinChanged)
}
