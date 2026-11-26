<#
.SYNOPSIS
    Run the Firefox backup/auth cleanup on shutdown only when the last one is old.

.DESCRIPTION
    Used as the scheduled-task action for SkoopCleanupOnShutdown. If a successful
    cleanup finished within -MaxAgeMinutes (default 10), it does nothing, so a
    recent manual cleanup is not repeated during shutdown. Otherwise it runs
    core/cleanup-before-shutdown.ps1. Every decision is appended to
    %LOCALAPPDATA%\skoop\backup\shutdown-guard.log for debugging.

.PARAMETER User
    SSH user forwarded to the cleanup script. Defaults to $env:SKOOP_BACKUP_USER.

.PARAMETER MaxAgeMinutes
    Skip cleanup when the last successful one is younger than this (default 10).

.PARAMETER Force
    Ignore the timestamp and always run cleanup.

.PARAMETER CleanupPath
    Cleanup script (defaults to cleanup-before-shutdown.ps1 next to this file).

.EXAMPLE
    .\core\shutdown-cleanup-guard.ps1 -User keios
#>
[CmdletBinding()]
param(
    [string] $User = "$env:SKOOP_BACKUP_USER",
    [int] $MaxAgeMinutes = 10,
    [switch] $Force,
    [string] $CleanupPath
)

$ErrorActionPreference = 'Stop'

if (-not $CleanupPath) { $CleanupPath = Join-Path $PSScriptRoot 'cleanup-before-shutdown.ps1' }
$logDir = Join-Path $env:LOCALAPPDATA 'skoop\backup'
$markerPath = Join-Path $logDir 'last-cleanup.json'
$guardLog = Join-Path $logDir 'shutdown-guard.log'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

function Write-GuardLog {
    param([string] $Message)
    $line = '[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] ' + $Message
    Add-Content -LiteralPath $guardLog -Value $line -Encoding UTF8
    Write-Host $line
}

Write-GuardLog ("shutdown guard triggered; maxAge=" + $MaxAgeMinutes + "min, force=" + $Force)

if (-not $Force -and (Test-Path -LiteralPath $markerPath)) {
    try {
        $last = Get-Content -Raw -LiteralPath $markerPath | ConvertFrom-Json
        $when = [DateTime]::Parse($last.timestamp)
        $age = (Get-Date) - $when
        $lastBackups = if ($last.backups) { @($last.backups) -join '; ' } elseif ($last.backup) { $last.backup } else { '(unknown)' }
        if ($age.TotalMinutes -ge 0 -and $age.TotalMinutes -lt $MaxAgeMinutes) {
            Write-GuardLog ("skip cleanup: last success " + ('{0:N1}' -f $age.TotalMinutes) + ' min ago (' + $lastBackups + ')')
            return
        }
        Write-GuardLog ("last success is " + ('{0:N1}' -f $age.TotalMinutes) + " min old; running cleanup")
    } catch {
        Write-GuardLog ("could not read last-cleanup stamp (" + $_.Exception.Message + "); running cleanup")
    }
} elseif ($Force) {
    Write-GuardLog 'force requested; running cleanup'
} else {
    Write-GuardLog 'no last-cleanup stamp; running cleanup'
}

if (-not (Test-Path -LiteralPath $CleanupPath)) {
    throw "Cleanup script not found: $CleanupPath"
}
$argsList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $CleanupPath)
if ($User) { $argsList += @('-User', $User) }

$powershell = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
if (-not $powershell) { $powershell = (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') }
& $powershell @argsList 2>&1 | ForEach-Object { Write-GuardLog ("cleanup: " + $_.ToString()) }
Write-GuardLog ("cleanup finished with exit code " + $LASTEXITCODE)
