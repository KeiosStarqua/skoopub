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

1. Wires `profile.ps1` into your `$PROFILE` (idempotent) **before anything that can fail**, so `z`/`atuin` are configured even if a later step breaks. An older hook pointing at a `profile.ps1` that no longer exists is rewritten, which is what silently breaks `z` after the repo moves.
2. Enables **Task Manager** by setting `DisableTaskMgr=0` for the current user; when run elevated, the machine-wide policy is cleared as well. A locked key is reported but does not abort setup.
3. Installs **Scoop** if it is missing.
4. Ensures **git** is available (Scoop buckets are git repos).
5. Installs **Firefox** before **WezTerm** (adds the `extras` bucket if needed), so the browser and terminal are available early. Firefox is also asked to become the default browser; on Windows 11, confirm in Settings if it opens there.
6. Runs `scoop import scoop.json` — adds the `main` / `extras` / `zeldrisho` buckets and every listed app. If UniKey is already installed (common on public PCs), that one app is skipped so you do not end up with two IMEs; pass `-ForceUniKey` to install the Scoop copy anyway.
7. Sets the default Rust toolchain to `stable-x86_64-pc-windows-gnu` if none is configured (no Visual Studio Build Tools needed).
8. Disables Windows' "Print screen opens Snipping Tool" so **ShareX** can bind PrtSc. A failure here is reported but does not abort the setup.

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
| Task Manager disabled by policy | `DisableTaskMgr` is set to `0` for the current user; elevated runs also clear the machine-wide value. A domain policy may reapply it on the next refresh |
| From a clone | The files next to `install.ps1` are used, so edits apply directly |
| Firefox default browser | `firefox --setDefaultBrowser` runs after install (skipped if Firefox is already the http handler); Windows 11 may open Settings for confirmation, and a failure is non-fatal |
| UniKey preinstalled | Detected via process, uninstall registry and Scoop dir; the existing copy is kept unless `-ForceUniKey` is passed |
| Rust toolchain | GNU is set as default only when no toolchain is active; switch with `rustup default stable-x86_64-pc-windows-msvc` (needs MSVC Build Tools) |
| `z` / `atuin` not found | The profile hook is missing or points at a missing `profile.ps1`, or the window predates the install. Check `Get-Content $PROFILE`; re-run `install.ps1` to rewrite it, then open a new PowerShell window |

Requires Windows 10/11 (or Server 2016+) with PowerShell 5.1+ and internet access.
