# skoop shell config
# Dot-sourced from $PROFILE, so the setup lives in this repo and is versioned.
# Keep this file idempotent: it runs every time a PowerShell session starts.

# Herdr marks its panes with HERDR_ENV=1. A terminal launched from a Herdr
# pane (Rio, WezTerm, etc.) inherits those variables, so a fresh shell
# can be mistaken for a nested Herdr session and `herdr` refuses to start.
# Clear them unless this shell was started directly by Herdr (a real pane).
function Clear-HerdrEnv {
    foreach ($name in @(
        'HERDR_ENV', 'HERDR_PANE_ID', 'HERDR_TAB_ID',
        'HERDR_WORKSPACE_ID', 'HERDR_SOCKET_PATH', 'HERDR_BIN_PATH'
    )) {
        Remove-Item "Env:$name" -ErrorAction SilentlyContinue
    }
}

if ($env:HERDR_ENV -eq '1') {
    # Herdr starts a pane's shell directly, so that shell's parent is herdr.exe
    # and its markers are genuine. A terminal (Rio, WezTerm, Windows
    # Terminal, cmd, Explorer) that was itself launched from a Herdr pane passes
    # the same variables on; drop them for shells started inside such a terminal.
    $self = Get-CimInstance Win32_Process -Filter "ProcessId = $PID" -ErrorAction SilentlyContinue
    $parentName = ''
    if ($self) {
        $parent = Get-CimInstance Win32_Process -Filter "ProcessId = $($self.ParentProcessId)" -ErrorAction SilentlyContinue
        if ($parent) { $parentName = $parent.Name }
    }
    if ($parentName -match '^(rio|wezterm-gui|wezterm|WindowsTerminal|wt|cmd|conhost|explorer)\.exe$') {
        Clear-HerdrEnv
    }
}

# zoxide: smarter `cd` — `z <query>`, `z ..`, `z -`
if (Get-Command zoxide -ErrorAction SilentlyContinue) {
    Invoke-Expression (& { (zoxide init powershell | Out-String) })
}

# atuin: shell history with search (Ctrl+R)
if (Get-Command atuin -ErrorAction SilentlyContinue) {
    # atuin's init checks for a *loaded* PSReadLine, so import it first.
    if (-not (Get-Module PSReadLine -ErrorAction Ignore)) {
        Import-Module PSReadLine -ErrorAction SilentlyContinue
    }
    if (Get-Module PSReadLine -ErrorAction Ignore) {
        Invoke-Expression (& { (atuin init powershell | Out-String) })
    }
}

# Nushell: `n` starts Nushell from PowerShell; the `nu` shim also works directly.
# Guarded so a machine without nu (or with its own `n` alias) stays untouched.
if (Get-Command nu -ErrorAction SilentlyContinue) {
    if (-not (Get-Alias -Name n -ErrorAction SilentlyContinue)) {
        Set-Alias -Name n -Value nu -Scope Global
    }
}

# btop-lhm installs the `btop` binary, so expose the package name as a command
# too (`btop-lhm` / `btop-lh` both start btop). Guarded for machines without it.
if (Get-Command btop -ErrorAction SilentlyContinue) {
    foreach ($aliasName in @('btop-lhm', 'btop-lh')) {
        if (-not (Get-Alias -Name $aliasName -ErrorAction SilentlyContinue)) {
            Set-Alias -Name $aliasName -Value btop -Scope Global
        }
    }
}

# Starship prompt for PowerShell (cmd.exe uses the same config through Clink).
# Skip when the prompt is already Starship, so sourcing this file twice in one
# session does not stack initialisations.
$starshipPrompt = @(Get-Command prompt -CommandType Function -ErrorAction SilentlyContinue) |
    Select-Object -First 1
if ((Get-Command starship -ErrorAction SilentlyContinue) -and
    (-not $starshipPrompt -or $starshipPrompt.Source -ne 'starship')) {
    Invoke-Expression (& { (starship init powershell | Out-String) })
}

# skoop-cleanup: short command for the shutdown backup. Uploads everything,
# verifies it, then clears local sign-ins. -BackupOnly uploads without wiping.
function skoop-cleanup {
    param([switch]$BackupOnly)
    $roots = @()
    if ($env:SKOOP_REPO) { $roots += $env:SKOOP_REPO }
    $roots += (Join-Path $env:USERPROFILE 'repos\skoopub')
    $roots += (Join-Path $env:LOCALAPPDATA 'skoop')
    $cleanup = $null
    foreach ($root in $roots) {
        $candidate = Join-Path $root 'core\cleanup-before-shutdown.ps1'
        if (Test-Path -LiteralPath $candidate) { $cleanup = $candidate; break }
    }
    if (-not $cleanup) {
        Write-Host 'skoop-cleanup: skoopub not found; set $env:SKOOP_REPO' -ForegroundColor Red
        return
    }
    $user = $env:SKOOP_BACKUP_USER
    if (-not $user) {
        $userFile = Join-Path $env:LOCALAPPDATA 'skoop\backup-user'
        if (Test-Path -LiteralPath $userFile) { $user = (Get-Content -Raw -LiteralPath $userFile).Trim() }
    }
    $cleanupArgs = @()
    if ($user) { $cleanupArgs += @('-User', $user) }
    if ($BackupOnly) { $cleanupArgs += '-BackupOnly' }
    & $cleanup @cleanupArgs
}
