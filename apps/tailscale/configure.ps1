#Requires -Version 5.1
<#
.SYNOPSIS
    Advertise a tailnet ACL tag on this device (default: tag:public-client).

.DESCRIPTION
    Idempotent and non-fatal. Resolves tailscale.exe from PATH, Program Files
    or Scoop, skips when Tailscale is not connected, and only runs
    `tailscale up --advertise-tags=...` when the tag is not already advertised.
    It never reauthenticates an unconnected node: sign in from the tray icon or
    with `tailscale up` first. Native stderr is merged through cmd.exe because
    Windows PowerShell 5.1 turns it into a terminating NativeCommandError.

.PARAMETER Tag
    ACL tag to advertise. The `tag:` prefix is added when omitted.

.PARAMETER SkipTag
    Leave this device's advertised tags untouched.

.EXAMPLE
    .\apps\tailscale\configure.ps1

.EXAMPLE
    .\apps\tailscale\configure.ps1 -Tag tag:public-client
#>
[CmdletBinding()]
param(
    [string]$Tag = 'tag:public-client',
    [switch]$SkipTag
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message)   { Write-Host "    $Message" -ForegroundColor DarkGray }
function Write-Warn([string]$Message) { Write-Host "    $Message" -ForegroundColor Yellow }

function Resolve-TailscaleCli {
    $found = Get-Command tailscale -ErrorAction SilentlyContinue
    if ($found) { return $found.Source }
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Tailscale\tailscale.exe'),
        (Join-Path $env:USERPROFILE 'scoop\shims\tailscale.exe')
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) { return $candidate }
    }
    return $null
}

if ($SkipTag) { Write-Ok 'Tailnet tagging skipped (-SkipTag).'; return }
if ($Tag -notlike 'tag:*') { $Tag = "tag:$Tag" }

$cli = Resolve-TailscaleCli
if (-not $cli) { Write-Warn 'tailscale.exe not found - skipping tailnet tagging.'; return }

Write-Step "Tagging this device with $Tag in the tailnet"
$raw = (& cmd /c "`"$cli`" status --json 2>&1" | Out-String)
$status = try { $raw | ConvertFrom-Json -ErrorAction Stop } catch { $null }
if (-not $status -or $status.BackendState -ne 'Running' -or -not $status.Self.Online) {
    Write-Warn 'Tailscale is not connected - sign in from the tray icon or run `tailscale up`, then re-run.'
    return
}

$prefsRaw = (& cmd /c "`"$cli`" debug prefs 2>&1" | Out-String)
$prefs = try { $prefsRaw | ConvertFrom-Json -ErrorAction Stop } catch { $null }
$advertised = if ($prefs) { @($prefs.AdvertiseTags) } else { @() }
if ($advertised -contains $Tag) {
    Write-Ok "$Tag is already advertised on this device"
    return
}

$out = (& cmd /c "`"$cli`" up --advertise-tags=$Tag 2>&1" | Out-String)
if ($LASTEXITCODE -ne 0) {
    Write-Warn "Could not advertise $Tag (non-fatal, exit $LASTEXITCODE): $(($out -split "`r?`n" | Select-Object -First 2) -join ' ')"
    Write-Warn 'Check that your tailnet ACL lists you as a tag owner for this tag.'
    return
}
Write-Ok "advertised $Tag on this device"
