# apps/yasb/configure.ps1
# Fetch the selected theme's config.yaml + styles.css from the community YASB
# themes catalog into ~/.config/yasb, create a .env from the template when
# missing, clone the wallpaper collection once, and start YASB.
#
# Theme files are deliberately NOT committed to this repo: there are ~70 themes
# in the catalog and YASB's Themes Manager (yasb_themes.exe) can install any of
# them. This script only applies a known default on a fresh machine. Pass
# -ThemeId (or set SKOOP_YASB_THEME_ID) to use a different catalog theme id.
#
#   powershell -ExecutionPolicy Bypass -File .\apps\yasb\configure.ps1
#   powershell -ExecutionPolicy Bypass -File .\apps\yasb\configure.ps1 -ThemeId 92a8f104-ab80-45c0-95f1-82ebb2e12df6
#   powershell -ExecutionPolicy Bypass -File .\apps\yasb\configure.ps1 -Restart
[CmdletBinding()]
param(
    # Resolved in the body: $PSScriptRoot is empty during param binding in PS 5.1.
    [string]$SourceDir = '',
    [string]$ConfigDir = '',
    # Catalog theme id to apply on fresh installs (default: dots windows).
    [string]$ThemeId = 'd513044f-9218-46e1-ab62-c15705b80341',
    # Overwrite changed files directly instead of keeping a timestamped .bak.
    [switch]$NoBackup,
    # Stop and relaunch YASB so the config is reloaded immediately.
    [switch]$Restart,
    # Skip the one-time aesthetic-wallpapers clone (also SKOOP_NO_WALLPAPERS=1).
    [switch]$NoWallpapers
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ($env:SKOOP_YASB_THEME_ID) { $ThemeId = $env:SKOOP_YASB_THEME_ID }
if ($ThemeId -notmatch '^[a-zA-Z0-9_-]+$') {
    Write-Host "Invalid YASB theme id: $ThemeId" -ForegroundColor Yellow
    return
}

if (-not $SourceDir) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    if (-not $scriptDir) { $scriptDir = $PSScriptRoot }
    $SourceDir = $scriptDir
}
if (-not $ConfigDir) {
    if ($env:USERPROFILE) { $ConfigDir = Join-Path $env:USERPROFILE '.config\yasb' }
    else { $ConfigDir = Join-Path $env:APPDATA 'yasb' }
}
New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null

# Load the user's YASB settings before patching the theme. YASB reads .env from
# this same folder, and its weather widget supports location: "env", so the
# location survives a theme re-download as long as .env keeps the value.
$example = Join-Path $SourceDir '.env.example'
$envFile = Join-Path $ConfigDir '.env'
if ((Test-Path -LiteralPath $example) -and -not (Test-Path -LiteralPath $envFile)) {
    Copy-Item -LiteralPath $example -Destination $envFile
    Write-Host "Created $envFile from the template - fill in any values you need."
}
function Get-YasbEnvValue {
    param([string]$Name)
    if (-not (Test-Path -LiteralPath $envFile)) { return '' }
    foreach ($line in [System.IO.File]::ReadAllLines($envFile)) {
        if ($line -match "^\s*$Name\s*=\s*(.*?)\s*$") {
            return $Matches[1].Trim().Trim('"', "'")
        }
    }
    return ''
}
$weatherLocation = Get-YasbEnvValue 'YASB_WEATHER_LOCATION'

function Add-WallpapersWidget {
    # Many catalog themes (including the default dots windows) have no wallpapers
    # widget at all. Add one so YASB's own hotkey + gallery can change wallpapers:
    #   Ctrl+Alt+w or Alt+E -> open gallery, Left/Right + Enter -> apply.
    # Right-clicking the widget changes to a random wallpaper directly.
    param([string]$Text)
    if ($Text -match '(?m)^\s*wallpapers:\s*') { return $Text }

    $widget = @'
  wallpapers:
    type: "yasb.wallpapers.WallpapersWidget"
    options:
      label: "Wallpaper"
      image_path: "$env:YASB_WALLPAPER_DIR"
      change_automatically: false
      gallery:
        type: "magnified"
        image_width: 220
        image_corner_radius: 8
      keybindings:
        - keys: "ctrl+alt+w"
          action: "toggle_gallery"
          screen: "cursor"
        - keys: "alt+e"
          action: "toggle_gallery"
          screen: "cursor"
      callbacks:
        on_left: "toggle_gallery"
        on_middle: "do_nothing"
        on_right: "change_wallpaper"
'@
    # Insert before the top-level `widgets:` mapping so YAML stays valid.
    $marker = "`nwidgets:"
    $idx = $Text.IndexOf($marker)
    if ($idx -lt 0) { return $Text + "`n`n" + $widget }
    return $Text.Insert($idx + 1, $widget + "`n`n")
}

