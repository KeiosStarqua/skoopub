# configure-starship.ps1
# Deploy the repo-managed Starship prompt for PowerShell and cmd.
#
# PowerShell: profile.ps1 runs `starship init powershell`, and this script puts
# the config at ~/.config/starship.toml (Starship's default location, so no
# STARSHIP_CONFIG variable is needed).
#
# cmd: Starship needs Clink. This script writes starship.lua to Clink's scripts
# folder (%LOCALAPPDATA%\clink) and runs `clink autorun install`, so cmd.exe
# loads Clink (and therefore Starship) on start. Existing AutoRun entries such
# as the Nushell `n` doskey macro are preserved - Clink appends its own command.
#
#   powershell -ExecutionPolicy Bypass -File .\configure-starship.ps1
#   powershell -ExecutionPolicy Bypass -File .\configure-starship.ps1 -NoCmd
#   powershell -ExecutionPolicy Bypass -File .\configure-starship.ps1 -NoBackup
[CmdletBinding()]
param(
    [string]$SourceFile = '',
    [string]$ConfigDir = '',
    [string]$ClinkScriptsDir = '',
    # Overwrite changed files directly instead of keeping a timestamped .bak.
    [switch]$NoBackup,
    # Only deploy the config; leave cmd.exe / Clink alone.
    [switch]$NoCmd,
    # Write starship.lua but do not touch cmd.exe's AutoRun registry value.
    [switch]$NoAutorun
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is not populated during parameter binding in PowerShell 5.1.
if (-not $SourceFile) { $SourceFile = Join-Path $PSScriptRoot 'starship\starship.toml' }
if (-not $ConfigDir) {
    $homeDir = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
    $ConfigDir = Join-Path $homeDir '.config'
}
if (-not $ClinkScriptsDir) {
    if ($env:LOCALAPPDATA) { $ClinkScriptsDir = Join-Path $env:LOCALAPPDATA 'clink' }
    else { $ClinkScriptsDir = Join-Path $env:USERPROFILE 'AppData\Local\clink' }
}

if (-not (Test-Path -LiteralPath $SourceFile)) {
    throw "Starship config source not found: $SourceFile"
}

function Read-Utf8Text {
    # PowerShell 5.1's Get-Content -Raw decodes BOM-less files as ANSI, which
    # turns the prompt glyphs (❯) into mojibake. Always decode as UTF-8.
    param([string]$Path)
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    return ($text -replace "^\uFEFF", '')
}

function Write-Utf8NoBom {
    # Starship's TOML parser and Clink's Lua loader both dislike a BOM, and
    # Set-Content -Encoding UTF8 in PowerShell 5.1 writes one.
    param([string]$Path, [string]$Text)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Install-ManagedFile {
    # Copy $Text over $Path, keeping a timestamped backup of a changed original.
    # Returns $true when the file was written.
    param([string]$Path, [string]$Text, [string]$Label)
    $normalize = { param([string]$Value) return ($Value -replace "`r`n", "`n").TrimEnd() }
    $desired = & $normalize $Text

    New-Item -ItemType Directory -Force -Path (Split-Path -LiteralPath $Path) | Out-Null

    if (Test-Path -LiteralPath $Path) {
        $existing = & $normalize (Read-Utf8Text -Path $Path)
        if ($existing -eq $desired) {
            Write-Host "$Label already up to date: $Path" -ForegroundColor DarkGray
            return $false
        }
        if (-not $NoBackup) {
            $backup = '{0}.bak.{1}' -f $Path, (Get-Date -Format 'yyyyMMdd-HHmmss')
            Copy-Item -LiteralPath $Path -Destination $backup -Force
            Write-Host "Backed up $Path -> $backup"
        }
    }

    Write-Utf8NoBom -Path $Path -Text $Text
    Write-Host "Installed ${Label}: $Path" -ForegroundColor Green
    return $true
}

$destination = Join-Path $ConfigDir 'starship.toml'
$configText = Read-Utf8Text -Path $SourceFile
Install-ManagedFile -Path $destination -Text $configText -Label 'Starship config' | Out-Null

if ($NoCmd) {
    Write-Host 'Skipping the cmd.exe / Clink setup (-NoCmd).' -ForegroundColor DarkGray
} else {
    $clink = Get-Command clink -ErrorAction SilentlyContinue
    if (-not $clink) {
        Write-Host 'Clink is not installed - cmd.exe keeps its stock prompt.' -ForegroundColor Yellow
        Write-Host '    Clink is in scoop.json; install it with: scoop install clink'
    } else {
        # The loader is the snippet from https://starship.rs/#cmd - Clink runs
        # every .lua file in its scripts folder when cmd.exe starts.
        $luaLines = @(
            '-- skoop: Starship prompt for cmd.exe (managed by configure-starship.ps1).',
            '-- Loads the Clink script that Starship prints for cmd.',
            "load(io.popen('starship init cmd'):read('*a'))()"
        )
        $luaPath = Join-Path $ClinkScriptsDir 'starship.lua'
        Install-ManagedFile -Path $luaPath -Text ($luaLines -join "`n") -Label 'Clink loader' | Out-Null

        if ($NoAutorun) {
            Write-Host 'Skipping `clink autorun install` (-NoAutorun).' -ForegroundColor DarkGray
            Write-Host '    Run it yourself so cmd.exe starts Clink (and Starship).'
        } else {
            # cmd /c keeps Clink's stderr from becoming a PowerShell error.
            $out = (& cmd /c ('"{0}" autorun install 2>&1' -f $clink.Source) | Out-String)
            if ($LASTEXITCODE -ne 0) {
                Write-Host 'Clink autorun install failed - cmd.exe will not load Starship.' -ForegroundColor Yellow
                foreach ($line in ($out -split "`r?`n")) {
                    if ($line.Trim()) { Write-Host "    $($line.Trim())" }
                }
            } else {
                Write-Host 'Clink autorun installed for cmd.exe.' -ForegroundColor Green
            }

            # The Nushell `n` macro lives in the same AutoRun value; Clink is
            # supposed to append, but verify so a Clink upgrade cannot silently
            # drop it.
            $autoRunKey = 'HKCU:\Software\Microsoft\Command Processor'
            $autoRun = (Get-ItemProperty -LiteralPath $autoRunKey -Name AutoRun -ErrorAction SilentlyContinue).AutoRun
            $nuLauncher = Join-Path $env:LOCALAPPDATA 'skoop\nu-autostart.cmd'
            if ((Test-Path -LiteralPath $nuLauncher) -and "$autoRun" -notmatch 'nu-autostart') {
                Write-Host 'The Nushell doskey entry is missing from cmd AutoRun - re-run .\setup-nushell.ps1' -ForegroundColor Yellow
            }
        }
    }
}

Write-Host ''
Write-Host 'Starship is deployed. Restart PowerShell (profile.ps1 runs `starship init powershell`)' -ForegroundColor Green
Write-Host 'and open a new cmd.exe window (Clink loads starship.lua) to see the prompt.' -ForegroundColor Green
