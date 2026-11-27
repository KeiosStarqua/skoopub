# apps/yasb/setup-wallpapers.ps1
# One-time, idempotent setup for the YASB wallpapers widget: shallow-clone the
# community aesthetic-wallpapers collection and point YASB_WALLPAPER_DIR at its
# images folder in ~/.config/yasb/.env. Failures are non-fatal (offline installs
# still work; the widget simply has no gallery until a later run).
#
#   powershell -ExecutionPolicy Bypass -File .\apps\yasb\setup-wallpapers.ps1
#   powershell -ExecutionPolicy Bypass -File .\apps\yasb\setup-wallpapers.ps1 -Update
#   powershell -ExecutionPolicy Bypass -File .\apps\yasb\setup-wallpapers.ps1 -NoClone
[CmdletBinding()]
param(
    # Upstream ignores the utm_source tracking parameter; keep the bare URL here.
    [string]$RepoUrl = 'https://github.com/D3Ext/aesthetic-wallpapers',
    [string]$TargetDir = '',
    [string]$EnvFile = '',
    # Pull the latest wallpapers when the clone already exists.
    [switch]$Update,
    # Only (re)point YASB at an already-present folder; do not clone.
    [switch]$NoClone,
    # Clone/pull only; leave ~/.config/yasb/.env untouched.
    [switch]$NoEnv
)

$ErrorActionPreference = 'Stop'

if (-not $TargetDir) {
    $base = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $env:USERPROFILE 'AppData\Local' }
    $TargetDir = Join-Path (Join-Path $base 'skoop\wallpapers') 'aesthetic-wallpapers'
}
if (-not $EnvFile) {
    if ($env:USERPROFILE) { $EnvFile = Join-Path $env:USERPROFILE '.config\yasb\.env' }
    else { $EnvFile = Join-Path $env:APPDATA 'yasb\.env' }
}

$imagesDir = Join-Path $TargetDir 'images'
$gitDir = Join-Path $TargetDir '.git'

function Invoke-Git {
    param([string[]]$Arguments)
    $command = Get-Command git -ErrorAction SilentlyContinue
    if (-not $command) {
        Write-Host '    git not found on PATH - skipping wallpaper clone.' -ForegroundColor Yellow
        return $false
    }
    # git writes progress to stderr; PS 5.1 + Stop would turn each line into a
    # terminating NativeCommandError, so mute the preference around the call.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $command.Source @Arguments 2>&1 | Out-String
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    if ($code -ne 0) {
        Write-Host ("    git {0} failed (exit {1}): {2}" -f ($Arguments -join ' '), $code, $output.Trim()) -ForegroundColor Yellow
        return $false
    }
    return $true
}

if (-not $NoClone) {
    if (Test-Path -LiteralPath $gitDir) {
        if ($Update) {
            Write-Host 'Updating aesthetic-wallpapers (shallow clone already present)...'
            [void](Invoke-Git -Arguments @('-C', $TargetDir, 'pull', '--ff-only'))
        } else {
            Write-Host "aesthetic-wallpapers already cloned: $TargetDir"
        }
    } elseif (Test-Path -LiteralPath $TargetDir) {
        Write-Host "Wallpaper target exists but is not a git clone - leaving it alone: $TargetDir" -ForegroundColor Yellow
    } else {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $TargetDir) | Out-Null
        Write-Host "Cloning aesthetic-wallpapers (shallow, ~645 MB) to $TargetDir ..."
        if (-not (Invoke-Git -Arguments @('clone', '--depth', '1', $RepoUrl, $TargetDir))) {
            Write-Host '    Wallpaper clone failed (non-fatal); YASB_WALLPAPER_DIR unchanged.' -ForegroundColor Yellow
        }
    }
}

$images = @()
if (Test-Path -LiteralPath $imagesDir) {
    $images = @(Get-ChildItem -LiteralPath $imagesDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -match '^\.(jpg|jpeg|png|webp|bmp|gif)$' })
}

if (-not $NoEnv) {
    if (-not (Test-Path -LiteralPath $EnvFile)) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $EnvFile) | Out-Null
        $example = Join-Path $PSScriptRoot '.env.example'
        if (Test-Path -LiteralPath $example) { Copy-Item -LiteralPath $example -Destination $EnvFile }
        else { New-Item -ItemType File -Path $EnvFile | Out-Null }
    }
    if ($images.Count -gt 0) {
        # Forward slashes avoid quoting/escaping problems in YASB's .env loader.
        $value = ($imagesDir -replace '\\', '/')
        $text = [System.IO.File]::ReadAllText($EnvFile)
        $lines = @($text -split "`r?`n")
        $found = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*YASB_WALLPAPER_DIR\s*=') {
                $lines[$i] = "YASB_WALLPAPER_DIR=$value"
                $found = $true
            }
        }
        while ($lines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($lines[$lines.Count - 1])) {
            $lines = $lines[0..($lines.Count - 2)]
        }
        if (-not $found) { $lines += "YASB_WALLPAPER_DIR=$value" }
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($EnvFile, ((@($lines) -join "`r`n") + "`r`n"), $utf8NoBom)
        Write-Host "Set YASB_WALLPAPER_DIR in $EnvFile"
    } else {
        Write-Host "No images found at $imagesDir - leaving YASB_WALLPAPER_DIR unchanged." -ForegroundColor Yellow
    }
}

Write-Host "Wallpapers available: $($images.Count) (press Alt+E in YASB for the gallery)."
