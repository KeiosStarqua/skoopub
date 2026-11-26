#Requires -Version 5.1
<#
.SYNOPSIS
    Set Vicinae's global toggle shortcut to Ctrl+Space via a config import.

.DESCRIPTION
    Vicinae merges imported config files before the user's settings.json, and
    the GUI never rewrites imported files. This script copies the repo-managed
    `vicinae/keybinds.json` into Vicinae's config directory and makes sure
    settings.json imports it. Existing settings are preserved; the global
    toggle becomes `control+space`.

    Restart the running Vicinae server (or sign out/in) for a new global
    shortcut to be registered. The bootstraps call this right after enabling
    Vicinae autostart, so a fresh sign-in picks it up.

.PARAMETER ConfigDir
    Vicinae config directory (default: %LOCALAPPDATA%\vicinae\config).

.PARAMETER SourceDir
    Directory holding keybinds.json (default: vicinae\ next to this script).

.PARAMETER NoBackup
    Do not create a timestamped .bak copy of settings.json before editing it.

.PARAMETER Restart
    Stop and relaunch the Vicinae server so the new shortcut takes effect now.

.EXAMPLE
    .\apps/vicinae/configure.ps1

.EXAMPLE
    .\apps/vicinae/configure.ps1 -Restart
#>
[CmdletBinding()]
param(
    [string]$ConfigDir = (Join-Path $env:LOCALAPPDATA 'vicinae\config'),
    [string]$SourceDir = '',
    [switch]$NoBackup,
    [switch]$Restart
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is not populated during parameter binding in PowerShell 5.1.
if (-not $SourceDir) { $SourceDir = $PSScriptRoot }

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message)   { Write-Host "    $Message" -ForegroundColor DarkGray }
function Write-Warn([string]$Message) { Write-Host "    $Message" -ForegroundColor Yellow }

$importFile = './keybinds.json'
$settings   = Join-Path $ConfigDir 'settings.json'
$keybinds   = Join-Path $SourceDir 'keybinds.json'

if (-not (Test-Path -LiteralPath $keybinds)) {
    throw "keybinds.json not found at $keybinds"
}
New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null

# --- 1. Install the repo-managed import --------------------------------------
$dest = Join-Path $ConfigDir 'keybinds.json'
$sourceText = (Get-Content -Raw -LiteralPath $keybinds).Trim()
$existingText = if (Test-Path -LiteralPath $dest) { (Get-Content -Raw -LiteralPath $dest).Trim() } else { '' }
if ($existingText -eq $sourceText) {
    Write-Ok "$dest already up to date"
} else {
    Copy-Item -LiteralPath $keybinds -Destination $dest -Force
    Write-Ok "copied keybinds.json -> $dest (Ctrl+Space toggles the launcher)"
}

# --- 2. Make sure settings.json imports it -----------------------------------
if (-not (Test-Path -LiteralPath $settings)) {
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($settings, "{`r`n   `"`$schema`": `"https://vicinae.com/schemas/config.json`",`r`n   `"imports`": [`"$importFile`"]`r`n}`r`n", $utf8)
    Write-Ok "created $settings with the keybinds import"
} else {
    $raw = Get-Content -Raw -LiteralPath $settings
    $changed = $false

    $match = [regex]::Match($raw, '"imports"\s*:\s*\[(?<items>[^\]]*)\]')
    if ($match.Success) {
        if ($match.Groups['items'].Value -match '(?i)keybinds\.json') {
            Write-Ok 'settings.json already imports keybinds.json'
        } else {
            $items = $match.Groups['items'].Value.Trim()
            $nl = [Environment]::NewLine
            $replacement = if ($items) {
                '"imports": [' + $items.TrimEnd() + ',' + $nl + '    "' + $importFile + '"' + $nl + ']'
            } else {
                '"imports": ["' + $importFile + '"]'
            }
            $raw = $raw.Remove($match.Index, $match.Length).Insert($match.Index, $replacement)
            $changed = $true
        }
    } else {
        # No imports yet: add one just inside the root object.
        $open = $raw.IndexOf('{')
        if ($open -lt 0) { throw "Could not find the root object in $settings" }
        $insert = "`r`n   `"imports`": [`"$importFile`"],"
        $raw = $raw.Insert($open + 1, $insert)
        $changed = $true
    }

    if ($changed) {
        if (-not $NoBackup) {
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            Copy-Item -LiteralPath $settings -Destination "$settings.bak.$stamp" -Force
            Write-Ok "backed up settings.json -> settings.json.bak.$stamp"
        }
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($settings, $raw, $utf8)
        Write-Ok "added the keybinds import to $settings"
    }
}

# --- 3. Optionally restart the server so the shortcut registers --------------
if ($Restart) {
    $running = Get-Process -Name 'vicinae-server' -ErrorAction SilentlyContinue
    if ($running) {
        Write-Step 'Restarting the Vicinae server'
        $running | Stop-Process -Force
        Start-Sleep -Seconds 2
    }
    $roots = @($env:SCOOP, (Join-Path $env:USERPROFILE 'scoop'), (Join-Path $env:ProgramData 'scoop'))
    $server = $roots | Where-Object { $_ } | ForEach-Object {
        Join-Path $_ 'apps\vicinae\current\bin\vicinae-server.exe'
    } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($server) {
        foreach ($name in @('HERDR_ENV', 'HERDR_PANE_ID', 'HERDR_TAB_ID', 'HERDR_WORKSPACE_ID', 'HERDR_SOCKET_PATH', 'HERDR_BIN_PATH')) {
            Remove-Item "Env:$name" -ErrorAction SilentlyContinue
        }
        Start-Process -FilePath $server -WindowStyle Hidden
        Start-Sleep -Seconds 2
        Write-Ok 'Vicinae server restarted'
    } else {
        Write-Warn 'vicinae-server.exe not found; restart it yourself to apply the shortcut'
    }
} else {
    Write-Ok 'Restart Vicinae (or sign out/in) to register Ctrl+Space; use -Restart to do it now'
}

Write-Host ''
Write-Host 'Vicinae global shortcut: Ctrl+Space' -ForegroundColor Green
