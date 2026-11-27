#Requires -Version 5.1
<#
.SYNOPSIS
    Installs and starts LibreScroll (inertial middle-button scrolling).

.DESCRIPTION
    Downloads the latest LibreScroll release zip from GitHub, verifies the
    SHA-256 digest published by the GitHub API, extracts it to
    %LOCALAPPDATA%\skoop\librescoll\<tag>, adds a per-user Startup shortcut and
    starts it when it is not already running. Idempotent: a re-run with the same
    tag only repairs the shortcut and the running process.

    LibreScroll installs a WH_MOUSE_LL hook that blocks physical wheel events
    and turns middle-button drags into scroll momentum. Pause or quit it from
    its tray icon before running skoopub-mouse diagnostics.
#>
[CmdletBinding()]
param(
    [string]$Repo = 'LibreScroll/LibreScroll',
    [string]$Version = '',
    [switch]$Force,
    [switch]$NoLaunch,
    [switch]$NoAutostart,
    [switch]$AllowUnverified
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Get-InstallRoot {
    $base = $env:LOCALAPPDATA
    if (-not $base) { $base = Join-Path $env:USERPROFILE 'AppData\Local' }
    return (Join-Path $base 'skoop\librescoll')
}

function Get-Release {
    if ($Version) {
        $tag = $Version
        if (-not $tag.StartsWith('v')) { $tag = "v$tag" }
        return Invoke-RestMethod -UseBasicParsing -Uri "https://api.github.com/repos/$Repo/releases/tags/$tag"
    }
    return Invoke-RestMethod -UseBasicParsing -Uri "https://api.github.com/repos/$Repo/releases/latest"
}

$release = Get-Release
$tag = $release.tag_name
if (-not $tag) { throw "could not determine a LibreScroll release tag" }

$asset = $release.assets | Where-Object { $_.name -match '^LibreScroll-.*\.zip$' } | Select-Object -First 1
if (-not $asset) { throw "release $tag has no LibreScroll zip asset" }

$expectedHash = ''
if ($asset.digest -and $asset.digest -match '^sha256:([0-9a-fA-F]{64})$') {
    $expectedHash = $Matches[1].ToLower()
}
if (-not $expectedHash -and -not $AllowUnverified) {
    throw "release $tag has no SHA-256 digest; refusing to install an unverified binary (use -AllowUnverified only if you trust the asset)"
}
if (-not $expectedHash) { Write-Host '    WARNING: no digest published - installing unverified binary (-AllowUnverified)' -ForegroundColor Yellow }

$root = Get-InstallRoot
$installDir = Join-Path $root $tag
$exe = Join-Path $installDir 'LibreScroll.exe'
$versionFile = Join-Path $installDir 'version.txt'
New-Item -ItemType Directory -Force -Path $installDir | Out-Null

$installed = ''
if (Test-Path -LiteralPath $versionFile) { $installed = (Get-Content -LiteralPath $versionFile -Raw).Trim() }
$already = (-not $Force) -and $installed -eq $tag -and (Test-Path -LiteralPath $exe)

if ($already) {
    Write-Host "==> LibreScroll $tag already installed"
} else {
    Write-Host "==> downloading LibreScroll $tag"
    # A running exe holds its image open: stop it before Expand-Archive -Force
    # overwrites it, then start it again below unless -NoLaunch was passed.
    $runningBefore = @(Get-Process LibreScroll -ErrorAction SilentlyContinue)
    if ($runningBefore.Count -gt 0) {
        Write-Host '    stopping the running LibreScroll before the update'
        $runningBefore | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 700
    }
    $zip = Join-Path ([IO.Path]::GetTempPath()) "LibreScroll-$tag-$([guid]::NewGuid().ToString('N')).zip"
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $asset.browser_download_url -OutFile $zip
        $actualHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLower()
        if ($expectedHash -and $actualHash -ne $expectedHash) {
            throw "SHA-256 mismatch for $tag (expected $expectedHash, got $actualHash)"
        }
        Expand-Archive -LiteralPath $zip -DestinationPath $installDir -Force
        Unblock-File -LiteralPath $exe -ErrorAction SilentlyContinue
    } finally {
        if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    }
    if (-not (Test-Path -LiteralPath $exe)) { throw "LibreScroll.exe not found after extracting $tag" }
    Set-Content -LiteralPath $versionFile -Value $tag -Encoding ASCII
    Write-Host "    installed $exe"
}

if (-not $NoAutostart) {
    $startup = [Environment]::GetFolderPath('Startup')
    if ($startup) {
        $shortcut = Join-Path $startup 'LibreScroll.lnk'
        $shell = New-Object -ComObject WScript.Shell
        $link = $shell.CreateShortcut($shortcut)
        $link.TargetPath = $exe
        $link.WorkingDirectory = $installDir
        $link.Description = 'LibreScroll inertial scrolling'
        $link.Save()
        Write-Host "    startup shortcut: $shortcut"
    }
}

if (-not $NoLaunch) {
    $running = Get-Process LibreScroll -ErrorAction SilentlyContinue
    if (-not $running) {
        Start-Process -FilePath $exe -WorkingDirectory $installDir | Out-Null
        Start-Sleep -Seconds 1
        $running = Get-Process LibreScroll -ErrorAction SilentlyContinue
    }
    if ($running) {
        Write-Host "    running (PID $($running[0].Id))"
    } else {
        Write-Host '    could not start LibreScroll' -ForegroundColor Yellow
    }
}

Write-Host "==> LibreScroll $tag ready: hold the middle mouse button and drag to scroll"
