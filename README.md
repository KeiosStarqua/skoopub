# skoop

Declarative Windows dev setup: [Scoop](https://scoop.sh) packages plus a repo-managed
PowerShell profile, restored from a single manifest.

- `scoop.json` — buckets + apps (`scoop export` format, replayed with `scoop import`)
- `profile.ps1` — shell config (`zoxide` + `atuin` history search), dot-sourced from your `$PROFILE`; also drops inherited `HERDR_*` variables so a fresh shell is not mistaken for a nested Herdr pane
- `install.ps1` — one-shot bootstrap for a fresh machine
- `firefox-policies.template.json` — Firefox policy for extensions, managed bookmarks, homepage, and password saving
- `fix-sharex-printscreen.ps1` — hands the PrtSc key back to ShareX
- `setup-gh-auth.ps1` — asks you to log in with `gh auth login` if needed, then makes `git push` use that login
- `zed/` + `configure-zed.ps1` — repo-managed Zed settings/keymap/tasks, copied to `%APPDATA%\Zed` on install
- `setup-herdr-ssh.ps1` — temporary SSH key + Herdr remote for a tailnet machine; asks which machine to use
- `enable-vicinae-autostart.ps1` — starts the Vicinae server at login (and now); scrubs inherited `HERDR_*` variables
- `vicinae/` + `configure-vicinae.ps1` — sets Vicinae's global shortcut to **Ctrl+Space** via a config import
- `rio/` + `configure-rio.ps1` — repo-managed Rio config (font size / zoom **16**), copied to `%LOCALAPPDATA%\rio\config.toml` on install

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
5. Installs **Firefox** first, then **WezTerm**, then **Herdr** (adds the `extras` bucket if needed). Firefox is made the default browser and `firefox-policies.template.json` is copied into Firefox's `distribution` folder. On the next start it installs Bitwarden, mymind and "I still don't care about cookies", shows the bookmarks toolbar, adds a **skoopub** bookmark folder (Hacker News, mymind, Scoop, OpenCode), and opens ChatGPT as the homepage. On Windows 11, confirm the default-browser change in Settings if it opens there.
6. Runs `scoop import scoop.json` — adds the `main` / `extras` / `nerd-fonts` / `zeldrisho` buckets and every listed app, including **JetBrainsMono-NF** for Rio and the Herdr TUI. If UniKey is already installed (common on public PCs), that one app is skipped so you do not end up with two IMEs; pass `-ForceUniKey` to install the Scoop copy anyway.
7. Starts **Tailscale**: enables/starts the Windows service if it exists, otherwise launches the Scoop `tailscaled` binary. Run `tailscale up` yourself afterwards to sign in.
8. Offers the **temporary Herdr SSH setup** (`setup-herdr-ssh.ps1`): it lists your tailnet machines and asks which one has Herdr inside, asks for the SSH user, creates a throwaway key pair under `%TEMP%`, and runs `ssh` to add the public key to that machine's `authorized_keys` (you type the password when SSH asks). It then writes a marked `Host <alias>` block to `~/.ssh/config` and runs `herdr machine add <alias>`. Skips itself when there are no tailnet machines or the shell is not interactive.
9. Sets the default Rust toolchain to `stable-x86_64-pc-windows-gnu` if none is configured (no Visual Studio Build Tools needed). The check tolerates a fresh `rustup`'s stderr so it cannot abort the bootstrap.
10. Disables Windows' "Print screen opens Snipping Tool" so **ShareX** can bind PrtSc. A failure here is reported but does not abort the setup.
11. Checks GitHub CLI auth. If you are not logged in, it asks whether to run `gh auth login` for you (HTTPS, no SSH key prompt), then runs `gh auth setup-git` so `git push` uses your gh token instead of prompting for a username. Pass `-SkipGhLogin` to skip the interactive prompt on unattended runs.
12. Copies `zed/settings.json`, `zed/keymap.json` and `zed/tasks.json` into `%APPDATA%\Zed` via `configure-zed.ps1` (existing files are backed up first). Zed installs the declared extensions on its first start: **PowerShell**, HTML, Dockerfile, Docker Compose, TOML, Nix and SQL. PowerShell support needs `pwsh` (added to `scoop.json`); Rust is supported natively in Zed via `rust-analyzer`, so there is no Rust extension to install.
13. Copies `rio/config.toml` into `%LOCALAPPDATA%\rio\config.toml` via `configure-rio.ps1` (a changed original is backed up first). It sets Rio's font size — its zoom level — to **16**; Rio hot-reloads the config, so new windows use it immediately.
14. Creates a per-user Startup shortcut for `vicinae-server.exe` via `enable-vicinae-autostart.ps1` and starts the server in the current session. Vicinae's global shortcut needs the server running, so it now works after every sign-in. The script clears inherited `HERDR_*` variables first, so terminals opened from Vicinae do not think they are inside a Herdr pane. Use `-Remove` to undo the autostart, `-NoLaunch` to only install the shortcut, or `-Restart` to relaunch an already running (contaminated) server.
15. Sets the Vicinae global shortcut to **Ctrl+Space** via `configure-vicinae.ps1`: it copies `vicinae/keybinds.json` into `%LOCALAPPDATA%\vicinae\config` and adds it to `settings.json`'s `imports`, so GUI changes never overwrite it. Existing settings are backed up before editing. Restart Vicinae (or sign in again) to register the shortcut; `.\configure-vicinae.ps1 -Restart` does that now.

Then open a new PowerShell window and try:

```powershell
z ..
```

## Updating this machine later

```powershell
scoop import .\scoop.json
```

Re-apply the editor config after editing `zed/`:

```powershell
.\configure-zed.ps1
```

Re-apply the Rio config after editing `rio/config.toml`:

```powershell
.\configure-rio.ps1
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
| Piped via `irm \| iex` | `scoop.json`, `profile.ps1`, `firefox-policies.template.json`, `fix-sharex-printscreen.ps1`, `setup-gh-auth.ps1`, `configure-zed.ps1`, `setup-herdr-ssh.ps1`, `enable-vicinae-autostart.ps1`, `configure-vicinae.ps1`, `configure-rio.ps1`, `vicinae/keybinds.json`, `rio/config.toml` and `zed/*.json` are fetched to `%LOCALAPPDATA%\skoop` |
| Task Manager disabled by policy | `DisableTaskMgr` is set to `0` for the current user; elevated runs also clear the machine-wide value. A domain policy may reapply it on the next refresh |
| From a clone | The files next to `install.ps1` are used, so edits apply directly |
| Firefox default browser | `firefox --setDefaultBrowser` runs after install (skipped if Firefox is already the http handler); Windows 11 may open Settings for confirmation, and a failure is non-fatal |
| Firefox extensions | Bitwarden, mymind and "I still don't care about cookies" use `normal_installed` policies, so they install automatically but can still be disabled or removed. Bitwarden and "I still don't care about cookies" update from AMO; mymind is pinned to the 2.0.2 XPI URL, so bump that URL when a newer version ships. Restart Firefox once after setup; check `about:policies` |
| Firefox bookmarks / homepage | Managed bookmarks are locked by policy under a **skoopub** folder (Hacker News, mymind, Scoop, OpenCode); the toolbar is shown on startup and the homepage/startup page is ChatGPT. Edit `firefox-policies.template.json` to change them |
| Firefox saving passwords | `OfferToSaveLogins` and `OfferToSaveLoginsDefault` are both `false`, so Firefox never offers to save logins — Bitwarden handles passwords instead |
| Tailscale | The installer starts the `Tailscale` service (and sets it to Automatic) when present, otherwise launches the Scoop `tailscaled` shim. Login still needs `tailscale up` in a terminal; the Scoop package does not install the Windows service by itself |
| Temporary Herdr SSH | Run `.\setup-herdr-ssh.ps1` after `tailscale up` on a public machine: choose a tailnet machine, type its SSH user and password, and a throwaway key in `%TEMP%` gets authorized remotely. The private key stays local; `-Revoke -Alias <alias>` removes the remote key, local key pair and SSH config block. Drop the saved machine with `herdr machine remove <id>` |
| `git push` asks for a username | Being logged in to `gh` is not enough: git also needs `gh auth setup-git`. `setup-gh-auth.ps1` does both; re-run it any time, or use `-SkipGhLogin` for unattended runs |
| UniKey preinstalled | Detected via process, uninstall registry and Scoop dir; the existing copy is kept unless `-ForceUniKey` is passed |
| Zed config | `configure-zed.ps1` copies `zed/*.json` to `%APPDATA%\Zed` and backs up changed originals as `.bak.<timestamp>`; use `-NoBackup` to overwrite directly, or `-ConfigDir` to target another folder |
| Zed extensions | Zed installs `auto_install_extensions` when it starts, so launch it once after setup; the PowerShell extension uses `pwsh` from Scoop, and Rust language support is built in (`rust-analyzer`) rather than an extension |
| Vicinae autostart | `enable-vicinae-autostart.ps1` creates `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Vicinae.lnk` pointing at the Scoop `vicinae-server.exe` (via `current`, so updates do not break it) and starts the server now. Global shortcuts need that server; `-Remove` deletes the shortcut, `-NoLaunch` skips starting it |
| Vicinae shortcut | The global toggle is **Ctrl+Space**, set through an imported `keybinds.json` so the settings GUI cannot overwrite it. Change it in `vicinae/keybinds.json` and re-run `.\configure-vicinae.ps1 -Restart`; Vicinae must be restarted for a new global shortcut to register |
| Rio config | `configure-rio.ps1` copies `rio/config.toml` to `%LOCALAPPDATA%\rio\config.toml`, backing up a changed original as `.bak.<timestamp>` unless `-NoBackup`. Font size (zoom) is **16**; Rio hot-reloads the file, so no restart is needed |
| `herdr` says "nested herdr"/inception | A long-lived launcher (often Vicinae) inherited `HERDR_ENV=1` from a Herdr pane and passes it to new terminals. Run `.\enable-vicinae-autostart.ps1 -Restart`, then close and reopen Rio/WezTerm. `profile.ps1` already clears the variables for new PowerShell sessions |
| Rust toolchain | GNU is set as default only when no toolchain is active; switch with `rustup default stable-x86_64-pc-windows-msvc` (needs MSVC Build Tools) |
| `z` / `atuin` not found | The profile hook is missing or points at a missing `profile.ps1`, or the window predates the install. Check `Get-Content $PROFILE`; re-run `install.ps1` to rewrite it, then open a new PowerShell window |

Requires Windows 10/11 (or Server 2016+) with PowerShell 5.1+ and internet access.
