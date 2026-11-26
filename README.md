# skoop

Declarative Windows dev setup: [Scoop](https://scoop.sh) packages plus a repo-managed
PowerShell profile, restored from a single manifest.

- `scoop.json` — buckets + apps (`scoop export` format, replayed with `scoop import`), including the personal `kbots` bucket
- `profile.ps1` — shell config (`zoxide` + `atuin` history search, Starship prompt), dot-sourced from your `$PROFILE`; also drops inherited `HERDR_*` variables so a fresh shell is not mistaken for a nested Herdr pane
- `install.ps1` — one-shot bootstrap for a fresh machine
- `firefox-policies.template.json` — Firefox policy for extensions, managed bookmarks, homepage, and password saving
- `fix-sharex-printscreen.ps1` — hands the PrtSc key back to ShareX
- `setup-gh-auth.ps1` — asks you to log in with `gh auth login` if needed, then makes `git push` use that login
- `setup-git-identity.ps1` — sets the git author to **Keios <git@taquangkhoi.com>** globally (or locally with `-Local`)
- `zed/` + `configure-zed.ps1` — repo-managed Zed settings/keymap/tasks, copied to `%APPDATA%\Zed` on install
- `setup-herdr-ssh.ps1` — pick a tailnet machine and save it in Herdr (`herdr machine add`) over Tailscale SSH (one prompt, no keys stored)
- `enable-vicinae-autostart.ps1` — starts the Vicinae server at login (and now); scrubs inherited `HERDR_*` variables
- `vicinae/` + `configure-vicinae.ps1` — sets Vicinae's global shortcut to **Ctrl+Space** via a config import
- `rio/` + `configure-rio.ps1` — repo-managed Rio config (font size / zoom **16**), copied to `%LOCALAPPDATA%\rio\config.toml` on install
- `komorebi/whkdrc`, `komorebi/komorebi.json`, `komorebi/pin-terminal-layout.ps1` + `configure-komorebi.ps1` — tiling hotkeys, tight window padding, workspace rules and a watcher that keeps Rio left / Firefox right, deployed to `~/.config` and started on install
- `yasb/` + `configure-yasb.ps1` — Komorebi status bar (`config.yaml`, `styles.css`, `.env.example`) from the Ultimate-Win11-Setup repo, deployed to `~/.config/yasb` on install
- `profile.ps1` + `setup-nushell.ps1` — `n` opens Nushell in PowerShell, and a cmd AutoRun doskey macro makes `n` work in new cmd windows too
- `starship/` + `configure-starship.ps1` — Catppuccin Mocha Starship prompt for **PowerShell** and **cmd**: config copied to `~/.config/starship.toml`, and cmd loads it through Clink (`%LOCALAPPDATA%\clink\starship.lua` + `clink autorun install`)

## Install with one command

`.\install.ps1 --help` (or `-Help`) prints the CLI options without changing anything. If gum only prints the prompt but cannot draw its TUI in your terminal, add `-NoGum` (or set `$env:SKOOP_NO_GUM=1`) to use the numbered list instead.

`install.ps1` is an interactive CLI: with **gum** (`charm-gum`) installed you get a menu — *Full setup + connect Herdr*, *Configure only (skip Herdr)*, *Connect Herdr only*, or *Quit*. Without gum it falls back to a numbered prompt; pass `-NoMenu` (or `$env:SKOOP_NO_MENU=1`) to skip it entirely.

Run this in PowerShell (no admin required):

```powershell
irm https://raw.githubusercontent.com/KeiosStarqua/skoopub/main/install.ps1 | iex
```

If the execution policy blocks `iex`, wrap it in a bypassed process:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/KeiosStarqua/skoopub/main/install.ps1 | iex"
```

### One command to configure and connect Herdr

From a clone, `install.ps1` is the single entry point — it configures the machine **and**, after Tailscale starts, asks you to pick a tailnet machine and saves it in Herdr over Tailscale SSH:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

Pass the machine/user up front to skip all prompts (values are supplied at runtime, never committed):

```powershell
.\install.ps1 -HerdrPeer              # interactive gum picker for the machine
.\install.ps1 -Peer <machine-or-ip> -HerdrUser <user> -SkipGhLogin
```

Use `-SkipHerdrConnect` if you only want the machine configured. The piped form accepts the same options through environment variables:

```powershell
$env:SKOOP_HERDR_PEER = '<machine-or-ip>'
$env:SKOOP_HERDR_USER = '<user>'      # optional; auto-detected otherwise
irm https://raw.githubusercontent.com/KeiosStarqua/skoopub/main/install.ps1 | iex
```

Without any of these, both forms prompt you to pick a machine from `tailscale status` and then add it to Herdr.

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
5. Installs **Firefox** first, then **WezTerm**, then **Herdr** (adds the `extras` bucket if needed). Firefox is made the default browser and `firefox-policies.template.json` is copied into Firefox's `distribution` folder. On the next start it installs Bitwarden, mymind and "I still don't care about cookies", shows the bookmarks toolbar, adds a **skoopub** bookmark folder (Hacker News, mymind, Scoop, OpenCode, YouTube to Transcript), and opens ChatGPT as the homepage. On Windows 11, confirm the default-browser change in Settings if it opens there.
6. Runs `scoop import scoop.json` — adds the `main` / `extras` / `nerd-fonts` / `zeldrisho` / `lemon` / `kbots` buckets and every listed app, including **JetBrainsMono-NF** for Rio and the Herdr TUI, **cava** for the YASB audio visualizer (`lemon` is used because Scoop's `extras` bucket has no cava manifest), and **kbots** from the personal bucket (`KeiosStarqua/kbots`; it builds from a pinned source tag using the `bun` / `rustup` / `mingw` already in this manifest). If UniKey is already installed (common on public PCs), that one app is skipped so you do not end up with two IMEs; pass `-ForceUniKey` to install the Scoop copy anyway.
7. Starts **Tailscale**: enables/starts the Windows service if it exists, otherwise launches the Scoop `tailscaled` binary. Sign in from the Tailscale tray icon or with `tailscale up`. If the CLI is missing or cannot reach the daemon, the installer says so and still leaves Tailscale running — the CLI is only needed to list machines.
8. Offers the **Herdr remote setup** (`setup-herdr-ssh.ps1`): it lists your tailnet machines and asks you to choose one (the only prompt). It then finds an SSH user Tailscale SSH permits by probing a few candidates derived from your git identity/Windows user — no password and no generated keys — and runs `herdr machine add <user>@<machine> --label <machine>`, which prepares the remote server and saves the profile so it appears in the sidebar of every open Herdr client (re-runs leave an existing profile alone). If `tailscale status --json` cannot be used on Windows, it says why and asks for the machine's Tailscale IP or MagicDNS name; `-Peer <ip|name>` skips the listing, and `-User <name>` skips user probing. Requires Tailscale SSH (`tailscale set --ssh=true`) on the target machine and a matching tailnet SSH policy. Skips itself when there are no tailnet machines or the shell is not interactive. No machine name or IP is committed to this repo.
9. Sets the default Rust toolchain to `stable-x86_64-pc-windows-gnu` if none is configured (no Visual Studio Build Tools needed). The check tolerates a fresh `rustup`'s stderr so it cannot abort the bootstrap.
10. Disables Windows' "Print screen opens Snipping Tool" so **ShareX** can bind PrtSc. A failure here is reported but does not abort the setup.
11. Checks GitHub CLI auth. If you are not logged in, it asks whether to run `gh auth login` for you (HTTPS, no SSH key prompt), then runs `gh auth setup-git` so `git push` uses your gh token instead of prompting for a username. Pass `-SkipGhLogin` to skip the interactive prompt on unattended runs.
12. Sets the global git author identity to **Keios <git@taquangkhoi.com>** via `setup-git-identity.ps1`, so commits are attributed correctly in every repository. Use `-Local` to apply it only to the current repo; re-running is safe.
13. Copies `zed/settings.json`, `zed/keymap.json` and `zed/tasks.json` into `%APPDATA%\Zed` via `configure-zed.ps1` (existing files are backed up first). Zed installs the declared extensions on its first start: **PowerShell**, HTML, Dockerfile, Docker Compose, TOML, Nix and SQL. PowerShell support needs `pwsh` (added to `scoop.json`); Rust is supported natively in Zed via `rust-analyzer`, so there is no Rust extension to install.
14. Copies `rio/config.toml` into `%LOCALAPPDATA%\rio\config.toml` via `configure-rio.ps1` (a changed original is backed up first). It sets Rio's font size — its zoom level — to **16**; Rio hot-reloads the config, so new windows use it immediately.
15. Creates a per-user Startup shortcut for `vicinae-server.exe` via `enable-vicinae-autostart.ps1` and starts the server in the current session. Vicinae's global shortcut needs the server running, so it now works after every sign-in. The script clears inherited `HERDR_*` variables first, so terminals opened from Vicinae do not think they are inside a Herdr pane. Use `-Remove` to undo the autostart, `-NoLaunch` to only install the shortcut, or `-Restart` to relaunch an already running (contaminated) server.
16. Sets the Vicinae global shortcut to **Ctrl+Space** via `configure-vicinae.ps1`: it copies `vicinae/keybinds.json` into `%LOCALAPPDATA%\vicinae\config` and adds it to `settings.json`'s `imports`, so GUI changes never overwrite it. Existing settings are backed up before editing. Restart Vicinae (or sign in again) to register the shortcut; `.\configure-vicinae.ps1 -Restart` does that now.
17. Deploys `komorebi/whkdrc` and `komorebi/komorebi.json` to `~/.config` via `configure-komorebi.ps1` (changed originals are backed up first), then starts Komorebi with that config (or reapplies it to a running instance) and starts/reloads `whkd`. The config sets **4px workspace padding and 2px container padding** so adjacent windows sit close together (down from Komorebi's 10px defaults), plus named workspaces with **initial-workspace rules** (assign on first appearance; you can still move windows manually): `Win+1` Terminal (Rio, WezTerm, Firefox), `Win+2` Development (Zed, VS Code, Pear Desktop / YouTube Music), `Win+3` Browser (Chrome), `Win+4` Communication (Discord, Telegram), `Win+5` Files (Explorer), `Win+6` Media (Spotify, VLC), and `Win+7..9` spare. Workspace 1 uses the **Columns** layout; `pin-terminal-layout.ps1` runs in the background (and starts at login) to keep **Rio on the left and Firefox on the right** whenever either window opens. The hotkey scheme uses `Win` as the primary modifier: `Win+←/↓/↑/→` focus, `Win+Shift+←/↓/↑/→` move, `Win+Ctrl+←/↓/↑/→` resize, `Win+1..9` switch workspace, and `Win+Shift+1..9` move a window to a workspace. Arrows replace H/J/K/L because Windows 11 reserves `Win+H/J/K/L`; some remaining `Win` combos (e.g. `Win+Q`, `Win+F`, `Win+Space`) are native Windows shortcuts, and Snap may need disabling for `Win+Arrow` to reach whkd. See `komorebi/whkdrc` for the full list.
18. Deploys the YASB status bar from `yasb/` via `configure-yasb.ps1`: `config.yaml` and `styles.css` go to `~/.config/yasb` (changed originals are backed up), and a `.env` is created from `.env.example` if missing. YASB starts automatically; it watches the config, so edits reload without a restart (`.\configure-yasb.ps1 -Restart` forces one). Fill `~/.config/yasb/.env` with a WeatherAPI key/location and optional wallpaper directory to enable those widgets. In-app updates are off so Scoop stays the version source. Source config: https://github.com/SleepyCatHey/Ultimate-Win11-Setup/tree/main/Komorebi/YASB%20config%20for%20Komorebi.
19. Adds an `n` alias for Nushell in `profile.ps1` (PowerShell) and a cmd.exe AutoRun doskey macro via `setup-nushell.ps1`, so typing `n` opens Nushell from either shell. Existing cmd AutoRun entries are preserved; run `.\setup-nushell.ps1 -Remove` to undo.
20. Deploys the **Starship** prompt via `configure-starship.ps1`: `starship/starship.toml` (Catppuccin Mocha, directory/git/time/status modules) goes to `~/.config/starship.toml`, and `profile.ps1` initialises Starship for PowerShell. For cmd.exe it writes `%LOCALAPPDATA%\clink\starship.lua` and runs `clink autorun install` (Clink is in `scoop.json`), which appends to the existing AutoRun entry so the Nushell macro survives. Use `-NoCmd` to skip cmd, `-NoAutorun` to leave the registry alone, or `-NoBackup` to overwrite without a `.bak`.

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

Re-apply the Komorebi hotkeys, padding or workspace rules after editing `komorebi/whkdrc` or `komorebi/komorebi.json` (add `-RestartPin` to relaunch the Rio/Firefox layout watcher, or `-NoPin` to skip it):

```powershell
.\configure-komorebi.ps1 -Restart
```

Re-apply the YASB bar after editing `yasb/config.yaml` or `yasb/styles.css`:

```powershell
.\configure-yasb.ps1 -Restart
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
| Piped via `irm \| iex` | `scoop.json`, `profile.ps1`, `firefox-policies.template.json`, `fix-sharex-printscreen.ps1`, `setup-gh-auth.ps1`, `setup-git-identity.ps1`, `configure-zed.ps1`, `setup-herdr-ssh.ps1`, `enable-vicinae-autostart.ps1`, `configure-vicinae.ps1`, `configure-rio.ps1`, `configure-komorebi.ps1`, `configure-yasb.ps1`, `setup-nushell.ps1`, `configure-starship.ps1`, `vicinae/keybinds.json`, `rio/config.toml`, `komorebi/whkdrc`, `komorebi/komorebi.json`, `komorebi/pin-terminal-layout.ps1`, `starship/starship.toml`, `yasb/config.yaml`, `yasb/styles.css`, `yasb/.env.example` and `zed/*.json` are fetched to `%LOCALAPPDATA%\skoop` |
| Task Manager disabled by policy | `DisableTaskMgr` is set to `0` for the current user; elevated runs also clear the machine-wide value. A domain policy may reapply it on the next refresh |
| From a clone | The files next to `install.ps1` are used, so edits apply directly |
| Firefox default browser | `firefox --setDefaultBrowser` runs after install (skipped if Firefox is already the http handler); Windows 11 may open Settings for confirmation, and a failure is non-fatal |
| Firefox extensions | Bitwarden, mymind and "I still don't care about cookies" use `normal_installed` policies, so they install automatically but can still be disabled or removed. Bitwarden and "I still don't care about cookies" update from AMO; mymind is pinned to the 2.0.2 XPI URL, so bump that URL when a newer version ships. Restart Firefox once after setup; check `about:policies` |
| Firefox bookmarks / homepage | Managed bookmarks are locked by policy under a **skoopub** folder (Hacker News, mymind, Scoop, OpenCode, YouTube to Transcript); the toolbar is shown on startup and the homepage/startup page is ChatGPT. Edit `firefox-policies.template.json` to change them |
| Firefox saving passwords | `OfferToSaveLogins` and `OfferToSaveLoginsDefault` are both `false`, so Firefox never offers to save logins — Bitwarden handles passwords instead |
| Tailscale | The installer starts the `Tailscale` service (and sets it to Automatic) when present, otherwise launches the Scoop `tailscaled` shim. Sign in from the tray icon or with `tailscale up`; the Scoop package does not install the Windows service by itself. On Windows the CLI may not be on PATH (the official installer does not add it) or may be unable to reach the daemon — Tailscale itself still works, and the scripts handle that case |
| Herdr remote over Tailscale SSH | Run `.\setup-herdr-ssh.ps1` after signing in to Tailscale: pick a machine from the `tailscale status` list with an interactive **gum picker** (arrow keys / filter; falls back to a numbered list), or pass `-Peer <ip|name>` to skip the picker, and it saves the machine with `herdr machine add` using an auto-detected SSH user (`-User` overrides). The machine then shows up in the sidebar of your running Herdr clients, where you can also `herdr machine disable` / `enable` / `remove` it. The target must have Tailscale SSH enabled (`tailscale set --ssh=true`) and allow your login in the tailnet SSH policy. No keys, passwords, machine names or tailnet IPs are stored in the repo |
| `git push` asks for a username | Being logged in to `gh` is not enough: git also needs `gh auth setup-git`. `setup-gh-auth.ps1` does both; re-run it any time, or use `-SkipGhLogin` for unattended runs |
| Git author identity | `setup-git-identity.ps1` sets `user.name` / `user.email` globally to **Keios <git@taquangkhoi.com>**. Override with `-Name` / `-Email`, or pass `-Local` to change only the current repo |
| UniKey preinstalled | Detected via process, uninstall registry and Scoop dir; the existing copy is kept unless `-ForceUniKey` is passed |
| Zed config | `configure-zed.ps1` copies `zed/*.json` to `%APPDATA%\Zed` and backs up changed originals as `.bak.<timestamp>`; use `-NoBackup` to overwrite directly, or `-ConfigDir` to target another folder |
| Zed extensions | Zed installs `auto_install_extensions` when it starts, so launch it once after setup; the PowerShell extension uses `pwsh` from Scoop, and Rust language support is built in (`rust-analyzer`) rather than an extension |
| Vicinae autostart | `enable-vicinae-autostart.ps1` creates `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Vicinae.lnk` pointing at the Scoop `vicinae-server.exe` (via `current`, so updates do not break it) and starts the server now. Global shortcuts need that server; `-Remove` deletes the shortcut, `-NoLaunch` skips starting it |
| Vicinae shortcut | The global toggle is **Ctrl+Space**, set through an imported `keybinds.json` so the settings GUI cannot overwrite it. Change it in `vicinae/keybinds.json` and re-run `.\configure-vicinae.ps1 -Restart`; Vicinae must be restarted for a new global shortcut to register |
| Komorebi hotkeys / padding / workspace rules | `configure-komorebi.ps1` copies `komorebi/whkdrc` and `komorebi/komorebi.json` to `~/.config`, backs up changed originals as `.bak.<timestamp>`, starts Komorebi with the config (or reapplies it when already running) and starts/reloads `whkd`. The JSON sets `default_workspace_padding: 4` and `default_container_padding: 2`, plus named workspaces with `initial_workspace_rules`: Firefox and Rio on `Win+1`, Zed/VS Code/Pear Desktop on `Win+2`, etc. Rules only apply when an app first appears, so existing windows keep their current workspace; edit the JSON and rerun the script to change gaps or assignments. Workspace 1 uses `Columns`, and `komorebi/pin-terminal-layout.ps1` is deployed to `~/.config/komorebi-pin.ps1`, started hidden and added to Startup to keep Rio left / Firefox right (it reorders only those two when needed; `-NoPin` opts out, `-RestartPin` relaunches it). Use `-NoBackup` to overwrite directly and `-NoStart` to only deploy the files; `-Restart` forces a whkd reload. The config needs `komorebi` and `whkd` from `scoop.json`; the `Win` modifier overlaps some Windows 11 shortcuts and Snap layouts, so disable Snap if `Win+Arrow` does not reach whkd |
| YASB status bar | `configure-yasb.ps1` copies `yasb/config.yaml` and `yasb/styles.css` to `~/.config/yasb`, backs up changed originals, creates a `.env` from `.env.example` when missing, and starts YASB. The vendored config comes from SleepyCatHey/Ultimate-Win11-Setup; weather needs a WeatherAPI key in `.env`, and the cava widget uses the `cava` package from the `lemon` bucket (listed in `scoop.json`). YASB's in-app update is disabled so Scoop owns the version |
| Nushell shortcut | `profile.ps1` defines `n` → `nu` when Nushell is installed and no `n` alias already exists. `setup-nushell.ps1` writes `%LOCALAPPDATA%\skoop\nu-autostart.cmd` (a `doskey n=nu` macro) and appends it to HKCU `Command Processor\AutoRun` without replacing other entries; `-Remove` undoes it. Note this is an alias, not a shell replacement — PowerShell/cmd still start normally |
| Starship prompt | `configure-starship.ps1` copies `starship/starship.toml` to `~/.config/starship.toml` and `profile.ps1` runs `starship init powershell`, so new PowerShell windows get the prompt. cmd.exe needs **Clink** (in `scoop.json`): the script installs `%LOCALAPPDATA%\clink\starship.lua` and runs `clink autorun install`, which appends to the existing AutoRun value instead of replacing it. Use `-NoCmd` to leave cmd alone, `-NoAutorun` to skip the registry edit, `-NoBackup` to overwrite without a `.bak`. Both loaders skip cleanly when `starship` is not installed |
| Rio config | `configure-rio.ps1` copies `rio/config.toml` to `%LOCALAPPDATA%\rio\config.toml`, backing up a changed original as `.bak.<timestamp>` unless `-NoBackup`. Font size (zoom) is **16**; Rio hot-reloads the file, so no restart is needed |
| gum picker falls back to the numbered list | gum draws its UI on **stderr** and only writes the answer to stdout, so capturing it with `2>&1` left it without a terminal and it returned nothing. The pickers now send stderr straight to the console and read the answer from a temp file, so `gum choose` renders in Rio, WezTerm, Windows Terminal and Herdr. If a terminal still cannot draw it, pass `-NoGum` or set `$env:SKOOP_NO_GUM=1` |
| `herdr` says "nested herdr"/inception | A long-lived launcher (often Vicinae) inherited `HERDR_ENV=1` from a Herdr pane and passes it to new terminals. Run `.\enable-vicinae-autostart.ps1 -Restart`, then close and reopen Rio/WezTerm. `profile.ps1` already clears the variables for new PowerShell sessions. `setup-herdr-ssh.ps1` uses `herdr machine add`, so it does not start a nested client at all |
| Rust toolchain | GNU is set as default only when no toolchain is active; switch with `rustup default stable-x86_64-pc-windows-msvc` (needs MSVC Build Tools) |
| `z` / `atuin` not found | The profile hook is missing or points at a missing `profile.ps1`, or the window predates the install. Check `Get-Content $PROFILE`; re-run `install.ps1` to rewrite it, then open a new PowerShell window |
| kbots daemon | The Scoop package installs the `kbots`, `kb`, `kbots-tui` and `kbots-gui` shims but deliberately does not start the daemon; run `kbots daemon start`, then `kb status`. The daemon binds authenticated TCP on `127.0.0.1:7878` |

Requires Windows 10/11 (or Server 2016+) with PowerShell 5.1+ and internet access.
