<#
.SYNOPSIS
    Register a per-user scheduled task that runs the Firefox/Vicinae/Atuin/Pear Desktop backup and local sign-in cleanup on shutdown/logoff.

.DESCRIPTION
    Triggers on Windows event 1074 (shutdown initiated) in the System log and, when
    available, 4647 (logoff) in the Security log. The action runs
    core/shutdown-cleanup-guard.ps1, which skips the work when a full cleanup
    already finished within -MaxAgeMinutes; otherwise it runs
    core/cleanup-before-shutdown.ps1 with -User. Nothing is changed until the
    remote backup verifies.

    Registration is per-user and non-elevated. Use -Remove to unregister.

.PARAMETER User
    SSH user on acer-ubuntu. Defaults to $env:SKOOP_BACKUP_USER.

.PARAMETER TaskName
    Scheduled task name (default 'SkoopCleanupOnShutdown').

.PARAMETER ScriptPath
    Guard script to run (defaults to shutdown-cleanup-guard.ps1 next to this file).

.PARAMETER MaxAgeMinutes
    Skip cleanup when the last successful run is younger than this (default 10).

.PARAMETER Force
    Always run cleanup, ignoring the last-success timestamp.

.PARAMETER Remove
    Unregister the task instead of creating it.

.EXAMPLE
    .\core\install-shutdown-hook.ps1 -User keios

.EXAMPLE
    .\core\install-shutdown-hook.ps1 -Remove
#>
[CmdletBinding()]
param(
    [string] $User = "$env:SKOOP_BACKUP_USER",
    [string] $TaskName = 'SkoopCleanupOnShutdown',
    [string] $ScriptPath,
    [int] $MaxAgeMinutes = 10,
    [switch] $Force,
    [switch] $Remove
)

$ErrorActionPreference = 'Stop'

if (-not $ScriptPath) { $ScriptPath = Join-Path $PSScriptRoot 'shutdown-cleanup-guard.ps1' }

if ($Remove) {
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Removed scheduled task: $TaskName"
    } else {
        Write-Host "Scheduled task not found: $TaskName"
    }
    return
}

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    throw "Cleanup script not found: $ScriptPath"
}
if (-not $User -or -not $User.Trim()) {
    throw 'SSH user is required. Pass -User <name> or set $env:SKOOP_BACKUP_USER.'
}
$User = $User.Trim()

function New-EventTrigger {
    param([string] $LogName, [string] $EventId)

    $class = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace 'Root/Microsoft/Windows/TaskScheduler'
    $trigger = New-CimInstance -CimClass $class -ClientOnly
    $trigger.Enabled = $true
    $trigger.Subscription = '<QueryList><Query Id="0" Path="' + $LogName + '"><Select Path="' + $LogName + '">*[System[EventID=' + $EventId + ']]</Select></Query></QueryList>'
    return $trigger
}

$triggers = @(
    (New-EventTrigger -LogName 'System' -EventId '1074')
)
try {
    $triggers += (New-EventTrigger -LogName 'Security' -EventId '4647')
} catch {
    Write-Host "    Security-log trigger skipped: $($_.Exception.Message)" -ForegroundColor Yellow
}

$powershell = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
if (-not $powershell) { $powershell = (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') }
$arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $ScriptPath + '" -User "' + $User + '" -MaxAgeMinutes ' + $MaxAgeMinutes
if ($Force) { $arguments += ' -Force' }
$action = New-ScheduledTaskAction -Execute $powershell -Argument $arguments

$account = $env:USERDOMAIN + '\' + $env:USERNAME
$principal = New-ScheduledTaskPrincipal -UserId $account -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers `
    -Principal $principal -Settings $settings -Force | Out-Null

Write-Host "Registered '$TaskName': runs shutdown-cleanup-guard.ps1 -User $User on shutdown/logoff (skip when last cleanup < $MaxAgeMinutes min old)." -ForegroundColor Green
Write-Host 'Note: a shutdown can terminate the task before a slow upload finishes; the script deletes auth only after the backup verifies.' -ForegroundColor Yellow
