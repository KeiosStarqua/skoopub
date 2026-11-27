#Requires -Version 5.1
<#
.SYNOPSIS
    Enable marimo dark mode permanently by setting [display] theme in ~/.marimo.toml.

.DESCRIPTION
    Merges the theme from config.toml into the user's marimo configuration file.
    Existing sections and keys in ~/.marimo.toml are preserved: only the theme
    inside [display] is updated (or added). Re-runs are a no-op when it already
    matches. The theme can be "dark", "light" or "system" (edit config.toml).

.PARAMETER NoBackup
    Overwrite a changed file directly instead of keeping a timestamped .bak.

.EXAMPLE
    .\apps\marimo\configure.ps1
#>
[CmdletBinding()]
param(
    [switch]$NoBackup
)

$ErrorActionPreference = 'Stop'

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message)   { Write-Host "    $Message" -ForegroundColor DarkGray }

function Get-DisplayTheme {
    # Read the desired theme from the repo template (single source of truth).
    param([string[]]$Lines)
    $inDisplay = $false
    foreach ($line in $Lines) {
        if ($line -match '^\s*\[([^\]]+)\]') { $inDisplay = ($Matches[1] -eq 'display'); continue }
        if ($inDisplay -and $line -match '^\s*theme\s*=\s*["'']?([^"''#\s]+)') { return $Matches[1].Trim() }
    }
    return ''
}

function Set-DisplayTheme {
    # Update only [display] theme; leave every other line untouched.
    param([string[]]$Lines, [string]$Value)
    $result = New-Object 'System.Collections.Generic.List[string]'
    $inDisplay = $false
    $hasDisplay = $false
    $done = $false
    foreach ($line in $Lines) {
        if ($line -match '^\s*\[([^\]]+)\]') {
            if ($inDisplay -and -not $done) { $result.Add("theme = `"$Value`""); $done = $true }
            $inDisplay = ($Matches[1] -eq 'display')
            if ($inDisplay) { $hasDisplay = $true }
            $result.Add($line)
            continue
        }
        if ($inDisplay -and -not $done -and $line -match '^\s*theme\s*=') {
            $result.Add("theme = `"$Value`"")
            $done = $true
            continue
        }
        $result.Add($line)
    }
    if ($inDisplay -and -not $done) { $result.Add("theme = `"$Value`"") }
    if (-not $hasDisplay) {
        if ($result.Count -gt 0 -and $result[$result.Count - 1].Trim()) { $result.Add('') }
        $result.Add('[display]')
        $result.Add("theme = `"$Value`"")
    }
    return $result.ToArray()
}

$source = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'config.toml' } else { Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'config.toml' }
$target = Join-Path $env:USERPROFILE '.marimo.toml'

if (-not (Test-Path -LiteralPath $source)) {
    Write-Host "config.toml not found at $source - skipping" -ForegroundColor Yellow
    return
}
$theme = Get-DisplayTheme ([System.IO.File]::ReadAllLines($source))
if (-not $theme) {
    Write-Host "No [display] theme found in $source - skipping" -ForegroundColor Yellow
    return
}

$targetExists = Test-Path -LiteralPath $target
$base = [System.IO.File]::ReadAllLines($(if ($targetExists) { $target } else { $source }))
$desired = @(Set-DisplayTheme -Lines $base -Value $theme)
$before = if ($targetExists) { ($base -join "`n").TrimEnd() } else { '' }
$after = ($desired -join "`n").TrimEnd()

if ($targetExists -and $before -eq $after) {
    Write-Ok "marimo theme already '$theme' in $target"
    return
}

if ($targetExists -and -not $NoBackup) {
    $backup = '{0}.bak.{1}' -f $target, (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-Item -LiteralPath $target -Destination $backup -Force
    Write-Ok "backed up $target -> $backup"
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($target, (($desired -join "`r`n") + "`r`n"), $utf8NoBom)
Write-Step "Setting marimo display theme to '$theme'"
Write-Ok "wrote $target"
