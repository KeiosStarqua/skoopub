# skoop

Declarative Windows dev setup: [Scoop](https://scoop.sh) packages plus a repo-managed
PowerShell profile, restored from a single manifest.

- `manifests/scoop.json` — buckets + apps (`scoop export` format; the single source of truth for versions)
- `manifests/phases.json` — ordered install phases: phase 1 is the fast essentials (git, PowerShell 7, Rio **first**, then Herdr, Vicinae, Tailscale), the heavy apps come last
- `core/scoop-phases.ps1` — validates the phase mapping and replays each phase as its own temporary `scoop import`
- `core/set-dark-mode.ps1` — checks the Windows theme and turns on Dark Mode (apps + system) for the current user; a no-op when it is already dark
- `shell/profile.ps1` — shell config (`zoxide` + `atuin` history search, Starship prompt), dot-sourced from your `$PROFILE`; aliases `btop-lhm` / `btop-lh` to `btop` and drops inherited `HERDR_*` variables so a fresh shell is not mistaken for a nested Herdr pane
- `install.ps1` — one-shot bootstrap for a fresh machine (phased install, `-EssentialsOnly` for just the terminal/launcher); re-runs skip Scoop apps that are already installed (`-ForceInstall` re-imports them). Creates `~/repos` and clones skoopub there, then opens Rio in that folder with Herdr running (`-NoAutoHerdr` opts out). Restores Firefox/Atuin from the backup once Tailscale connects and retries at the end (`-ForceFirefoxRestore` / `-ForceAtuinRestore` repeat, `-SkipFirefoxRestore` / `-SkipAtuinRestore` skip). `-NoWallpapers` skips the one-time wallpaper collection clone
- `apps/firefox/policies.template.json` — Firefox policy for extensions, homepage, and password saving
- `apps/sharex/fix-printscreen.ps1` — hands the PrtSc key back to ShareX (checks first; re-runs are a no-op)
- `apps/unikey/` + `apps/unikey/configure.ps1` — installs/auto-configures UniKey with **Unicode + VNI**, Vietnamese typing on, no startup dialog and a Startup shortcut; `unikey.reg` is the sanitized baseline and `-Export` / `-Restore` back up settings
- `apps/github/setup-auth.ps1` — asks you to log in with `gh auth login` if needed, then makes `git push` use that login
- `apps/git/setup-identity.ps1` — sets the git author to **Keios <git@taquangkhoi.com>** globally (or locally with `-Local`)
- `apps/zed/` + `apps/zed/configure.ps1` — repo-managed Zed settings/keymap/tasks, copied to `%APPDATA%\Zed` on install
- `apps/herdr/setup-ssh.ps1` — pick a tailnet machine and save it in Herdr (`herdr machine add`) over Tailscale SSH (one prompt, no keys stored)
- `apps/tailscale/configure.ps1` — tag this device `tag:public-client` in the tailnet and, with `-RestoreVicinae` / `-RestorePearDesktop` / `-RestoreFirefox` / `-RestoreAtuin` / `-RestoreOpenCode`, restore Vicinae, Pear Desktop, Firefox, Atuin or OpenCode from the backup once connected (idempotent, non-fatal)
- `apps/vicinae/enable-autostart.ps1` — starts the Vicinae server at login (and now); scrubs inherited `HERDR_*` variables
- `apps/vicinae/` + `apps/vicinae/configure.ps1` — sets Vicinae's global shortcut to **Ctrl+Space** via a config import
- `apps/rio/` + `apps/rio/configure.ps1` — repo-managed Rio config (font size / zoom **16**), copied to `%LOCALAPPDATA%\rio\config.toml` on install
- `apps/komorebi/whkdrc`, `apps/komorebi/komorebi.json`, `apps/komorebi/pin-terminal-layout.ps1`, `apps/komorebi/set-taskbar-autohide.ps1` + `apps/komorebi/configure.ps1` — tiling hotkeys, tight window padding, workspace rules, a watcher that keeps Rio left / Firefox right, and taskbar auto-hide, deployed to `~/.config` and started on install
- `apps/yasb/` + `apps/yasb/configure.ps1` — YASB status bar setup: downloads the chosen theme from the community catalog (default **dots windows**) into `~/.config/yasb` on install, plus `.env.example`; no theme files are committed. `apps/yasb/setup-wallpapers.ps1` shallow-clones D3Ext/aesthetic-wallpapers and sets `YASB_WALLPAPER_DIR` for the Alt+E gallery
- `shell/profile.ps1` + `apps/nushell/setup.ps1` — `n` opens Nushell in PowerShell, and a cmd AutoRun doskey macro makes `n` work in new cmd windows too
- `apps/starship/` + `apps/starship/configure.ps1` — Catppuccin Mocha Starship prompt for **PowerShell** and **cmd**: config copied to `~/.config/starship.toml`, and cmd loads it through Clink (`%LOCALAPPDATA%\clink\starship.lua` + `clink autorun install`)
- `core/cleanup-before-shutdown.ps1` + `core/install-shutdown-hook.ps1` — shutdown/logoff backup of Firefox, Vicinae, Atuin, Pear Desktop and OpenCode to `acer-ubuntu`, then clears local sign-ins: GitHub, SSH keys, **Tailscale**, **Pear Desktop**, **OpenCode** and Firefox logins
- `core/restore-backup.ps1` — restores the latest Firefox, Vicinae, Atuin, Pear Desktop, OpenCode and/or SSH-key snapshot from `acer-ubuntu` onto a fresh machine; Tailscale also calls it for Vicinae, Pear Desktop, Firefox and Atuin after connecting, OpenCode and the SSH key at the end of the install (`-SkipSshRestore` opts out)
- `apps/mouse/` + `.github/workflows/mouse-release.yml` — Rust `skoopub-mouse` wheel diagnostics (HID Raw Input vs `WM_MOUSEWHEEL`) and Logitech HID++ hardware-DPI control via `hidapi-rs`, built on `mouse-v*` tags; `configure.ps1` downloads the release exe and `mouse.ps1` is the CLI
- `apps/librescoll/configure.ps1` — installs and starts **LibreScroll** (inertial middle-button scrolling) from the latest GitHub release: SHA-256 digest verified, extracted to `%LOCALAPPDATA%\skoop\librescoll`, Startup shortcut written; `install.ps1` runs it on every setup

## Install with one command

`.\install.ps1 --help` (or `-Help`) prints the CLI options without changing anything. If gum only prints the prompt but cannot draw its TUI in your terminal, add `-NoGum` (or set `$env:SKOOP_NO_GUM=1`) to use the numbered list instead.

A bare `.\install.ps1` runs the **full setup** straight away — there is no startup menu and no option to choose. Pass `-Menu` (or `$env:SKOOP_MENU=1`) to open the optional selector: *Full setup + connect Herdr*, *Essentials only*, *Configure only*, *Connect Herdr only*, or *Quit*. It uses **gum** when available and falls back to a numbered prompt. `-NoMenu` is still accepted as a no-op for older scripts; `$env:SKOOP_NO_MENU=1` suppresses the menu even with `-Menu`.

The install is **phased** so the useful parts land first. Phase 1 (`core-terminal`) installs git, **PowerShell 7**, **Rio first**, then **Herdr** / `herdr-core`, **Vicinae**, the JetBrains Mono Nerd Fonts (regular + proportional `NFP` for YASB icons) and **Tailscale**. It starts Tailscale and runs `tailscale up --qr` so you can sign in (URL/QR in the terminal) before anything else downloads. Once connected it restores Vicinae, Pear Desktop, Firefox and Atuin from the shutdown backup (once per machine) **before** applying the Rio config, the Vicinae Ctrl+Space shortcut/autostart and checking the Herdr TUI — so the restored database/config is in place first and the repo-managed keybinds win. Finally it opens **Rio in `~/repos` with Herdr running**. Firefox and Atuin are installed in later phases, so this early restore only lays down their files (no CLI dependency, unlike OpenCode) and is retried at the end of the install; marker files make the retry a no-op. Pass `-NoAutoHerdr` (or `$env:SKOOP_NO_AUTO_HERDR=1`) to skip that launch. Phase 2 adds the CLI shell tools, phase 3 the editors/toolchains and phase 4 the heavy apps (Firefox, Blender, …). A failure in a later phase is reported and skipped instead of aborting the run. `-EssentialsOnly` stops after phase 1; run the script again to continue.

When **pwsh** (PowerShell 7) is already installed, `install.ps1` re-launches itself under it with the same options — Windows PowerShell 5.1 mangles native stderr (gum's TUI) and reads BOM-less UTF-8 as ANSI. If pwsh is not there yet, it starts phase 1 under 5.1 and re-launches under 7 as soon as phase 1 installs it. Pass `-NoPwsh` (or `$env:SKOOP_NO_PWSH=1`) to stay on 5.1; a piped `irm … | iex` run cannot re-launch and stays in the evaluating shell.

Run this in PowerShell (no admin required):

```powershell
irm https://raw.githubusercontent.com/KeiosStarqua/skoopub/main/install.ps1 | iex
```

If the execution policy blocks `iex`, wrap it in a bypassed process:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/KeiosStarqua/skoopub/main/install.ps1 | iex"
```

The installer sets the **CurrentUser execution policy to `RemoteSigned`** early on, so the dot-sourced profile loads in every new PowerShell shell (including Rio) instead of failing with *"running scripts is disabled on this system"*. The bypass above is only needed for the very first piped run; an already-permissive policy is left alone. As a regression guard, the installer then opens a fresh shell and checks that the managed profile really loaded — if it did not, you get an error naming `Get-ExecutionPolicy -List` and your `$PROFILE`.

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

1. Wires `shell/profile.ps1` into **both** PowerShell profiles — Windows PowerShell 5.1 (`Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1`) and PowerShell 7+ (`Documents\PowerShell\Microsoft.PowerShell_profile.ps1`) — **before anything that can fail**, so `z`/`atuin`/Starship/`n` work in either edition even if a later step breaks. An older hook pointing at a `profile.ps1` that no longer exists (for example the old repo-root path from before the file moved into `shell/`) is rewritten, which is what silently breaks `z` after the repo moves.
2. Enables **Task Manager** by setting `DisableTaskMgr=0` for the current user; when run elevated, the machine-wide policy is cleared as well. A locked key is reported but does not abort setup.
3. Installs **Scoop** if it is missing.
4. Ensures **git** is available (Scoop buckets are git repos), then creates `~/repos` and clones skoopub into `~/repos\skoopub` when missing. An existing folder or checkout is never overwritten; a piped run keeps using its downloaded files for that session.
5. Installs `manifests/scoop.json` in the **ordered phases** declared by `manifests/phases.json` (each phase is replayed as its own temporary `scoop import`, so it only clones the buckets it needs):
   - **core-terminal** — `pwsh`, **Rio first**, then `herdr` / `herdr-core`, Vicinae, **JetBrainsMono-NF** + **JetBrainsMono-NF-Propo** (the fast essentials; the proportional NFP family is what YASB theme CSS uses for icons) and Tailscale.
   - **shell** — the CLI tools (7zip, gum, Nushell, zoxide, atuin, Starship, Clink, delta, ripgrep, fd, bat, fzf, jq, less, btop-lhm, mise, uv, gh, opencode, cursor-cli).
   - **editors** — VS Code, Zed, lazygit, rustup, mingw and bun.
   - **apps** — Firefox, ShareX, grok-bot, Pear Desktop, ChatGPT, Blender, YASB, Komorebi/whkd, cava, **Ollama**, UniKey and kbots.
   Phase 1 failures abort; a failure in a later phase is reported and skipped so a slow download cannot take the essentials down. UniKey is dropped from the apps phase when an existing copy is found (common on public PCs); pass `-ForceUniKey` to install the Scoop copy anyway. Once the apps phase has installed Firefox, `apps/firefox/policies.template.json` is copied into its `distribution` folder and Firefox is asked to become the default browser (Windows 11 may ask you to confirm). On the next start the policy installs Bitwarden, mymind and "I still don't care about cookies", shows the bookmarks toolbar, and opens ChatGPT as the homepage.
5a. Configures **UniKey** via `apps/unikey/configure.ps1`: it reuses an existing copy (or installs the Scoop build with `-ForceUniKey`), stops it, imports the machine-independent `apps/unikey/unikey.reg` baseline (`HKCU\SOFTWARE\PkLong\UniKey` for 4.6 RC2 — older builds used `HKCU\Software\UniKey`), enforces Unicode output + **VNI** input + Vietnamese typing on + no startup dialog, adds `UniKey.lnk` to your Startup folder and starts it. Use `-InputMethod Telex` for Telex, `-Export` to back up the DWORD settings to `%LOCALAPPDATA%\skoop\unikey\backups`, and `-Restore [-Path <file>]` to restore them. No GUI is needed and no machine-specific paths are stored in the repo.
6. Finishes the phase-1 apps **before phase 2 starts**: starts Tailscale and runs `tailscale up --qr` so you can sign in (the login URL and QR code are printed) before Firefox and the other heavy apps. Once `tailscale status --json` confirms the node is connected, `apps/tailscale/configure.ps1 -RestoreVicinae -RestorePearDesktop -RestoreFirefox -RestoreAtuin` restores Vicinae (`core/restore-backup.ps1 -Only vicinae`), Pear Desktop's signed-in userData (`-Only pear`), the Firefox profile (`-Only firefox`) and Atuin config/history (`-Only atuin`) from the latest `acer-ubuntu` snapshot (once per machine, markers at `%LOCALAPPDATA%\skoop\vicinae-restore-on-connect.done`, `pear-restore-on-connect.done`, `firefox-restore.done` and `atuin-restore.done`; supply `-BackupUser` / `SKOOP_BACKUP_USER` for unattended runs). **This happens before Vicinae is configured or launched**, so its restored database/config is in place and the managed keybinds are applied on top. It then copies `apps/rio/config.toml` into `%LOCALAPPDATA%\rio\config.toml` (font size / zoom **16**, hot-reloaded), sets the Vicinae global shortcut to **Ctrl+Space** via `apps/vicinae/configure.ps1`, creates the Vicinae Startup shortcut and starts the server via `apps/vicinae/enable-autostart.ps1`, and confirms `herdr` is on PATH. Firefox and Atuin are installed in later phases, so this only lays down files (no CLI dependency); Firefox is closed/relaunched around the copy and Atuin warns you to close other shells. Both are retried at the end of the install; `-ForceFirefoxRestore` / `-ForceAtuinRestore` repeat one and `-SkipFirefoxRestore` / `-SkipAtuinRestore` opt out. Pear's cookies are DPAPI-encrypted, so a different Windows user or machine may still ask for a Google sign-in. Finally it opens **Rio in `~/repos` with Herdr running** (`-NoAutoHerdr` opts out). It then re-launches the rest of the run under **PowerShell 7** (phase 1 just installed it) unless `-NoPwsh` is set. `-EssentialsOnly` stops here.
7. Starts **Tailscale** again as a safety net: enables/starts the Windows service if it exists, otherwise launches the Scoop `tailscaled` binary. Sign in from the Tailscale tray icon or with `tailscale up --qr` if phase 1 could not. If the CLI is missing or cannot reach the daemon, the installer says so and still leaves Tailscale running — the CLI is only needed to list machines. `apps/tailscale/configure.ps1` then advertises **tag:public-client** on this device when signed in; re-runs skip a tag that is already advertised.
8. Offers the **Herdr remote setup** (`apps/herdr/setup-ssh.ps1`): it lists your tailnet machines and asks you to choose one (the only prompt). It then finds an SSH user Tailscale SSH permits by probing a few candidates derived from your git identity/Windows user — no password and no generated keys — and runs `herdr machine add <user>@<machine> --label <machine>`, which prepares the remote server and saves the profile so it appears in the sidebar of every open Herdr client (re-runs leave an existing profile alone). If `tailscale status --json` cannot be used on Windows, it says why and asks for the machine's Tailscale IP or MagicDNS name; `-Peer <ip|name>` skips the listing, and `-User <name>` skips user probing. Requires Tailscale SSH (`tailscale set --ssh=true`) on the target machine and a matching tailnet SSH policy. Skips itself when there are no tailnet machines or the shell is not interactive. No machine name or IP is committed to this repo.
9. Sets the default Rust toolchain to `stable-x86_64-pc-windows-gnu` if none is configured (no Visual Studio Build Tools needed). The check tolerates a fresh `rustup`'s stderr so it cannot abort the bootstrap.
10. Checks the PrtSc state and disables Windows' "Print screen opens Snipping Tool" only if needed, so **ShareX** can bind PrtSc. Already-applied fixes are left alone — no registry rewrite and no ShareX restart — and `-Force` is the explicit opt-in to re-apply. A failure here is reported but does not abort the setup.
11. Checks GitHub CLI auth. If you are not logged in, it asks whether to run `gh auth login` for you (HTTPS, no SSH key prompt), then runs `gh auth setup-git` so `git push` uses your gh token instead of prompting for a username. Pass `-SkipGhLogin` to skip the interactive prompt on unattended runs.
12. Sets the global git author identity to **Keios <git@taquangkhoi.com>** via `apps/git/setup-identity.ps1`, so commits are attributed correctly in every repository. Use `-Local` to apply it only to the current repo; re-running is safe.
13. Copies `apps/zed/settings.json`, `apps/zed/keymap.json` and `apps/zed/tasks.json` into `%APPDATA%\Zed` via `apps/zed/configure.ps1` (existing files are backed up first). Zed installs the declared extensions on its first start: **PowerShell**, HTML, Dockerfile, Docker Compose, TOML, Nix and SQL. PowerShell support needs `pwsh` (added to `manifests/scoop.json`); Rust is supported natively in Zed via `rust-analyzer`, so there is no Rust extension to install.
14. Deploys `apps/komorebi/whkdrc` and `apps/komorebi/komorebi.json` to `~/.config` via `apps/komorebi/configure.ps1` (changed originals are backed up first), then starts Komorebi with that config (or reapplies it to a running instance) and starts/reloads `whkd`. The config sets **4px workspace padding and 2px container padding** so adjacent windows sit close together (down from Komorebi's 10px defaults), and drops the border width from Komorebi's 8px default to **3px** (`border_width`). It also enables **hover-to-focus** (`"focus_follows_mouse": "Komorebi"`) so the window under the cursor becomes active without a click, and turns off the opposing cursor jump (`"mouse_follows_focus": false`). The managed-windows-only implementation is used because native Windows X-Mouse also focuses YASB's popup windows, making popups disappear as soon as the cursor moved onto them; it requires `komorebi.exe --ffm`, which `configure.ps1` now passes (`komorebic start` has no `--ffm` flag). Upstream marks this option end-of-life in favour of the separate `masir` tool (not on Scoop), so a deprecation warning is printed. Remove the line to return to click-to-focus. Plus named workspaces with **initial-workspace rules** (assign on first appearance; you can still move windows manually): `Win+1` Terminal (Rio, WezTerm, Firefox), `Win+2` Development (Zed, VS Code, Pear Desktop / YouTube Music, YASB Themes), `Win+3` Browser (Chrome), `Win+4` Communication (Discord, Telegram), `Win+5` Files (Explorer), `Win+6` Media (Spotify, VLC), and `Win+7..9` spare. Workspace 1 uses the **Columns** layout; `pin-terminal-layout.ps1` runs in the background (and starts at login) to keep **Rio on the left and Firefox on the right** whenever either window opens. The hotkey scheme uses `Win` as the primary modifier: `Win+←/↓/↑/→` focus, `Win+Shift+←/↓/↑/→` move, `Win+Ctrl+←/↓/↑/→` resize, `Win+1..9` switch workspace, and `Win+Shift+1..9` move a window to a workspace. Arrows replace H/J/K/L because Windows 11 reserves `Win+H/J/K/L`; some remaining `Win` combos (e.g. `Win+Q`, `Win+F`, `Win+Space`) are native Windows shortcuts, and Snap may need disabling for `Win+Arrow` to reach whkd. See `apps/komorebi/whkdrc` for the full list. Once Komorebi is up, `apps/komorebi/configure.ps1` also sets the Windows taskbar to auto-hide (via `apps/komorebi/set-taskbar-autohide.ps1`, restarting Explorer once so it applies immediately); with YASB as the visible bar this gives tiling windows the full screen. It is idempotent, runs last so it does not interrupt Komorebi/whkd startup, and `-NoTaskbarAutohide` opts out. Run `.\apps\komorebi\set-taskbar-autohide.ps1 -Disable` to restore the always-on-top taskbar.
15. Deploys the YASB status bar via `apps/yasb/configure.ps1`. **No theme files are committed to this repo** — the community catalog has ~70 themes and YASB's Themes Manager (`yasb_themes.exe`, tray → *Get Themes*) can install any of them. On a fresh install the script downloads the default **dots windows** theme (id `d513044f-9218-46e1-ab62-c15705b80341`) from https://github.com/amnweb/yasb-themes, patches its wallpaper paths to `$env:YASB_WALLPAPER_DIR` and turns `update_check` off (Scoop owns the version), then writes `config.yaml` + `styles.css` to `~/.config/yasb` with backups of changed originals; a `.env` is created from `.env.example` if missing. Pick another catalog theme with `.\apps\yasb\configure.ps1 -ThemeId <id> -Restart` or `$env:SKOOP_YASB_THEME_ID=<id>` (ids are listed at https://yasb.dev/themes); theme IDs are validated as `a-zA-Z0-9_-`. YASB starts automatically and watches its config, so edits reload without a restart. `apps/yasb/setup-wallpapers.ps1` then shallow-clones https://github.com/D3Ext/aesthetic-wallpapers into `%LOCALAPPDATA%\skoop\wallpapers\aesthetic-wallpapers` (once, ~645 MB) and points `YASB_WALLPAPER_DIR` at its `images` folder, so `Alt+E` shows the full gallery; re-run with `-Update` to pull new wallpapers, or pass `-NoWallpapers` to install.ps1 / configure.ps1 (or set `$env:SKOOP_NO_WALLPAPERS=1`) to skip it. Failures are non-fatal (offline installs keep the existing theme). dots windows is the end-4 Hyprland-inspired bar (Power Menu, Active Window, CPU/Memory/Traffic, Media, Taskbar, Clock, Weather, Language, Notifications, WiFi/Bluetooth) and uses `Rubik Light` for text. Broken icons are a font problem: `configure.ps1` reads the fetched stylesheet, installs missing font families via `scoop install` (`JetBrainsMono NFP` comes from `JetBrainsMono-NF-Propo`, already in phase 1), downloads `Rubik Light` from the upstream `google/fonts` OFL file per-user, and on Windows 10 auto-installs **Segoe Fluent Icons** per-user from Microsoft's official `https://aka.ms/SegoeFluentIcons` ZIP (EULA included; the TTF is never committed), then restarts YASB so glyphs load. `Segoe UI Variable` is Windows 11-only and falls back to `Segoe UI`.

15a. Clears wallpaper-change restrictions and sets a desktop wallpaper: it zeroes `NoChangingWallPaper` under `HKCU\...\Policies\ActiveDesktop` and `NoDispBackgroundPage` under `HKCU\...\Policies\System`, removes any forced `Wallpaper`/`WallpaperStyle`/`TileWallpaper` policy, and repeats those writes machine-wide when the shell is elevated. It then picks a random image from the cloned `aesthetic-wallpapers/images` folder (or `-Wallpaper <path>` / `$env:SKOOP_WALLPAPER`) and applies it with `SystemParametersInfo(SPI_SETDESKWALLPAPER)` in **Fill** mode, persisting the path under `HKCU\Control Panel\Desktop`. `-NoWallpaper` / `$env:SKOOP_NO_WALLPAPER=1` skips both the policy clearing and the wallpaper change; failures are non-fatal.
16. Adds an `n` alias for Nushell in `shell/profile.ps1` (PowerShell) and a cmd.exe AutoRun doskey macro via `apps/nushell/setup.ps1`, so typing `n` opens Nushell from either shell. Existing cmd AutoRun entries are preserved; run `.\apps\nushell\setup.ps1 -Remove` to undo.
17. Deploys the **Starship** prompt via `apps/starship/configure.ps1`: `apps/starship/starship.toml` (Catppuccin Mocha, directory/git/time/status modules) goes to `~/.config/starship.toml`, and `shell/profile.ps1` initialises Starship for PowerShell. For cmd.exe it writes `%LOCALAPPDATA%\clink\starship.lua` and runs `clink autorun install` (Clink is in `manifests/scoop.json`), which appends to the existing AutoRun entry so the Nushell macro survives. Use `-NoCmd` to skip cmd, `-NoAutorun` to leave the registry alone, or `-NoBackup` to overwrite without a `.bak`.
18. Checks the Windows theme via `core/set-dark-mode.ps1` and turns on **Dark Mode** for both apps and the system (`AppsUseLightTheme=0`, `SystemUsesLightTheme=0` in HKCU). Re-runs are a no-op when dark mode is already on, and a theme-change notification tells running apps to reload.
18a. Restores **OpenCode** config/state and sign-in from the latest `acer-ubuntu` snapshot at the end of the install (the CLI installed by the app phases is needed for `opencode auth import`; marker `%LOCALAPPDATA%\skoop\opencode-restore.done`, `-ForceOpenCodeRestore` repeats it). Non-fatal and skipped when Tailscale is not connected.
18b. Restores the **Firefox** profile and **Atuin** config/history from the latest `acer-ubuntu` snapshot as soon as Tailscale is connected/up in phase 1 (`-RestoreFirefox -RestoreAtuin`), then retries idempotently at the end of the install. Both apps are installed in later phases, but this restore only copies files, so unlike OpenCode it needs no CLI; Firefox is closed and relaunched around the copy, and Atuin warns you to close other Atuin shells. Markers `%LOCALAPPDATA%\skoop\firefox-restore.done` / `atuin-restore.done` make re-runs a no-op; `-ForceFirefoxRestore` / `-ForceAtuinRestore` repeat one, `-SkipFirefoxRestore` / `-SkipAtuinRestore` opt out (env equivalents `SKOOP_FORCE_FIREFOX_RESTORE`, `SKOOP_FORCE_ATUIN_RESTORE`, `SKOOP_NO_FIREFOX_RESTORE`, `SKOOP_NO_ATUIN_RESTORE`). Requires Tailscale connected and `-BackupUser` / `SKOOP_BACKUP_USER`; failures are non-fatal.
19. Registers the per-user scheduled task `SkoopCleanupOnShutdown` via `core/install-shutdown-hook.ps1`. On shutdown/logoff it backs up Firefox profiles, Vicinae's config/data/state, Atuin's config + data (`%USERPROFILE%\.atuin`), Pear Desktop's signed-in userData (`%APPDATA%\YouTube Music`, cache folders skipped) and OpenCode's config/state plus an `opencode auth export` credential dump to `acer-ubuntu`, verifies each upload, and only then clears local sign-ins: GitHub CLI/git/Credential Manager, SSH keys, the **Tailscale login** (`tailscale logout`), **Pear Desktop / YouTube Music** user data, **OpenCode** credentials and Firefox `logins.json` / `key4.db`. Pear Desktop is stopped for the copy so its cookie database is included. Pass `-BackupUser` (or `$env:SKOOP_BACKUP_USER`) for the SSH user, or `-SkipShutdownHook` to opt out. `.\core\cleanup-before-shutdown.ps1 -DryRun` previews without changing anything; `-BackupOnly` uploads without removing anything; `-NoPear` / `-NoOpenCode` leave those apps untouched (no snapshot, no sign-out).
20. Installs and starts **LibreScroll** via `apps/librescoll/configure.ps1` on every run: the latest GitHub release zip is checked against the API's SHA-256 digest, extracted under `%LOCALAPPDATA%\skoop\librescoll`, a per-user Startup shortcut is created and the tray app is launched. Hold the **middle mouse button** and drag to scroll with inertia; release to stop. LibreScroll blocks physical wheel events while active, so pause or quit it from the tray before running `apps/mouse/mouse.ps1 diagnose`. A failure is reported but does not abort the setup.

Then open a new PowerShell window and try:

```powershell
z ..
```

### Restoring Firefox / Vicinae / Atuin / Pear Desktop / OpenCode on a new public machine

Vicinae, Pear Desktop, Firefox and Atuin are restored automatically right after Tailscale connects/up during `install.ps1` (Firefox/Atuin are retried at the end of the run), and OpenCode is restored at the end of the install once its CLI exists. This happens once per machine — delete `%LOCALAPPDATA%\skoop\vicinae-restore-on-connect.done` / `pear-restore-on-connect.done` / `firefox-restore.done` / `atuin-restore.done` / `opencode-restore.done` or pass `-ForceVicinaeRestore` / `-ForcePearDesktopRestore` / `-ForceFirefoxRestore` / `-ForceAtuinRestore` / `-ForceOpenCodeRestore` to `apps/tailscale/configure.ps1` to repeat one. `install.ps1` accepts the Firefox/Atuin force switches directly (`-SkipFirefoxRestore` / `-SkipAtuinRestore` opt out) and needs Tailscale connected plus `-BackupUser` / `SKOOP_BACKUP_USER`; Firefox is closed and relaunched around the copy, and Atuin warns you to close other shells. You can always re-run any app yourself after installing:

```powershell
.\core\restore-backup.ps1 -User <ssh-user>
```

It picks the newest timestamp under `~/skoop-backups/firefox`, `~/skoop-backups/vicinae`, `~/skoop-backups/atuin`, `~/skoop-backups/pear` and `~/skoop-backups/opencode` on `acer-ubuntu` **independently per app**, downloads them with scp, then merges Firefox profiles into `%APPDATA%\Mozilla\Firefox`, Vicinae's `config` / `data` / `state` into `%LOCALAPPDATA%\vicinae`, Atuin's `config.toml` + `data` (history/records/meta databases and `key`) into `%USERPROFILE%\.atuin`, Pear Desktop's userData back under `%APPDATA%` (cache folders were not backed up), and OpenCode's `config` / `state` back under `~/.config/opencode` / `~/.local/state/opencode` followed by `opencode auth import` of the snapshot's `auth/export.json` (so integrations stay signed in; the CLI must be installed). Close Firefox before running it (its profile files are locked); a running `vicinae-server` is stopped for the copy and restarted afterwards, and a running Pear Desktop is stopped for its restore. Existing config/data is kept as `.bak.<timestamp>` unless you pass `-NoBackup`. Pear cookies are encrypted with Windows DPAPI, so under a different Windows user or on another machine Google may still ask you to sign in again. Stale `*.db-wal` / `*.db-shm` files are removed before the Atuin restore so a restored database is not mixed with local journal data; close other shells with Atuin sessions before using the restored history.

Useful switches: `-List` shows the latest stamp per app, `-Only firefox` / `-Only vicinae` / `-Only atuin` / `-Only pear` / `-Only opencode` restores one app, `-Stamp <timestamp>` pins all apps to one snapshot, `-DryRun` previews, and `-NoRestart` leaves a stopped Vicinae server stopped. `-User` defaults to `$env:SKOOP_BACKUP_USER`; `-TargetHost`, `-FirefoxRemotePath`, `-VicinaeRemotePath`, `-AtuinRemotePath`, `-PearRemotePath` and `-OpenCodeRemotePath` override the remote locations. If you changed the managed keybinds, run `.\apps\vicinae\configure.ps1 -Restart` after the restore. Nothing on the remote host is modified or deleted. The Atuin and OpenCode archives contain credentials, so protect the remote backups accordingly.

### Mouse wheel diagnostics (random inverted scrolling)

On shared PCs a wheel can report the right direction to HID but the wrong one to
applications. `skoopub-mouse` captures both streams at once (`Raw Input` and
`WM_MOUSEWHEEL`) and writes a JSON report so the fault can be attributed to the
device/driver or to a software hook (G HUB, cafe client, …):

```powershell
.\apps\mouse\mouse.ps1 diagnose -Seconds 30   # turn the wheel during the capture
.\apps\mouse\mouse.ps1 diagnose -Seconds 60 -Expect 'down@0-25,up@30-55' -Cues
.\apps\mouse\mouse.ps1 monitor                # stream events live
.\apps\mouse\mouse.ps1 status
.\apps\mouse\mouse.ps1 driver                 # read-only HID/USB driver report
.\apps\mouse\mouse.ps1 driver -Action filters # third-party mouse/HID/USB filters
.\apps\mouse\mouse.ps1 fix                    # opt-in: flip the sign when diagnosis is conclusive
.\apps\mouse\mouse.ps1 fix -DryRun            # observe without changing events
.\apps\mouse\mouse.ps1 restore                # stop the correction hook
.\apps\mouse\mouse.ps1 dpi                    # set Logitech mouse DPI to 1200
.\apps\mouse\mouse.ps1 dpi -Dpi 800 -DryRun   # inspect range without changing it
```

`fix` only enables correction when the report shows >= 5 inverted events and >=
60% mismatch; otherwise it prints why and leaves the input stream untouched.
Use `--force` to override. Full details and limits are in `apps/mouse/README.md`.
The executable is built by GitHub Actions on `mouse-v*` tags and downloaded from
the release - you do not need Rust installed locally (`-Build` exists for that).
`mouse.ps1 driver` is a separate read-only PowerShell inspection of the PnP
device, INF/version/service, parent chain, Mouse/HID/USB class filters,
Authenticode signatures and recent Kernel-PnP/USB events; it changes nothing.

`install.ps1` also installs and starts **LibreScroll** (inertial middle-button
scrolling). It deliberately blocks physical `WM_MOUSEWHEEL` events while active,
so pause it from its tray icon before running `diagnose`/`monitor`; otherwise the
report sees raw wheel data with almost no `WM_MOUSEWHEEL` counterpart.

## Updating this machine later

Re-run the installer; it checks the Scoop app directories first and leaves already-installed apps out of the generated phase manifests, so only missing packages are imported. The skipped names are printed under each phase, and a phase whose apps are all present is not imported at all:

```powershell
.\install.ps1
```

Pass `-ForceInstall` (alias `-Force`, or `$env:SKOOP_FORCE_INSTALL=1` for piped runs) to re-import the apps that are already there. This never overrides the deliberate UniKey skip — use `-ForceUniKey` for that.

Firefox and Atuin are restored only once per machine (markers `%LOCALAPPDATA%\skoop\firefox-restore.done` / `atuin-restore.done`); a plain re-run skips them. Pass `-ForceFirefoxRestore` / `-ForceAtuinRestore` (or `SKOOP_FORCE_FIREFOX_RESTORE=1` / `SKOOP_FORCE_ATUIN_RESTORE=1` for piped runs) to repeat one, or `-SkipFirefoxRestore` / `-SkipAtuinRestore` (or `SKOOP_NO_FIREFOX_RESTORE=1` / `SKOOP_NO_ATUIN_RESTORE=1`) to opt out. The restore needs a connected Tailscale node and `-BackupUser` / `SKOOP_BACKUP_USER`; Firefox is closed/relaunched around the copy, and Atuin warns you to close other shells.

A plain `scoop import .\manifests/scoop.json` still installs every app at once, but it ignores the phase order (and therefore the fast phase-1 path) and this skip check.

Re-apply the editor config after editing `apps/zed/`:

```powershell
.\apps\zed\configure.ps1
```

Re-apply the Rio config after editing `apps/rio/config.toml`:

```powershell
.\apps\rio\configure.ps1
```

Re-check and enforce Dark Mode after editing `core/set-dark-mode.ps1`:

```powershell
.\core\set-dark-mode.ps1
```

Re-apply the UniKey setup after editing `apps/unikey/unikey.reg` (or to switch the input method). `-Export` writes a sanitized `.reg` to `%LOCALAPPDATA%\skoop\unikey\backups`; `-Restore` imports that file or the newest backup:

```powershell
.\apps\unikey\configure.ps1
.\apps\unikey\configure.ps1 -InputMethod Telex
.\apps\unikey\configure.ps1 -Export
.\apps\unikey\configure.ps1 -Restore -Path "$env:LOCALAPPDATA\skoop\unikey\backups\unikey-<timestamp>.reg"
```

Re-apply the Komorebi hotkeys, padding or workspace rules after editing `apps/komorebi/whkdrc` or `apps/komorebi/komorebi.json` (add `-RestartPin` to relaunch the Rio/Firefox layout watcher, `-NoPin` to skip it, or `-NoTaskbarAutohide` to leave the taskbar alone):

```powershell
.\apps\komorebi\configure.ps1 -Restart
```

Re-apply the YASB bar after editing `apps/yasb/config.yaml` or `apps/yasb/styles.css` (add `-Theme komorebi` to restore the previously vendored Komorebi bar theme):

```powershell
.\apps\yasb\configure.ps1 -Restart
```

…or add a package and re-export to commit (then add its name to exactly one phase in `manifests/phases.json`; the installer throws if an app is unassigned):

```powershell
scoop install <app>
scoop export | Out-File -Encoding utf8 manifests/scoop.json
```

## Notes

| Situation | Behavior |
|---|---|
| Normal (non-elevated) shell | Scoop installs per-user under `%USERPROFILE%\scoop` |
| Elevated shell | Scoop installs system-wide under `C:\ProgramData\scoop` |
| Piped via `irm \| iex` | `manifests/scoop.json`, `manifests/phases.json`, `core/scoop-phases.ps1`, `core/set-dark-mode.ps1`, `core/restore-backup.ps1`, `shell/profile.ps1`, `apps/firefox/policies.template.json`, `apps/sharex/fix-printscreen.ps1`, `apps/github/setup-auth.ps1`, `apps/git/setup-identity.ps1`, `apps/zed/configure.ps1`, `apps/herdr/setup-ssh.ps1`, `apps/tailscale/configure.ps1`, `apps/vicinae/enable-autostart.ps1`, `apps/vicinae/configure.ps1`, `apps/rio/configure.ps1`, `apps/komorebi/configure.ps1`, `apps/yasb/configure.ps1`, `apps/yasb/setup-wallpapers.ps1`, `apps/nushell/setup.ps1`, `apps/mouse/configure.ps1`, `apps/mouse/mouse.ps1`, `apps/librescoll/configure.ps1`, `apps/starship/configure.ps1`, `apps/vicinae/keybinds.json`, `apps/rio/config.toml`, `apps/komorebi/whkdrc`, `apps/komorebi/komorebi.json`, `apps/komorebi/pin-terminal-layout.ps1`, `apps/komorebi/set-taskbar-autohide.ps1`, `apps/unikey/configure.ps1`, `apps/unikey/unikey.reg`, `apps/starship/starship.toml`, `apps/yasb/config.yaml`, `apps/yasb/styles.css`, `apps/yasb/.env.example` and `apps/zed/*.json` are fetched to `%LOCALAPPDATA%\skoop` |
| Windows theme / Dark Mode | `core/set-dark-mode.ps1` sets `AppsUseLightTheme=0` and `SystemUsesLightTheme=0` under HKCU `...\Themes\Personalize` only when they are not already dark, then broadcasts `ImmersiveColorSet`. No admin needed, and it never overrides an existing dark theme. Run `.\core\set-dark-mode.ps1` to re-apply |
| Task Manager disabled by policy | `DisableTaskMgr` is set to `0` for the current user; elevated runs also clear the machine-wide value. A domain policy may reapply it on the next refresh |
| From a clone | The files next to `install.ps1` are used, so edits apply directly |
| Local checkouts | Both bootstraps create `~/repos` and clone skoopub into `~/repos\skoopub` when missing (fork-friendly: the URL is derived from `-RepoRawBase`). Existing folders/checkouts are never overwritten; a failed clone only prints a warning |
| Firefox default browser | `firefox --setDefaultBrowser` runs after install (skipped if Firefox is already the http handler); Windows 11 may open Settings for confirmation, and a failure is non-fatal |
| Firefox version | Only Firefox is pinned: `manifests/scoop.json` uses `Source: <auto-generated>` with `Version: 161.0` and `Info: Held package`, so `scoop import` installs that exact version and holds it. Other apps still install latest. To upgrade, change `Version` and run `scoop unhold firefox` before importing |
| Firefox extensions | Bitwarden, mymind and "I still don't care about cookies" use `normal_installed` policies, so they install automatically but can still be disabled or removed. Bitwarden and "I still don't care about cookies" update from AMO; mymind is pinned to the 2.0.2 XPI URL, so bump that URL when a newer version ships. Restart Firefox once after setup; check `about:policies` |
| Firefox bookmarks / homepage | Bookmarks come from the restored Firefox profile — no bookmark folder is injected by policy. The toolbar is shown on startup and the homepage/startup page is ChatGPT. Edit `apps/firefox/policies.template.json` to change them |
| Firefox saving passwords | `OfferToSaveLogins` and `OfferToSaveLoginsDefault` are both `false`, so Firefox never offers to save logins — Bitwarden handles passwords instead |
| Backup / restore on a new machine | `core/cleanup-before-shutdown.ps1` uploads Firefox profiles to `~/skoop-backups/firefox/<timestamp>/firefox`, Vicinae `config`/`data`/`state` to `~/skoop-backups/vicinae/<timestamp>/vicinae`, Atuin `config` + `data` to `~/skoop-backups/atuin/<timestamp>/atuin`, Pear Desktop's signed-in userData (Chromium caches excluded) to `~/skoop-backups/pear/<timestamp>/pear` and OpenCode's `config`/`state` plus an `opencode auth export` dump to `~/skoop-backups/opencode/<timestamp>/opencode`. `core/restore-backup.ps1 -User <name>` takes the latest of each independently and merges them back (`-List`, `-Only firefox/vicinae/atuin/pear/opencode`, `-Stamp`, `-DryRun`, `-NoBackup`, `-NoRestart`); Vicinae, Pear Desktop, Firefox and Atuin are restored automatically after Tailscale connects (Firefox/Atuin are retried at the end of the run), and OpenCode at the end of the install, once per machine; markers `firefox-restore.done` / `atuin-restore.done` make repeats a no-op and `-ForceFirefoxRestore` / `-ForceAtuinRestore` repeat one. Close Firefox first for a manual restore; Vicinae is stopped/restarted around the copy and Pear Desktop is stopped for its restore. Pear cookies are DPAPI-encrypted, so another Windows user/machine may still ask for a Google sign-in. Atuin's `key`/history and OpenCode's exported credentials are in the archive, so protect it. `-NoVicinae` / `-NoAtuin` / `-NoPear` / `-NoOpenCode` on the backup script skip those snapshots (`-NoPear` / `-NoOpenCode` also skip the sign-out) |
| Tailscale | The installer starts the `Tailscale` service (and sets it to Automatic) when present, otherwise launches the Scoop `tailscaled` shim. Phase 1 runs `apps/tailscale/configure.ps1 -SignIn -RestoreVicinae -RestorePearDesktop -RestoreFirefox -RestoreAtuin`, which executes `tailscale up --qr` and prints the login URL/QR in the terminal; already-connected nodes skip the sign-in. Once connected, it restores Vicinae and Pear Desktop's signed-in userData plus the Firefox profile and Atuin config/history from the latest backups once and writes `%LOCALAPPDATA%\skoop\vicinae-restore-on-connect.done` / `pear-restore-on-connect.done` / `firefox-restore.done` / `atuin-restore.done`; `-ForceVicinaeRestore` / `-ForcePearDesktopRestore` / `-ForceFirefoxRestore` / `-ForceAtuinRestore` repeat one app and `-BackupUser` / `SKOOP_BACKUP_USER` supplies the SSH user for unattended runs. Firefox is closed/relaunched around the copy and Atuin warns you to close other shells; `install.ps1` also forwards `-SkipFirefoxRestore` / `-SkipAtuinRestore` (or `SKOOP_NO_FIREFOX_RESTORE=1` / `SKOOP_NO_ATUIN_RESTORE=1`) to opt out, and retries Firefox/Atuin at the end of the run (markers make both retries no-ops). OpenCode is restored later with `-RestoreOpenCode` once its CLI exists (marker `opencode-restore.done`). You can also sign in from the tray icon or run `tailscale up --qr` yourself. The Scoop package does not install the Windows service by itself. On Windows the CLI may not be on PATH (the official installer does not add it) or may be unable to reach the daemon - Tailscale itself still works, and the scripts handle that case |
| Tailnet tag | `apps/tailscale/configure.ps1` advertises `tag:public-client` on this device after Tailscale is connected. It is idempotent and non-fatal: if the tag is already advertised it does nothing, and if sign-in is missing it prints a hint. Your tailnet ACL must allow you to own that tag. Pass `-SkipTag` to the script to leave the tag alone |
| Herdr auto-launch | After the essentials phase (Rio is installed before Herdr), both bootstraps open `rio -w ~/repos -e pwsh -NoLogo -NoExit -Command herdr` so Herdr is ready in the new terminal. It is skipped for non-interactive shells, Herdr panes and `-NoAutoHerdr` / `SKOOP_NO_AUTO_HERDR=1`; all six `HERDR_*` markers are cleared before launch to avoid the nested-session error |
| Herdr remote over Tailscale SSH | Run `.\apps\herdr\setup-ssh.ps1` after signing in to Tailscale: pick a machine from the `tailscale status` list with an interactive **gum picker** (arrow keys / filter; falls back to a numbered list), or pass `-Peer <ip|name>` to skip the picker, and it saves the machine with `herdr machine add` using an auto-detected SSH user (`-User` overrides). The machine then shows up in the sidebar of your running Herdr clients, where you can also `herdr machine disable` / `enable` / `remove` it. The target must have Tailscale SSH enabled (`tailscale set --ssh=true`) and allow your login in the tailnet SSH policy. No keys, passwords, machine names or tailnet IPs are stored in the repo |
| `git push` asks for a username | Being logged in to `gh` is not enough: git also needs `gh auth setup-git`. `apps/github/setup-auth.ps1` does both; re-run it any time, or use `-SkipGhLogin` for unattended runs |
| Git author identity | `apps/git/setup-identity.ps1` sets `user.name` / `user.email` globally to **Keios <git@taquangkhoi.com>**. Override with `-Name` / `-Email`, or pass `-Local` to change only the current repo |
| UniKey preinstalled | Detected via process, uninstall registry and Scoop dir; the existing copy is kept unless `-ForceUniKey` is passed |
| UniKey config / backup | `apps/unikey/configure.ps1` writes `HKCU\SOFTWARE\PkLong\UniKey` (4.6 RC2): `CodeTable=0` (Unicode), `InputMethod=1` (VNI; `0` = Telex), `Vietnamese=1`, `ShowDlg=0`, `AutoUpdate=0`. It creates `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\UniKey.lnk` and starts UniKey; `-NoAutostart` / `-NoLaunch` opt out, `-RemoveAutostart` removes the shortcut. `-Export` writes a sanitized `.reg` to `%LOCALAPPDATA%\skoop\unikey\backups`; `-Restore [-Path <file>]` imports that or the repo baseline. An existing `HKCU\Software\UniKey` (older builds) is mirrored, never created from scratch |
| Zed config | `apps/zed/configure.ps1` copies `apps/zed/*.json` to `%APPDATA%\Zed` and backs up changed originals as `.bak.<timestamp>`; use `-NoBackup` to overwrite directly, or `-ConfigDir` to target another folder |
| Zed extensions | Zed installs `auto_install_extensions` when it starts, so launch it once after setup; the PowerShell extension uses `pwsh` from Scoop, and Rust language support is built in (`rust-analyzer`) rather than an extension |
| Vicinae autostart | `apps/vicinae/enable-autostart.ps1` creates `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Vicinae.lnk` pointing at the Scoop `vicinae-server.exe` (via `current`, so updates do not break it) and starts the server now. Global shortcuts need that server; `-Remove` deletes the shortcut, `-NoLaunch` skips starting it |
| Vicinae shortcut | The global toggle is **Ctrl+Space**, set through an imported `keybinds.json` so the settings GUI cannot overwrite it. Change it in `apps/vicinae/keybinds.json` and re-run `.\apps\vicinae\configure.ps1 -Restart`; Vicinae must be restarted for a new global shortcut to register |
| Komorebi hotkeys / padding / workspace rules | `apps/komorebi/configure.ps1` copies `apps/komorebi/whkdrc` and `apps/komorebi/komorebi.json` to `~/.config`, backs up changed originals as `.bak.<timestamp>`, starts `komorebi.exe` directly with `--ffm` and the config (or reapplies it when already running) and starts/reloads `whkd`. The JSON sets `default_workspace_padding: 4`, `default_container_padding: 2`, a slim `border_width: 3` (down from 8), `"focus_follows_mouse": "Komorebi"` (managed windows only, so YASB popups stay open; needs `--ffm`) and `"mouse_follows_focus": false` (drop the focus_follows_mouse line to disable hover-focus; upstream marks it end-of-life), plus named workspaces with `initial_workspace_rules`: Firefox and Rio on `Win+1`, Zed/VS Code/Pear Desktop / YASB Themes on `Win+2`, etc. Rules only apply when an app first appears, so existing windows keep their current workspace; edit the JSON and rerun the script to change gaps or assignments. Workspace 1 uses `Columns`, and `apps/komorebi/pin-terminal-layout.ps1` is deployed to `~/.config/komorebi-pin.ps1`, started hidden and added to Startup to keep Rio left / Firefox right (it reorders only those two when needed; `-NoPin` opts out, `-RestartPin` relaunches it). After Komorebi is started it also runs `apps/komorebi/set-taskbar-autohide.ps1`, which sets `HKCU\...\Explorer\StuckRects3\Settings` byte 8 to `0x03` and restarts Explorer once to hide the stock taskbar (YASB is the visible bar); it is idempotent, `-NoTaskbarAutohide` opts out, and running it with `-Disable` restores the always-on-top taskbar. Use `-NoBackup` to overwrite directly and `-NoStart` to only deploy the files; `-Restart` forces a whkd reload. The config needs `komorebi` and `whkd` from `manifests/scoop.json`; the `Win` modifier overlaps some Windows 11 shortcuts and Snap layouts, so disable Snap if `Win+Arrow` does not reach whkd |
| YASB status bar | `apps/yasb/configure.ps1` downloads the selected theme's `config.yaml` + `styles.css` from the community catalog into `~/.config/yasb` (default **dots windows**, `-ThemeId <id>` or `SKOOP_YASB_THEME_ID` picks another), patches wallpaper paths to `$env:YASB_WALLPAPER_DIR` and `update_check` off, backs up changed originals, creates a `.env` from `.env.example` when missing, auto-installs missing theme fonts (Nerd Font via Scoop, `Rubik Light` from google/fonts, Segoe Fluent Icons from Microsoft on Windows 10) and starts YASB. `apps/yasb/setup-wallpapers.ps1` shallow-clones D3Ext/aesthetic-wallpapers into `%LOCALAPPDATA%\skoop\wallpapers\aesthetic-wallpapers` (once, `-Update` pulls new ones) and writes `YASB_WALLPAPER_DIR` in `.env`; `-NoWallpapers` / `SKOOP_NO_WALLPAPERS=1` skips it and failures are non-fatal. YASB's in-app update is disabled so Scoop owns the version |
| Desktop wallpaper | `install.ps1` clears wallpaper-change policies (`NoChangingWallPaper` in `HKCU\...\Policies\ActiveDesktop`, `NoDispBackgroundPage` and forced `Wallpaper`/`WallpaperStyle`/`TileWallpaper` in `HKCU\...\Policies\System`, plus the HKLM equivalents when elevated) and applies a random image from the cloned collection with `SystemParametersInfo(SPI_SETDESKWALLPAPER)` in Fill mode, persisting it under `HKCU\Control Panel\Desktop`. `-Wallpaper <path>` picks a specific file, `-NoWallpaper` / `SKOOP_NO_WALLPAPER=1` skips both steps |
| Nushell shortcut | `shell/profile.ps1` defines `n` → `nu` when Nushell is installed and no `n` alias already exists. `apps/nushell/setup.ps1` writes `%LOCALAPPDATA%\skoop\nu-autostart.cmd` (a `doskey n=nu` macro) and appends it to HKCU `Command Processor\AutoRun` without replacing other entries; `-Remove` undoes it. Note this is an alias, not a shell replacement — PowerShell/cmd still start normally |
| Starship prompt | `apps/starship/configure.ps1` copies `apps/starship/starship.toml` to `~/.config/starship.toml` and `shell/profile.ps1` runs `starship init powershell`, so new PowerShell windows get the prompt. cmd.exe needs **Clink** (in `manifests/scoop.json`): the script installs `%LOCALAPPDATA%\clink\starship.lua` and runs `clink autorun install`, which appends to the existing AutoRun value instead of replacing it. Use `-NoCmd` to leave cmd alone, `-NoAutorun` to skip the registry edit, `-NoBackup` to overwrite without a `.bak`. Both loaders skip cleanly when `starship` is not installed |
| Rio config | `apps/rio/configure.ps1` copies `apps/rio/config.toml` to `%LOCALAPPDATA%\rio\config.toml`, backing up a changed original as `.bak.<timestamp>` unless `-NoBackup`. Font size (zoom) is **16**; Rio hot-reloads the file, so no restart is needed |
| gum picker falls back to the numbered list | gum draws its UI on **stderr** and only writes the answer to stdout. Capturing it with `2>&1` left it without a terminal, so it returned nothing; letting PowerShell inherit stderr instead turns the TUI into a `NativeCommandError` under `$ErrorActionPreference='Stop'`. The pickers now start gum through `System.Diagnostics.Process` with **only stdout redirected**, so the TUI stays on the console and the answer is captured — this works in Rio, WezTerm, Windows Terminal and Herdr. If a terminal still cannot draw it, pass `-NoGum` or set `$env:SKOOP_NO_GUM=1` |
| `herdr` says "nested herdr"/inception | A long-lived launcher (often Vicinae) inherited `HERDR_ENV=1` from a Herdr pane and passes it to new terminals. Run `.\apps\vicinae\enable-autostart.ps1 -Restart`, then close and reopen Rio/WezTerm. `shell/profile.ps1` already clears the variables for new PowerShell sessions. `apps/herdr/setup-ssh.ps1` uses `herdr machine add`, so it does not start a nested client at all |
| Rust toolchain | GNU is set as default only when no toolchain is active; switch with `rustup default stable-x86_64-pc-windows-msvc` (needs MSVC Build Tools) |
| Mouse wheel diagnostics / DPI | `apps/mouse/configure.ps1` installs `skoopub-mouse.exe` from the latest `mouse-v*` GitHub Release to `%LOCALAPPDATA%\skoop\mouse`; re-runs skip the download unless `-Force`. `mouse.ps1 fix` installs a `WH_MOUSE_LL` hook and `restore` stops it; neither touches drivers, registry or cafe software. `mouse.ps1 dpi` sets a Logitech HID++ mouse's hardware DPI (default **1200**) via `hidapi-rs` feature `0x2201`, verifies it by reading back, and is idempotent; `install.ps1` runs it after installing the exe (`-MouseDpi` / `SKOOP_MOUSE_DPI` to change, `-SkipMouseDpi` / `SKOOP_NO_MOUSE_DPI=1` to skip), and failures are non-fatal |
| LibreScroll | `apps/librescoll/configure.ps1` fetches the latest `LibreScroll/LibreScroll` release zip, verifies the GitHub API SHA-256 digest, extracts to `%LOCALAPPDATA%\skoop\librescoll\<tag>`, writes a Startup shortcut and starts the tray app; re-runs with the same tag skip the download and only repair the shortcut/process. `install.ps1` runs it on every setup (non-fatal). Pause or quit it before `skoopub-mouse` diagnostics because it blocks physical wheel events while active |
| `z` / `atuin` not found | The profile hook is missing or points at a missing `shell/profile.ps1`, or the window predates the install. `install.ps1` hooks both editions (Windows PowerShell 5.1 and PowerShell 7+ profiles are separate files); check `Get-Content $PROFILE` **in the shell that is missing the command** (pwsh reads `Documents\PowerShell\...`, 5.1 reads `Documents\WindowsPowerShell\...`); re-run `install.ps1` to rewrite both, then open a new window |
| kbots daemon | The Scoop package installs the `kbots`, `kb`, `kbots-tui` and `kbots-gui` shims but deliberately does not start the daemon; run `kbots daemon start`, then `kb status`. The daemon binds authenticated TCP on `127.0.0.1:7878` |
| Ollama | The **apps** phase installs `extras/ollama-full` (the `main` bucket's `ollama` is CLI-only — the daemon lives in `ollama-full`). It provides the `ollama` CLI plus the tray app/daemon, so `ollama run <model>` works. Models are **not** pulled automatically (they are multi-GB); pull the ones you want yourself, e.g. `ollama pull huihui_ai/dolphin3-abliterated:8b`. If the daemon is not running yet, launch the **Ollama** tray shortcut once (or run `ollama serve`) |

Requires Windows 10/11 (or Server 2016+) with PowerShell 5.1+ and internet access.
