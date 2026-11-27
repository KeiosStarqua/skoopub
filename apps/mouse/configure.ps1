#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the skoopub-mouse executable locally from a GitHub Release (or a local cargo build).

.DESCRIPTION
    Default: fetch the newest `mouse-v*` release of KeiosStarqua/skoopub and
    download its `skoopub-mouse.exe` asset to %LOCALAPPDATA%\skoop\mouse.
    Re-runs skip the download when the same tag is already installed; -Force
    re-downloads. -Build compiles the in-repo Rust crate instead (needs cargo
    and the GNU target, which skoop installs for kbots).
#>
[CmdletBinding()]
param(
    [string]$Repo = 'KeiosStarqua/skoopub',
    [string]$Version = '',
    [switch]$Force,
    [switch]$Build,
    [string]$ExePath = ''
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Get-InstallDir {
    $base = $env:LOCALAPPDATA
    if (-not $base) { $base = Join-Path $env:USERPROFILE 'AppData\Local' }
    return (Join-Path $base 'skoop\mouse')
}

$installDir = Get-InstallDir
$targetExe  = if ($ExePath) { $ExePath } else { Join-Path $installDir 'skoopub-mouse.exe' }
$versionFile = Join-Path $installDir 'version.txt'
New-Item -ItemType Directory -Force -Path (Split-Path $targetExe -Parent) | Out-Null

$tag = ''
if ($Version) {
    $tag = if ($Version.StartsWith('v')) { "mouse$Version" } else { "mouse-v$Version" }
}

if ($Build) {
    $cargo = Get-Command cargo -ErrorAction SilentlyContinue
    if (-not $cargo) { throw 'cargo not found on PATH; install rustup (skoop installs it in the editors phase) or omit -Build to download a release.' }
    $manifest = Join-Path $PSScriptRoot 'Cargo.toml'
    Write-Host "==> building $manifest (x86_64-pc-windows-gnu)"
    $olderToolchain = $env:RUSTUP_TOOLCHAIN
    $env:RUSTUP_TOOLCHAIN = 'stable-x86_64-pc-windows-gnu'
    try {
        & $cargo.Source build --release --target x86_64-pc-windows-gnu --manifest-path $manifest
        if ($LASTEXITCODE -ne 0) { throw "cargo build failed with exit $LASTEXITCODE" }
    } finally {
        $env:RUSTUP_TOOLCHAIN = $olderToolchain
    }
    $built = Join-Path $PSScriptRoot 'target\x86_64-pc-windows-gnu\release\skoopub-mouse.exe'
    if (-not (Test-Path -LiteralPath $built)) { throw "built executable not found at $built" }
    Copy-Item -LiteralPath $built -Destination $targetExe -Force
    Unblock-File -LiteralPath $targetExe -ErrorAction SilentlyContinue
    $tag = 'local-build'
    Set-Content -LiteralPath $versionFile -Value $tag -Encoding ASCII
    Write-Host "    installed $targetExe"
    return $targetExe
}

$asset = $null
if ($tag) {
    $release = Invoke-RestMethod -UseBasicParsing -Uri "https://api.github.com/repos/$Repo/releases/tags/$tag"
    $asset = $release.assets | Where-Object { $_.name -eq 'skoopub-mouse.exe' } | Select-Object -First 1
    if (-not $asset) { throw "release $tag has no skoopub-mouse.exe asset" }
} else {
    $releases = Invoke-RestMethod -UseBasicParsing -Uri "https://api.github.com/repos/$Repo/releases?per_page=100"
    $latest = $releases | Where-Object { $_.tag_name -like 'mouse-v*' -and -not $_.draft } |
        Sort-Object published_at -Descending | Select-Object -First 1
    if (-not $latest) { throw "no mouse-v* release found in $Repo; run the GitHub workflow or use -Build" }
    $tag = $latest.tag_name
    $asset = $latest.assets | Where-Object { $_.name -eq 'skoopub-mouse.exe' } | Select-Object -First 1
    if (-not $asset) { throw "release $tag has no skoopub-mouse.exe asset" }
}

$installed = ''
if (Test-Path -LiteralPath $versionFile) { $installed = (Get-Content -LiteralPath $versionFile -Raw).Trim() }
if (-not $Force -and $installed -eq $tag -and (Test-Path -LiteralPath $targetExe)) {
    Write-Host "==> skoopub-mouse $tag already installed"
    return $targetExe
}

Write-Host "==> downloading skoopub-mouse $tag"
$temp = Join-Path ([IO.Path]::GetTempPath()) "skoopub-mouse-$([guid]::NewGuid().ToString('N')).exe"
try {
    Invoke-WebRequest -UseBasicParsing -Uri $asset.browser_download_url -OutFile $temp
    Unblock-File -LiteralPath $temp -ErrorAction SilentlyContinue
    Move-Item -LiteralPath $temp -Destination $targetExe -Force
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
}
Set-Content -LiteralPath $versionFile -Value $tag -Encoding ASCII
Write-Host "    installed $targetExe"
return $targetExe
