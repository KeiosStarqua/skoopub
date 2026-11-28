#Requires -Version 5.1
<#
.SYNOPSIS
    Notification-area icon for the skoop backup and cleanup scripts.

.DESCRIPTION
    Starts at login from a Startup shortcut created by configure.ps1. The
    right-click menu runs the same work as `skoop-cleanup`, without needing a
    terminal:

      - Backup now (keep sign-ins)  -> cleanup-before-shutdown.ps1 -BackupOnly
      - Backup + sign out           -> the full cleanup (asks for confirmation)
      - Exit                        -> closes the icon until the next login

    Each command opens its own PowerShell window, so progress is visible and an
    uncached SSH user is still prompted for. One tray runs per session; a second
    launch (login plus an installer re-run) exits immediately.

.EXAMPLE
    .\apps\tray\tray.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# One icon per session: the Startup shortcut and a manual run must not stack.
$mutex = New-Object System.Threading.Mutex($false, 'Local\skoop-tray')
$ownsMutex = $false
try {
    $ownsMutex = $mutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    # -Remove force-stopped the previous tray; no live icon is left.
    $ownsMutex = $true
}
if (-not $ownsMutex) { return }

function Get-CleanupScript {
    # Same roots as skoop-cleanup in shell/profile.ps1, so a deleted checkout
    # still works when the installer fetched its files to %LOCALAPPDATA%.
    foreach ($root in @(
            (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
            (Join-Path $env:LOCALAPPDATA 'skoop'),
            (Join-Path $env:USERPROFILE 'repos\skoopub')
        )) {
        $candidate = Join-Path $root 'core\cleanup-before-shutdown.ps1'
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

function Get-BackupUser {
    if ($env:SKOOP_BACKUP_USER) { return $env:SKOOP_BACKUP_USER }
    $file = Join-Path $env:LOCALAPPDATA 'skoop\backup-user'
    if (Test-Path -LiteralPath $file) { return (Get-Content -Raw -LiteralPath $file).Trim() }
    return $null
}

function Start-SkoopScript {
    param([string] $Script, [string[]] $Arguments = @())

    $exe = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
    if (-not $exe) { $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    $argList = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$Script`"") + $Arguments
    Start-Process -FilePath $exe -ArgumentList ($argList -join ' ')
}

$script:Cleanup = Get-CleanupScript
$script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
$script:NotifyIcon.Icon = [System.Drawing.SystemIcons]::Shield
$script:NotifyIcon.Text = 'skoop backup and cleanup'

$menu = New-Object System.Windows.Forms.ContextMenuStrip

$backupItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Backup now (keep sign-ins)'
$backupItem.add_Click({
        if (-not $script:Cleanup) { return }
        $cleanupArgs = @('-BackupOnly')
        $user = Get-BackupUser
        if ($user) { $cleanupArgs += @('-User', "`"$user`"") }
        Start-SkoopScript -Script $script:Cleanup -Arguments $cleanupArgs
    })

$cleanItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Backup + sign out'
$cleanItem.add_Click({
        if (-not $script:Cleanup) { return }
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "Upload the backup to acer-ubuntu, then sign out of GitHub, Tailscale, Firefox, Pear Desktop and OpenCode on this PC?`n`nNothing is removed until the backup is verified.",
            'skoop cleanup', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { return }
        $cleanupArgs = @()
        $user = Get-BackupUser
        if ($user) { $cleanupArgs += @('-User', "`"$user`"") }
        Start-SkoopScript -Script $script:Cleanup -Arguments $cleanupArgs
    })

$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Exit'
$exitItem.add_Click({
        $script:NotifyIcon.Visible = $false
        [System.Windows.Forms.Application]::Exit()
    })

if (-not $script:Cleanup) {
    $menu.Items.Add((New-Object System.Windows.Forms.ToolStripMenuItem 'cleanup-before-shutdown.ps1 not found')) | Out-Null
    $menu.Items[0].Enabled = $false
}
[void]$menu.Items.Add($backupItem)
[void]$menu.Items.Add($cleanItem)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$menu.Items.Add($exitItem)

$script:NotifyIcon.ContextMenuStrip = $menu
$script:NotifyIcon.Visible = $true

try {
    [System.Windows.Forms.Application]::Run()
} finally {
    $script:NotifyIcon.Visible = $false
    $script:NotifyIcon.Dispose()
    $mutex.Dispose()
}