function Add-WallpapersToBar {
    # The widget only registers its keybindings when it is placed in a bar.
    # Append it to the first right-hand widget list under `bars:`.
    param([string]$Text)
    if ($Text -match '"wallpapers"') { return $Text }
    $marker = 'right: ['
    $idx = $Text.IndexOf($marker)
    if ($idx -lt 0) { return $Text }
    return $Text.Insert($idx + $marker.Length, "`n        `"wallpapers`",")
}

$themeBase = 'https://raw.githubusercontent.com/amnweb/yasb-themes/main/themes/{0}' -f $ThemeId
$themeName = $ThemeId
try {
    $catalog = Invoke-RestMethod 'https://raw.githubusercontent.com/amnweb/yasb-themes/refs/heads/main/themes.json' -TimeoutSec 30
    $entry = @($catalog.PSObject.Properties | Where-Object { $_.Name -eq $ThemeId })
    if ($entry.Count -gt 0 -and $entry[0].Value.name) { $themeName = $entry[0].Value.name }
} catch {
    # Name is cosmetic; the raw file URLs below are enough to apply the theme.
}

$patch = {
    param([string]$Text)
    # Keep no machine-specific paths and let Scoop own the version.
    $text = $Text -replace '(?m)^(\s*image_path:\s*).*$', '$1"$env:YASB_WALLPAPER_DIR" # Set in ~/.config/yasb/.env (see .env.example)'
    $text = $text -replace '(?m)^(\s*path:\s*)[''"]?[A-Za-z]:\\.*[Ww]allpaper.*$', '$1"$env:YASB_WALLPAPER_DIR"'
    $text = $text -replace '(?m)^(\s*update_check:\s*).*$', '${1}false'
    # Use YASB's native env support so the theme's hardcoded location does not
    # overwrite the user's choice on a fresh install or theme change.
    if ($weatherLocation) {
        $text = $text -replace '(?m)^(\s*location:\s*).*$', '${1}"env"'
    }
    # Nerd Font supplies the F0xxx/EAF8 glyphs, Segoe Fluent Icons supplies E972
    # and the Windows system glyphs; neither alone covers every theme label.
    $text = $text -replace '(?m)^(\s*--icons-font(?:-fallback)?:\s*).*$', '$1"JetBrainsMono NFP", "Segoe Fluent Icons";'
    $text = $text -replace '(?m)^(\s*font-family:\s*)"Segoe Fluent Icons".*$', '$1"Segoe Fluent Icons", "JetBrainsMono NFP";'
    $text = Add-WallpapersWidget $text
    $text = Add-WallpapersToBar $text
    return $text
}

function Set-DeployedFile {
    param([string]$Name, [string]$Content)
    $destination = Join-Path $ConfigDir $Name
    $normalize = { param($s) (($s -replace "`r`n", "`n")).TrimEnd() }
    $desired = & $normalize $Content
    if (Test-Path -LiteralPath $destination) {
        $existing = & $normalize ([System.IO.File]::ReadAllText($destination))
        if ($existing -eq $desired) {
            Write-Host "$Name already up to date."
            return
        }
        if (-not $NoBackup) {
            $backup = '{0}.bak.{1}' -f $destination, (Get-Date -Format 'yyyyMMdd-HHmmss')
            Copy-Item -LiteralPath $destination -Destination $backup -Force
            Write-Host "Backed up $destination -> $backup"
        }
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($destination, ($desired + "`r`n"), $utf8NoBom)
    Write-Host "Installed $destination"
}

foreach ($file in @('config.yaml', 'styles.css')) {
    try {
        $raw = (Invoke-WebRequest -Uri "$themeBase/$file" -UseBasicParsing -TimeoutSec 45).Content
        $content = & $patch $raw
        if ($file -eq 'config.yaml' -and $content -notmatch '(?m)^update_check:') {
            $content = "update_check: false`r`n" + $content
        }
        if ($file -eq 'styles.css') {
            # Many themes only style icon colour/size per widget and rely on the
            # global '*' font, so Nerd Font glyphs fall back to Segoe UI boxes.
            $content = $content.TrimEnd() + @"

/* skoop: render Nerd Font glyphs inside widget labels/icons */
.widget .icon,
.widget .label span {
    font-family: "JetBrainsMono NFP", "Segoe Fluent Icons";
}
"@
        }
        Set-DeployedFile -Name $file -Content $content
    } catch {
        Write-Host "Could not fetch $file for '$themeName' ($($_.Exception.Message)) - existing file left untouched." -ForegroundColor Yellow
    }
}

# Fonts: theme CSS names fonts by their Windows family ("JetBrainsMono NFP"),
# not by the Scoop package ("JetBrainsMono-NF-Propo"). Detect what is missing
# and install known Nerd Font packages so icons are not boxes on Windows 10.
$fontPackages = @{
    'JetBrainsMono NFP'              = 'JetBrainsMono-NF-Propo'
    'JetBrainsMono Nerd Font Propo'  = 'JetBrainsMono-NF-Propo'
    'JetBrainsMono NF'               = 'JetBrainsMono-NF'
    'JetBrainsMono Nerd Font'        = 'JetBrainsMono-NF'
    'CaskaydiaCove NFP'              = 'CascadiaCode-NF-Propo'
    'CaskaydiaCove NF'               = 'CascadiaCode-NF'
    'CascadiaCode NFP'               = 'CascadiaCode-NF-Propo'
    'CascadiaCode NF'                = 'CascadiaCode-NF'
    'Symbols Nerd Font'              = 'NerdFontsSymbolsOnly'
    'Symbols Nerd Font Mono'         = 'NerdFontsSymbolsOnly'
    'Font Awesome'                   = 'Font-Awesome'
    'Font Awesome 6 Free'            = 'Font-Awesome'
}
# Google Fonts families with no Scoop package; installed per-user from the
# upstream google/fonts repo (OFL). The variable Rubik file exposes the
# "Rubik Light" family used by the dots windows theme.
$googleFonts = @{
    'Rubik Light' = 'https://raw.githubusercontent.com/google/fonts/main/ofl/rubik/Rubik%5Bwght%5D.ttf'
}
# Some themes spell the Nerd Font family differently from its Windows name.
$fontAliases = @{
    'JetBrainsMono Nerd Font Propo' = 'JetBrainsMono NFP'
    'JetBrainsMono Nerd Font'       = 'JetBrainsMono NF'
    'CaskaydiaCove NFP'             = 'CascadiaCode NFP'
    'CaskaydiaCove NF'              = 'CascadiaCode NF'
    'Font Awesome 6 Free'           = 'Font Awesome'
}
function Get-InstalledFontNames {
    try {
        Add-Type -AssemblyName System.Drawing
        return @((New-Object System.Drawing.Text.InstalledFontCollection).Families | ForEach-Object { $_.Name })
    } catch {
        return @()
    }
}
function Install-SegoeFluentIcons {
    # Windows 10 does not ship this font; Microsoft provides it as a ZIP with an
    # EULA at aka.ms/SegoeFluentIcons. Install per-user (no admin), never commit it.
    $url = 'https://aka.ms/SegoeFluentIcons'
    $zipPath = Join-Path $env:TEMP 'skoop-segoe-fluent-icons.zip'
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        Write-Host 'Downloading Segoe Fluent Icons from Microsoft (aka.ms/SegoeFluentIcons)...'
        Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing -TimeoutSec 60
        $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        try {
            $entry = $zip.Entries | Where-Object { $_.FullName -like '*.ttf' } | Select-Object -First 1
            if (-not $entry) { throw 'No TTF found in the Microsoft font archive.' }
            $fontDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
            New-Item -ItemType Directory -Force -Path $fontDir | Out-Null
            $destination = Join-Path $fontDir 'Segoe Fluent Icons.ttf'
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destination, $true)
            $key = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
            New-ItemProperty -Path $key -Name 'Segoe Fluent Icons (TrueType)' -Value $destination -PropertyType String -Force | Out-Null
            Write-Host "Installed Segoe Fluent Icons at $destination"
        } finally {
            $zip.Dispose()
            Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Host "Could not install Segoe Fluent Icons (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host '    Download it from https://aka.ms/SegoeFluentIcons and accept the EULA.' -ForegroundColor Yellow
    }
}
function Install-GoogleFont {
    param([string]$Family, [string]$Url)
    try {
        $fontDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
        New-Item -ItemType Directory -Force -Path $fontDir | Out-Null
        $fileName = (($Family -replace '[^A-Za-z0-9]+', '-').Trim('-')) + '.ttf'
        $destination = Join-Path $fontDir $fileName
        Write-Host "Downloading $Family from Google Fonts..."
        Invoke-WebRequest -Uri $Url -OutFile $destination -UseBasicParsing -TimeoutSec 60
        $key = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
        New-ItemProperty -Path $key -Name "$Family (TrueType)" -Value $destination -PropertyType String -Force | Out-Null
        Write-Host "Installed $Family at $destination"
    } catch {
        Write-Host "Could not install $Family (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
    }
}
function Ensure-ThemeFonts {
    param([string]$StylesPath)
    if (-not (Test-Path -LiteralPath $StylesPath)) { return }
    $css = Get-Content -Raw -LiteralPath $StylesPath
    $declared = @()
    foreach ($match in [regex]::Matches($css, '(?m)^\s*(?:--[\w-]*font[\w-]*|font-family)\s*:\s*([^;]+);')) {
        foreach ($quoted in [regex]::Matches($match.Groups[1].Value, '"([^"]+)"')) {
            $declared += $quoted.Groups[1].Value
        }
    }
    $installed = Get-InstalledFontNames
    $missing = @($declared | Where-Object {
        $installed -notcontains $_ -and -not ($fontAliases.ContainsKey($_) -and $installed -contains $fontAliases[$_])
    } | Sort-Object -Unique)
    if ($missing.Count -eq 0) { return }
    $scoop = Get-Command scoop -ErrorAction SilentlyContinue
    foreach ($name in $missing) {
        if ($name -eq 'Segoe UI Variable') { continue } # Windows 11 only; CSS falls back to Segoe UI
        if ($name -eq 'Segoe Fluent Icons') {
            if ($installed -notcontains 'Segoe Fluent Icons') { Install-SegoeFluentIcons }
            continue
        }
        if ($googleFonts.ContainsKey($name)) {
            Install-GoogleFont -Family $name -Url $googleFonts[$name]
            continue
        }
        if ($fontPackages.ContainsKey($name)) {
            $package = $fontPackages[$name]
            if (-not $scoop) {
                Write-Host "Font '$name' missing; install it with: scoop install $package" -ForegroundColor Yellow
                continue
            }
            Write-Host "Installing font '$name' via scoop install $package ..."
            $previous = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                $output = & $scoop.Source install $package 2>&1 | Out-String
                $code = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $previous
            }
            if ($code -ne 0) {
                Write-Host "    scoop install $package failed (exit $code): $($output.Trim())" -ForegroundColor Yellow
            }
        } else {
            Write-Host "Font '$name' referenced by the theme is missing and has no known Scoop package." -ForegroundColor Yellow
        }
    }
}
Ensure-ThemeFonts -StylesPath (Join-Path $ConfigDir 'styles.css')

