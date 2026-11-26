#Requires -Version 5.1
<#
.SYNOPSIS
    Start the Vicinae server at login (and right now).

.DESCRIPTION
    Vicinae's global shortcut only works while its server is running. Scoop
    installs the server binary but does not register it as a startup app, so
    this script creates a per-user Startup shortcut to
    `apps\vicinae\current\bin\vicinae-server.exe` and launches it in the current
    session unless -NoLaunch is given. Re-running it repairs a shortcut that
    points at an old versioned Scoop folder. -Remove deletes the shortcut.

.PARAMETER NoLaunch
    Only install the Startup shortcut; do not start the server in this session.

.PARAMETER Remove
    Remove the Startup shortcut. Does not stop an already running server.

.EXAMPLE
    .\enable-vicinae-autostart.ps1

.EXAMPLE
    .\enable-vicinae-autostart.ps1 -Remove
#>
[CmdletBinding()]
param(
    [switch]$NoLaunch,
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message)   { Write-Host "    $Message" -ForegroundColor DarkGray }

function Get-VicinaeServer {
    # Prefer the stable `current` folder; a shortcut into a versioned folder
    # goes stale after `scoop update vicinae`.
    foreach ($root in @($env:SCOOP, (Join-Path $env:USERPROFILE 'scoop'), (Join-Path $env:ProgramData 'scoop'))) {
        if (-not $root) { continue }
        $exe = Join-Path $root 'apps\vicinae\current\bin\vicinae-server.exe'
        if (Test-Path -LiteralPath $exe) { return $exe }
    }

    $vicinae = Get-Command vicinae -ErrorAction SilentlyContinue
    if ($vicinae -and $vicinae.Source -match '^(?<root>.+)\\shims\\vicinae\.exe$') {
        $exe = Join-Path $Matches.root 'apps\vicinae\current\bin\vicinae-server.exe'
        if (Test-Path -LiteralPath $exe) { return $exe }
    }
    return $null
}

$startupDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
$linkPath   = Join-Path $startupDir 'Vicinae.lnk'

if ($Remove) {
    if (Test-Path -LiteralPath $linkPath) {
        Remove-Item -LiteralPath $linkPath -Force
        Write-Ok "removed $linkPath (Vicinae will not auto-start at login)"
    } else {
        Write-Ok 'no Vicinae Startup shortcut to remove'
    }
    return
}

$exe = Get-VicinaeServer
if (-not $exe) {
    throw 'vicinae-server.exe not found. Install Vicinae first (scoop install extras/vicinae).'
}
Write-Ok "server: $exe"

New-Item -ItemType Directory -Force -Path $startupDir | Out-Null
$shell = New-Object -ComObject WScript.Shell
try {
    $shortcut = $shell.CreateShortcut($linkPath)
    try {
        $target = if (Test-Path -LiteralPath $linkPath) { $shortcut.TargetPath } else { '' }
        if ([string]::Equals($target, $exe, [StringComparison]::OrdinalIgnoreCase)) {
            Write-Ok "already enabled: $linkPath"
        } else {
            $shortcut.TargetPath       = $exe
            $shortcut.Arguments        = ''
            $shortcut.WorkingDirectory = Split-Path $exe -Parent
            $shortcut.WindowStyle      = 7   # minimized: the server has no window
            $shortcut.Description      = 'Start the Vicinae server at login'
            $shortcut.Save()
            Write-Ok "created $linkPath -> $exe"
        }
    } finally {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut)
    }
} finally {
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
}

if ($NoLaunch) {
    Write-Ok 'skipped launching (use your Vicinae shortcut once the server is running)'
    return
}

if (Get-Process -Name 'vicinae-server' -ErrorAction SilentlyContinue) {
    Write-Ok 'Vicinae server is already running'
} else {
    Write-Step 'Starting the Vicinae server'
    try {
        Start-Process -FilePath $exe -WindowStyle Hidden
        Start-Sleep -Seconds 2
        if (Get-Process -Name 'vicinae-server' -ErrorAction SilentlyContinue) {
            Write-Ok 'Vicinae server started'
        } else {
            Write-Host '    Server did not stay running; check `vicinae logs`.' -ForegroundColor Yellow
        }
    } catch {
        Write-Host "    Could not start Vicinae (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

Write-Host ''
Write-Host 'Vicinae will now start when you sign in.' -ForegroundColor Green
