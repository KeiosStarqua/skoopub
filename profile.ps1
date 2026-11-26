# skoop shell config
# Dot-sourced from $PROFILE, so the setup lives in this repo and is versioned.
# Keep this file idempotent: it runs every time a PowerShell session starts.

# Herdr marks its panes with HERDR_ENV=1. A terminal launched from a Herdr
# pane (Alacritty, WezTerm, etc.) inherits those variables, so a fresh shell
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
    # and its markers are genuine. A terminal (Alacritty, WezTerm, Windows
    # Terminal, cmd, Explorer) that was itself launched from a Herdr pane passes
    # the same variables on; drop them for shells started inside such a terminal.
    $self = Get-CimInstance Win32_Process -Filter "ProcessId = $PID" -ErrorAction SilentlyContinue
    $parentName = ''
    if ($self) {
        $parent = Get-CimInstance Win32_Process -Filter "ProcessId = $($self.ParentProcessId)" -ErrorAction SilentlyContinue
        if ($parent) { $parentName = $parent.Name }
    }
    if ($parentName -match '^(alacritty|wezterm-gui|wezterm|WindowsTerminal|wt|cmd|conhost|explorer)\.exe$') {
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