# .env is created near the top (before the theme patch); an existing one is never
# overwritten here - it may hold the user's API key, location and wallpaper path.

# The wallpapers widget reads YASB_WALLPAPER_DIR. Clone the community collection
# once and point the env var at its images folder. Non-fatal when offline.
$wallpapersScript = Join-Path $SourceDir 'setup-wallpapers.ps1'
if ($NoWallpapers -or $env:SKOOP_NO_WALLPAPERS -eq '1') {
    Write-Host 'Skipping wallpaper setup (-NoWallpapers).' -ForegroundColor DarkGray
} elseif (Test-Path -LiteralPath $wallpapersScript) {
    try {
        & $wallpapersScript -EnvFile $envFile
    } catch {
        Write-Host "    Wallpaper setup failed (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
    }
} else {
    Write-Host 'setup-wallpapers.ps1 not found - YASB_WALLPAPER_DIR left unchanged.' -ForegroundColor Yellow
}

function Resolve-Tool {
    param([string]$Name)
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    foreach ($root in @($env:SCOOP, (Join-Path $env:USERPROFILE 'scoop'))) {
        if (-not $root) { continue }
        $shim = Join-Path $root "shims\$Name.exe"
        if (Test-Path -LiteralPath $shim) { return $shim }
    }
    return $null
}

