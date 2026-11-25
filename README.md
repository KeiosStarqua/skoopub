# skoop

Declarative Windows dev setup: [Scoop](https://scoop.sh) packages plus a repo-managed
PowerShell profile, restored from a single manifest.

- `scoop.json` — buckets + apps (`scoop export` format, replayed with `scoop import`)
- `profile.ps1` — shell config, dot-sourced from your `$PROFILE`
- `install.ps1` — one-shot bootstrap for a fresh machine

## Install with one command

Run this in PowerShell (no admin required):

```powershell
irm https://raw.githubusercontent.com/KeiosStarqua/skoopub/main/install.ps1 | iex
```

If the execution policy blocks `iex`, wrap it in a bypassed process:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/KeiosStarqua/skoopub/main/install.ps1 | iex"
```

### From a clone instead

```powershell
git clone https://github.com/KeiosStarqua/skoopub.git
cd skoop
.\install.ps1
```

## What the script does

1. Installs **Scoop** if it is missing.
2. Ensures **git** is available (Scoop buckets are git repos).
3. Runs `scoop import scoop.json` — adds the `main` / `extras` buckets and every listed app.
4. Appends a dot-source line for `profile.ps1` to your `$PROFILE` (idempotent).

Then open a new PowerShell window and try:

```powershell
z ..
```

## Updating this machine later

```powershell
scoop import .\scoop.json
```

…or add a package and re-export to commit:

```powershell
scoop install <app>
scoop export | Out-File -Encoding utf8 scoop.json
```

## Notes

| Situation | Behavior |
|---|---|
| Normal (non-elevated) shell | Scoop installs per-user under `%USERPROFILE%\scoop` |
| Elevated shell | Scoop installs system-wide under `C:\ProgramData\scoop` |
| Piped via `irm \| iex` | `scoop.json` / `profile.ps1` are fetched to `%LOCALAPPDATA%\skoop` |
| From a clone | The files next to `install.ps1` are used, so edits apply directly |

Requires Windows 10/11 (or Server 2016+) with PowerShell 5.1+ and internet access.
