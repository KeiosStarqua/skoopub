# skoop shell config
# Dot-sourced from $PROFILE, so the setup lives in this repo and is versioned.
# Keep this file idempotent: it runs every time a PowerShell session starts.

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
