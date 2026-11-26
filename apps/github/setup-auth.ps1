# apps/github/setup-auth.ps1
# Makes `git push` use your GitHub CLI login instead of prompting for a username.
# Being logged in to `gh` is not enough: git needs gh registered as a credential
# helper (`gh auth setup-git`). This script does both, and is safe to re-run.
#
#   .\apps/github/setup-auth.ps1
#   .\apps/github/setup-auth.ps1 -SkipLogin     # non-interactive: only wire up an existing login
#   .\apps/github/setup-auth.ps1 -ForceLogin    # re-authenticate even if already logged in
[CmdletBinding()]
param(
    # Do not launch `gh auth login`; if not logged in, print the command and stop.
    [switch]$SkipLogin,
    # Run `gh auth login` even when GitHub CLI is already authenticated.
    [switch]$ForceLogin
)

$ErrorActionPreference = 'Stop'

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message)   { Write-Host "    $Message" -ForegroundColor DarkGray }

function Test-GhAuth {
    # gh writes status diagnostics to stderr; route through cmd and inspect the
    # exit code so PS 5.1 does not turn it into a terminating NativeCommandError.
    $null = & cmd /c 'gh auth status --hostname github.com 2>&1'
    return ($LASTEXITCODE -eq 0)
}

if ($SkipLogin -and $ForceLogin) { throw '-SkipLogin and -ForceLogin cannot be combined.' }

# --- 1. Locate gh (or install it with Scoop) ----------------------------------
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    $shimDir = @(
        (Join-Path $env:USERPROFILE 'scoop\shims'),
        (Join-Path $env:ProgramData 'scoop\shims')
    ) | Where-Object { Test-Path (Join-Path $_ 'scoop.cmd') } | Select-Object -First 1
    if ($shimDir) { $env:Path = "$shimDir;$env:Path" }
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    $scoopCmd = @(
        (Join-Path $env:USERPROFILE 'scoop\shims\scoop.cmd'),
        (Join-Path $env:ProgramData 'scoop\shims\scoop.cmd')
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $scoopCmd) {
        throw 'gh not found. Run install.ps1 first (it installs gh via scoop.json), or install GitHub CLI manually.'
    }
    Write-Step 'Installing gh with Scoop'
    & $scoopCmd install gh
    if ($LASTEXITCODE -ne 0) { throw "scoop install gh failed with exit code $LASTEXITCODE." }
    $env:Path = "$(Split-Path $scoopCmd -Parent);$env:Path"
}
Write-Ok "gh found: $((Get-Command gh).Source)"

# --- 2. Ask to log in, then let gh do the interactive part -------------------
if (-not $ForceLogin -and (Test-GhAuth)) {
    Write-Ok 'GitHub CLI is already logged in to github.com'
} elseif ($SkipLogin -or -not [Environment]::UserInteractive) {
    Write-Host 'GitHub CLI is not logged in to github.com.' -ForegroundColor Yellow
    Write-Host 'Run "gh auth login" yourself, then re-run this script.' -ForegroundColor Yellow
    return
} else {
    Write-Host 'GitHub CLI is not logged in to github.com yet.'
    $answer = Read-Host 'Run "gh auth login" now? [Y/n]'
    if ($answer -match '^(n|no)$') {
        Write-Host 'Skipped login. Run "gh auth login" then ".\apps/github/setup-auth.ps1" when ready.' -ForegroundColor Yellow
        return
    }
    Write-Step 'Running gh auth login (follow the prompts)'
    # HTTPS matches this repo's remote; skip the unused SSH key prompt.
    & cmd /c 'gh auth login --hostname github.com --git-protocol https --skip-ssh-key'
    if ($LASTEXITCODE -ne 0) { throw "gh auth login failed with exit code $LASTEXITCODE." }
    Write-Ok 'GitHub CLI is logged in'
}

# --- 3. Register gh as git's credential helper for GitHub --------------------
Write-Step 'Applying the login to git (gh auth setup-git)'
$null = & cmd /c 'gh auth setup-git 2>&1'
if ($LASTEXITCODE -ne 0) { throw "gh auth setup-git failed with exit code $LASTEXITCODE." }

# Query git directly: cmd wraps long values at the console width, which breaks
# a plain "gh auth git-credential" match.
$helper = ((& git config --global --get 'credential.https://github.com.helper' 2>$null) -join ' ').Trim()
if ($helper -notmatch 'auth\s+git-credential') {
    throw "git credential helper was not configured: $helper"
}
Write-Ok "credential.https://github.com.helper -> $helper"

Write-Host ''
Write-Host 'Done. git push will now use your gh login - no username prompt.' -ForegroundColor Green