$yasbc = Resolve-Tool 'yasbc'
if (-not $yasbc) {
    Write-Host 'yasbc not found; YASB config deployed but not started.' -ForegroundColor Yellow
    return
}

$colorsFile = Join-Path $ConfigDir 'yasb_colors.css'
$colorsExisted = Test-Path -LiteralPath $colorsFile
$running = [bool](Get-Process -Name yasb -ErrorAction SilentlyContinue)
if ($running -and $Restart) {
    Write-Host 'Restarting YASB...'
    & $yasbc stop 2>&1 | ForEach-Object { Write-Host "    $_" }
    Start-Sleep -Milliseconds 700
    $running = $false
}
if (-not $running) {
    Write-Host 'Starting YASB...'
    & $yasbc start 2>&1 | ForEach-Object { Write-Host "    $_" }
    Start-Sleep -Seconds 2
}

# With system_colors: true, YASB generates yasb_colors.css after the first CSS
# pass, so a theme that @imports it can log a missing-file error on first run.
# Reload once when the file appeared during this run so the import resolves.
if (-not $colorsExisted -and (Test-Path -LiteralPath $colorsFile) -and
    (Get-Process -Name yasb -ErrorAction SilentlyContinue)) {
    Write-Host 'Reloading YASB so the generated yasb_colors.css is picked up...'
    & $yasbc reload 2>&1 | ForEach-Object { Write-Host "    $_" }
    Start-Sleep -Milliseconds 600
}

if (Get-Process -Name yasb -ErrorAction SilentlyContinue) {
    Write-Host "YASB is running with the '$themeName' theme ($ConfigDir)." -ForegroundColor Green
} else {
    Write-Host 'YASB did not stay running; check `yasbc log`.' -ForegroundColor Yellow
}
