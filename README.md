# skoop

Declarative Windows dev setup: [Scoop](https://scoop.sh) packages plus a repo-managed
PowerShell profile, restored from a single manifest.

- `scoop.json` — buckets + apps (`scoop export` format, replayed with `scoop import`)
- `profile.ps1` — shell config (`zoxide` + `atuin` history search), dot-sourced from your `$PROFILE`
- `install.ps1` — one-shot bootstrap for a fresh machine
- `fix-sharex-printscreen.ps1` — hands the PrtSc key back to ShareX

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
3. Runs `scoop import scoop.json` — adds the `main` / `extras` / `zeldrisho` buckets and every listed app. If UniKey is already installed (common on public PCs), that one app is skipped so you do not end up with two IMEs; pass `-ForceUniKey` to install the Scoop copy anyway.
4. Sets the default Rust toolchain to `stable-x86_64-pc-windows-gnu` if none is configured (no Visual Studio Build Tools needed).
5. Disables Windows' "Print screen opens Snipping Tool" so **ShareX** can bind PrtSc.
6. Wires `profile.ps1` into your `$PROFILE` (idempotent). An older hook pointing at a `profile.ps1` that no longer exists is rewritten, which is what silently breaks `z` after the repo moves.

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
| Piped via `irm \| iex` | `scoop.json`, `profile.ps1`, `fix-sharex-printscreen.ps1` are fetched to `%LOCALAPPDATA%\skoop` |
| From a clone | The files next to `install.ps1` are used, so edits apply directly |
| UniKey preinstalled | Detected via process, uninstall registry and Scoop dir; the existing copy is kept unless `-ForceUniKey` is passed |
| Rust toolchain | GNU is set as default only when no toolchain is active; switch with `rustup default stable-x86_64-pc-windows-msvc` (needs MSVC Build Tools) |
| `z` / `atuin` not found | The profile hook points at a missing `profile.ps1` or the window predates the install. Check `Get-Content $PROFILE`, then open a new PowerShell window |

Requires Windows 10/11 (or Server 2016+) with PowerShell 5.1+ and internet access.
