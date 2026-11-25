# skoop shell config
# Dot-sourced from $PROFILE, so the setup lives in this repo and is versioned.
# Keep this file idempotent: it runs every time a PowerShell session starts.

# zoxide: smarter `cd` — `z <query>`, `z ..`, `z -`
if (Get-Command zoxide -ErrorAction SilentlyContinue) {
    Invoke-Expression (& { (zoxide init powershell | Out-String) })
}
