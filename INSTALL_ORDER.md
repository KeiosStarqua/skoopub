# Install order

`install.ps1` runs every step **sequentially**; there is no DAG. Package order
comes from `manifests/phases.json` (phase order, then app order inside a phase)
and versions from `manifests/scoop.json`. On PowerShell 7, app imports **within
one phase** may run concurrently (default `-ThrottleLimit 4`); the script waits
for all of them before the next phase or callback, so phase order is unchanged.
`-ThrottleLimit 1` and Windows PowerShell 5.1 run app imports sequentially.
This file mirrors the script; when the order changes, change the manifest or
`install.ps1` first and then update this page.

`core/bootstrap.ps1` is the older `-File` bootstrap and does not follow this list.

## Phase 1 — `core-terminal` (fatal on failure)

Terminal and launcher first, so the rest of the run has a usable shell.

1. git, pwsh, rio, alacritty, wezterm
2. herdr, herdr-core
3. vicinae
4. JetBrainsMono-NF, JetBrainsMono-NF-Propo

After the phase, in this order:

1. Refresh this process's `PATH` from the registry and resolve Scoop executables
   from the Scoop roots, so apps installed in this phase are visible without
   opening a new shell.
2. The pwsh re-launch: a Windows PowerShell 5.1 process stops here and the run
   continues under PowerShell 7 (piped runs use a cached copy of `install.ps1`).
3. `apps/rio/configure.ps1` (font size / zoom).
4. Open Rio in `~/repos` with Herdr already running, using the resolved pwsh 7
   executable (`-NoAutoHerdr` opts out). Skipped when a Rio window is already
   open, so repeated install runs do not stack terminals.

Rio is deliberately installed before Herdr; Vicinae is only installed here and
configured later, after its backup restore.

## Phase 2 — `tailscale` (fatal on failure; `-EssentialsOnly` stops here)

Installs Tailscale, then the callback does everything that needs the network:

1. Install OpenCode, then Firefox from their `manifests/scoop.json` entries (their
   restores need the CLI / the browser profile; skipped with `-EssentialsOnly`).
2. Start the Tailscale daemon.
3. `apps/tailscale/configure.ps1 -SignIn`: `tailscale up --qr` in a new Rio window
   (reusing one already showing the QR; a console fallback forces UTF-8), wait
   until online, then restore OpenCode first, followed by Vicinae, Pear Desktop,
   Firefox and Atuin as parallel child processes (each with its own restore log),
   then advertise `tag:public-client`.
4. Restore the SSH key (`core/restore-backup.ps1 -Only ssh`).
5. Restore the registered repo list (`-Only repos`).
6. Apply the Vicinae config (Ctrl+Space) and autostart on top of the restored data.
7. `gh auth login` / `gh auth setup-git`, so private checkouts can authenticate.
8. Clone skoopub into `~/repos\skoopub`, then every missing repo from the restored
   (or shipped) `repos.json`.

## Phase 3 — `shell`

7zip, charm-gum, nu, zoxide, atuin, starship, clink, delta, fzf, ripgrep, fd, bat,
jq, less, btop-lhm, mise, uv, gh, opencode, cursor-cli.

## Phase 4 — `editors`

vscode, zed, lazygit, rustup, mingw, bun.

## Phase 5 — `apps` (`unikey` is skipped when it is already installed)

firefox, sharex, grok-bot, pear-desktop, chatgpt, blender, yasb, komorebi, whkd,
cava, ollama-full, unikey, kbots.

Each phase adds its buckets first, then imports its apps in the order above —
concurrently on PowerShell 7 (up to `-ThrottleLimit`, so completion order can
differ from the list). Apps already installed are left out (`-ForceInstall`
re-imports them). A phase 1 failure aborts the run; later phase failures are
reported and the remaining phases still run.

## Before the phases (every run)

1. Mode selection: Full by default; `-Menu` opts into the selector, `-HerdrPeer`
   runs only the Herdr connection.
2. Locate the checkout, or download the repo files to `%LOCALAPPDATA%\skoop`.
3. Dark Mode (`core/set-dark-mode.ps1`) — no network, so the rest is already dark.
4. Execution policy + the repo-managed profile hook (`Install-ProfileHook`), then
   verify the profile loads in a fresh shell.
5. Clear the Task Manager policy.
6. Check Windows activation (and activate when it is not).
7. Install Scoop when its shims are missing.
8. Put the shims on PATH and cache the backup user.
9. Install git when missing — buckets are git repos.
10. Run the phases above.

## After the phases

1. UniKey config (Unicode + VNI, Vietnamese on, startup shortcut).
2. Firefox policies and default browser.
3. Start Tailscale and tag this device.
4. Herdr remote peer (interactive; `-HerdrPeer` / `-Peer`).
5. Default Rust toolchain: GNU, only when no toolchain is active.
6. ShareX PrtSc fix (check-first).
7. Git author identity.
8. Zed settings, keymap and tasks.
9. Komorebi: whkdrc + whkd, the Rio/Firefox column watcher, then taskbar auto-hide
   (inside `apps/komorebi/configure.ps1`, whose Explorer restart runs last).
10. YASB theme, fonts and the wallpaper clone, then start the bar.
11. Wallpaper restrictions + a random desktop wallpaper (needs the YASB clone).
12. Nushell `n` shortcut (PowerShell + cmd AutoRun).
13. Starship prompt (PowerShell + Clink for cmd).
14. marimo dark mode.
15. ponytail plugin for OpenCode (skipped when already listed).
16. Shutdown cleanup hook.
17. skoopub-mouse install, then the Logitech DPI value.
18. LibreScroll install + startup shortcut.
19. Start Tailscale and ShareX from their `Scoop Apps` Start Menu shortcuts when
    they are not already running.

Why these boundaries matter:

- Scoop before git, because the git install uses Scoop; git before the phases,
  because bucket setup is git.
- Tailscale and its restores before GitHub auth and any clone, because the
  snapshots and private repos live behind the tailnet.
- OpenCode and Firefox before their restores, because one needs `opencode auth
  import` and the other needs its profile in place.
- Vicinae config/autostart after its restore, so the repo-managed keybinds win.
- YASB before the wallpaper step, because that step reuses the wallpaper clone.
- Tray apps last, so nothing they spawn is disturbed by an Explorer restart.
- A phase boundary is a barrier: buckets and every app import in that phase
  finish (or fail) before `AfterPhase` or the next phase starts.

## Where to change the order

- Package order: `manifests/phases.json` (phase and app order). It is the
  machine-readable plan — there is no separate `install-plan.json` or DAG, and
  `core/scoop-phases.ps1` rejects unassigned, duplicated or unknown apps.
- Step order: the numbered `# --- N.` sections in `install.ps1`; keep the help
  text, `README.md`, `AGENTS.md` and this file in sync.
- Concurrency inside a phase: `-ThrottleLimit` on `install.ps1` /
  `Invoke-SkoopPhases` (or `SKOOP_THROTTLE`); it never changes the order above.
