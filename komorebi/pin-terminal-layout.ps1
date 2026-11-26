# pin-terminal-layout.ps1
# Keep the Terminal workspace (Komorebi workspace index 0) arranged with Rio on
# the left and Firefox on the right. Komorebi decides column order from the
# order windows were created, which cannot be expressed in komorebi.json, so
# this watcher checks the live state and reorders the two windows when needed.
#
#   powershell -ExecutionPolicy Bypass -File .\pin-terminal-layout.ps1
#   powershell -ExecutionPolicy Bypass -File .\pin-terminal-layout.ps1 -Once
#   powershell -ExecutionPolicy Bypass -File .\pin-terminal-layout.ps1 -Stop
[CmdletBinding()]
param(
    [int]$IntervalMs = 1000,
    # Fix the order once and exit (useful for testing and for a hotkey).
    [switch]$Once,
    # Stop the background watcher started by configure-komorebi.ps1.
    [switch]$Stop
)

$ErrorActionPreference = 'Stop'

$marker = '*-File*komorebi-pin.ps1*'
$logPath = Join-Path $env:TEMP 'skoop-komorebi-pin.log'

function Write-Log([string]$Message) {
    $line = '{0} {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    try { Add-Content -LiteralPath $logPath -Value $line -ErrorAction Stop } catch { }
}

function Resolve-Komorebic {
    $command = Get-Command komorebic -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    foreach ($root in @($env:SCOOP, (Join-Path $env:USERPROFILE 'scoop'))) {
        if (-not $root) { continue }
        $shim = Join-Path $root 'shims\komorebic.exe'
        if (Test-Path -LiteralPath $shim) { return $shim }
    }
    return $null
}

$komorebic = Resolve-Komorebic
if (-not $komorebic) {
    Write-Log 'komorebic not found - nothing to do'
    return
}

if ($Stop) {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like $marker -and $_.ProcessId -ne $PID } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Write-Log 'watcher stopped'
    return
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class SkoopPinWin {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
}
'@ -ErrorAction SilentlyContinue

function Get-TerminalExes {
    $raw = (& $komorebic state 2>$null | Out-String)
    if (-not $raw) { return @() }
    try { $state = $raw | ConvertFrom-Json } catch { return @() }
    foreach ($monitor in $state.monitors.elements) {
        foreach ($workspace in $monitor.workspaces.elements) {
            if ($workspace.name -ne 'Terminal') { continue }
            $result = @()
            foreach ($container in $workspace.containers.elements) {
                $window = $container.windows.elements | Select-Object -First 1
                if ($window) { $result += $window.exe }
            }
            return $result
        }
    }
    return @()
}

function Set-TerminalOrder {
    $exes = Get-TerminalExes
    $rio = [array]::IndexOf($exes, 'rio.exe')
    $firefox = [array]::IndexOf($exes, 'firefox.exe')
    if ($rio -lt 0 -or $firefox -lt 0 -or $rio -eq 0) { return }

    $foreground = [SkoopPinWin]::GetForegroundWindow()
    try {
        & $komorebic eager-focus rio.exe 2>$null | Out-Null
        for ($i = 0; $i -lt 8; $i++) {
            $exes = Get-TerminalExes
            $rio = [array]::IndexOf($exes, 'rio.exe')
            if ($rio -le 0) { break }
            & $komorebic move left 2>$null | Out-Null
            Start-Sleep -Milliseconds 150
        }
        Write-Log ("reordered Terminal: {0}" -f ((Get-TerminalExes) -join ', '))
    } finally {
        if ($foreground -ne [IntPtr]::Zero) { [void][SkoopPinWin]::SetForegroundWindow($foreground) }
    }
}

if ($Once) {
    Set-TerminalOrder
    return
}

Write-Log "watcher started (pid $PID, interval ${IntervalMs}ms)"
while ($true) {
    try { Set-TerminalOrder } catch { Write-Log ("error: {0}" -f $_.Exception.Message) }
    Start-Sleep -Milliseconds $IntervalMs
}
