# apps/zed/configure.ps1
# Copy the repo-managed Zed config into the current user's Zed config folder.
# Settings/keymap/tasks/themes/snippets live in %APPDATA%\Zed; extensions are
# installed by Zed itself into %LOCALAPPDATA%\Zed on the next start.
#
#   powershell -ExecutionPolicy Bypass -File .\apps\zed\configure.ps1
#   powershell -ExecutionPolicy Bypass -File .\apps\zed\configure.ps1 -NoBackup
[CmdletBinding()]
param(
    # Resolved in the body: $PSScriptRoot is empty during param binding in PS 5.1.
    [string]$SourceDir = '',
    [string]$ConfigDir = '',
    # Overwrite changed files directly instead of keeping a timestamped .bak.
    [switch]$NoBackup
)

$ErrorActionPreference = 'Stop'

if (-not $SourceDir) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    if (-not $scriptDir) { $scriptDir = $PSScriptRoot }
    $SourceDir = $scriptDir
}

if (-not $ConfigDir) {
    if ($env:APPDATA) { $ConfigDir = Join-Path $env:APPDATA 'Zed' }
    else { $ConfigDir = Join-Path $env:USERPROFILE 'AppData\Roaming\Zed' }
}

if (-not (Test-Path -LiteralPath $SourceDir)) {
    Write-Host "Zed config source not found: $SourceDir" -ForegroundColor Yellow
    return
}

function Copy-ZedFile {
    param([string]$Source, [string]$Destination)

    $normalize = {
        param([string]$Text)
        return ($Text -replace "`r`n", "`n").TrimEnd()
    }

    if (Test-Path -LiteralPath $Destination) {
        $existing = & $normalize (Get-Content -Raw -LiteralPath $Destination)
        $desired  = & $normalize (Get-Content -Raw -LiteralPath $Source)
        if ($existing -eq $desired) { return }

        if (-not $NoBackup) {
            $backup = '{0}.bak.{1}' -f $Destination, (Get-Date -Format 'yyyyMMdd-HHmmss')
            Copy-Item -LiteralPath $Destination -Destination $backup -Force
            Write-Host "Backed up $Destination -> $backup"
        }
    }

    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    Write-Host "Installed $Destination"
}

New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null

foreach ($file in Get-ChildItem -LiteralPath $SourceDir -File -Filter '*.json') {
    Copy-ZedFile -Source $file.FullName -Destination (Join-Path $ConfigDir $file.Name)
}

# themes/ and snippets/ may be empty in the repo; make sure they exist for Zed.
foreach ($dir in @('themes', 'snippets')) {
    $targetDir = Join-Path $ConfigDir $dir
    New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
    $sourceSubDir = Join-Path $SourceDir $dir
    if (Test-Path -LiteralPath $sourceSubDir) {
        foreach ($file in Get-ChildItem -LiteralPath $sourceSubDir -File -Filter '*.json') {
            Copy-ZedFile -Source $file.FullName -Destination (Join-Path $targetDir $file.Name)
        }
    }
}

Write-Host "Zed config applied to $ConfigDir" -ForegroundColor Green
if (Get-Process -Name zed -ErrorAction SilentlyContinue) {
    Write-Host 'Zed is running - restart it to load the new settings and extensions.' -ForegroundColor Yellow
} else {
    Write-Host 'Declared extensions (PowerShell, HTML, Dockerfile, Compose, TOML, Nix, SQL) install on Zed''s first start.' -ForegroundColor DarkGray
}
