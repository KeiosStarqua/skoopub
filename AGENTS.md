# AGENTS.md

Index of this repository for agents and humans. **skoop** is a declarative Windows
dev setup: [Scoop](https://scoop.sh) packages plus a repo-managed PowerShell profile,
restored from one manifest. There is no build system, no tests, and no package
manager of its own — the files are the product.

## File index

| Path | Type | Purpose |
|---|---|---|
| `scoop.json` | Manifest (JSON) | Single source of truth: `buckets` (main, extras, nerd-fonts, zeldrisho) + `apps` (name/source pairs) in `scoop export` format. Replayed with `scoop import scoop.json`. |
| `install.ps1` | PowerShell 5.1 script | Primary one-shot bootstrap. Works locally (`.\install.ps1`) or piped (`irm ... \| iex`); downloads the manifest when there is no checkout, hooks `profile.ps1` into `$PROFILE` early (so `z`/`atuin` load even if a later step fails), clears the Task Manager `DisableTaskMgr` policy (HKCU, plus HKLM when elevated; failures non-fatal), installs Scoop (per-user or system-wide when elevated), ensures git, installs Firefox before WezTerm and Herdr, requests Firefox as the default browser, deploys the Firefox policy (extensions, bookmarks, toolbar, homepage), runs `scoop import`, starts Tailscale (Windows service if present, otherwise the Scoop `tailscaled` shim; login stays manual), offers a temporary SSH key + Herdr remote setup (choose a tailnet machine, authorize a throwaway key, add an SSH alias, `herdr machine add`), sets GNU as the default Rust toolchain if none is active, then applies the ShareX PrtSc fix (failures are non-fatal), and offers `gh auth login` before wiring gh into git as a credential helper. Skips UniKey if one is already installed unless `-ForceUniKey`; `-SkipGhLogin` keeps the auth step non-interactive; finally applies the repo-managed Zed config and Alacritty font config. |
| `bootstrap.ps1` | PowerShell script | Older/simpler equivalent of `install.ps1`: install Scoop, hook the profile dot-source line early, clear the Task Manager `DisableTaskMgr` policy (HKCU, plus HKLM when elevated; failures non-fatal), install Firefox before WezTerm and Herdr, request Firefox as the default browser, deploy the Firefox policy (extensions, bookmarks, toolbar, homepage), `scoop import scoop.json`, start Tailscale (Windows service if present, otherwise the Scoop `tailscaled` shim; login stays manual), offer a temporary SSH key + Herdr remote setup, set GNU Rust default when no toolchain is active, apply the ShareX PrtSc fix (non-fatal), then offer `gh auth login` and register gh as the git credential helper. Also skips an existing UniKey unless `-ForceUniKey`; `-SkipGhLogin` skips the prompt, then applies the repo-managed Zed and Alacritty configs. Kept for `-File` usage from a clone. |
| `profile.ps1` | PowerShell profile fragment | Shell config dot-sourced from `$PROFILE`. Must stay idempotent; initialises `zoxide` and `atuin` (imports PSReadLine first and skips quietly if it is unavailable). |
| `fix-sharex-printscreen.ps1` | PowerShell utility | Disables the Windows "Print screen opens Snipping Tool" setting (`PrintScreenKeyForSnippingEnabled = 0`), optionally restarts Explorer (`-RestartExplorer`), seeds ShareX config so hotkeys register without the first-run welcome screen, then restarts ShareX unless `-NoRestart`. Run by `install.ps1`/`bootstrap.ps1` after the import; safe to run standalone. |
| `sharex-hotkeys.template.json` | JSON template | Default ShareX hotkey set (PrtSc, Ctrl/PrtSc, Alt/PrtSc, Shift/PrtSc, Ctrl+Shift/PrtSc) copied on first run when `HotkeysConfig.json` is missing. |
| `firefox-policies.template.json` | JSON template | Firefox enterprise policy copied to the Scoop install's `distribution\policies.json`; auto-installs Bitwarden, "I still don't care about cookies" (both AMO) and mymind (pinned vendor XPI) with `normal_installed`, shows the bookmarks toolbar, adds a `skoopub` managed-bookmarks folder (Hacker News, mymind, Scoop, OpenCode), sets ChatGPT as the homepage, and disables Firefox's save-login prompt (`OfferToSaveLogins`/`OfferToSaveLoginsDefault` = false). |
| `setup-gh-auth.ps1` | PowerShell utility | Checks `gh auth status --hostname github.com`, offers to run `gh auth login` when needed (interactive; `-SkipLogin` / `-ForceLogin`), then runs `gh auth setup-git` so `git push` uses gh's token. Called by both bootstraps after the ShareX fix; safe to run standalone. |
| `zed/` | JSON config | Repo-managed Zed config: `settings.json` (theme, font, format-on-save, auto-update off, declared extensions, rust-analyzer), `keymap.json` and `tasks.json`. |
| `configure-zed.ps1` | PowerShell utility | Copies `zed/*.json` into `%APPDATA%\Zed` (settings/keymap/tasks) and ensures `themes`/`snippets` folders exist. Changed originals get a `.bak.<timestamp>` copy unless `-NoBackup`; `-ConfigDir` / `-SourceDir` allow testing. Called by both bootstraps after gh auth; safe to run standalone. |
| `alacritty/` | TOML config | Repo-managed `alacritty.toml`: JetBrainsMono Nerd Font Mono (Regular/Bold/Italic/Bold Italic) at 12pt, `builtin_box_drawing = true`, small font offset and window padding, for Herdr TUI glyphs and borders. |
| `configure-alacritty.ps1` | PowerShell utility | Copies `alacritty/alacritty.toml` into `%APPDATA%\alacritty\alacritty.toml`. A changed original gets a `.bak.<timestamp>` copy unless `-NoBackup`; `-SourceFile` / `-ConfigDir` allow testing. Called by both bootstraps after the Zed config; safe to run standalone. |
| `setup-herdr-ssh.ps1` | PowerShell utility | For public/internet-cafe machines after `tailscale up`: lists tailnet peers and asks which machine has Herdr, asks for the SSH user, creates a temporary ed25519 key pair under `%TEMP%`, runs `ssh` (you type the password) to authorize the public key on the remote, adds a marked `Host <alias>` block to `~/.ssh/config`, and runs `herdr machine add`. `-Revoke -Alias <alias>` removes the remote key, local key pair and config block; `-SkipMachineAdd` stops before Herdr. Called by both bootstraps after Tailscale; skips when offline/non-interactive; safe to run standalone. |
| `README.md` | Docs | User-facing overview, install commands, update workflow, and per-user vs elevated behavior. |
| `AGENTS.md` | Docs | This index and the conventions below. |
| `.git/` | Git metadata | Version control only; not part of the setup. No tracked content should be added here by hand. |

## Current inventory

Buckets: `main`, `extras`, `nerd-fonts` (Scoop Nerd Fonts), `zeldrisho` (community bucket for Vietnamese IMEs).

Apps — `main`: git, pwsh, herdr, herdr-core, 7zip, mise, uv, ripgrep, fd, bat, fzf, jq,
gh, less, starship, delta, zoxide, atuin, rustup, mingw, bun, cursor-cli,
opencode.
Apps — `extras`: firefox, vscode, lazygit, alacritty, sharex, tailscale, zed, grok-bot, pear-desktop, vicinae, chatgpt,
blender.
Apps — `nerd-fonts`: JetBrainsMono-NF (JetBrains Mono Nerd Font for Alacritty/Herdr TUI).
Apps — `zeldrisho`: unikey (Vietnamese IME; third-party bucket).

## Conventions

- **Add or remove a package** by editing `scoop.json`; keep the `{ "Info": "", "Source": ..., "Name": ... }` shape and keep apps grouped by source. Real-world workflow: `scoop install <app>` then `scoop export | Out-File -Encoding utf8 scoop.json` (verify the diff before committing).
- **Buckets must exist before their apps**; if you introduce a new bucket, add it to `buckets` and make sure `install.ps1`/`bootstrap.ps1` still import cleanly (buckets are git repos, hence the git step).
- **Scripts target Windows PowerShell 5.1+** with `$ErrorActionPreference = 'Stop'`, and must run without admin unless explicitly elevated. Avoid PowerShell 7-only syntax.
- **Idempotence matters.** `install.ps1`/`bootstrap.ps1` and `profile.ps1` may run repeatedly; check before appending to `$PROFILE` and guard optional commands with `Get-Command ... -ErrorAction SilentlyContinue`.
- **Keep the three docs in sync** when behavior changes: `README.md` (users), `AGENTS.md` (inventory/conventions), and the comment-based help in `install.ps1`.
- **Verify changes** with `scoop export` (manifest fidelity) and by re-running the affected script in a fresh `powershell` process; there is no automated test suite.
- **Editor config:** keep Zed user config in `zed/` and re-run `.\configure-zed.ps1` after edits. Never put credentials, API keys or tokens in these public JSON files.

## Git workflow

- **Auto commit and push.** After finishing a change, commit and push it to `origin`
  without waiting to be asked. Stage only the files you touched (`git add <paths>`),
  write a concise imperative message (e.g. `Add one-shot install script and README`),
  then `git push`. Don't sweep unrelated work-in-progress into the commit; if the push
  is rejected, `git pull --rebase` and retry once.
- Skip the commit/push only when the user explicitly asks you not to, or when the change
  is unverified and the user wants to review it first.

## Notes

- The repo is not a Scoop bucket and publishes nothing; `install.ps1` is fetched raw from `https://raw.githubusercontent.com/KeiosStarqua/skoopub/main/install.ps1` (override with `-RepoRawBase`).
- Tailscale installs its service separately; the Scoop package provides the CLI (`tailscale`, `tailscaled`) and needs `tailscaled` running before `tailscale status` works. Both bootstraps now start the Windows `Tailscale` service (and set it to Automatic) when present, otherwise launch the Scoop `tailscaled` shim; `tailscale up` still requires an interactive login.
- `zeldrisho/scoop-bucket` is third-party: the UniKey manifest installs the official `unikey.org` archive with a pinned SHA-256 hash. Verify the diff when bumping versions.
- Public PCs may already have UniKey installed outside Scoop. Both bootstraps detect it (running `UniKeyNT`, uninstall registry, existing Scoop app dir) and import a temporary manifest without `unikey`; `-ForceUniKey` overrides.
- Rust: `rustup` installs the toolchain into `persist\rustup`; the bootstraps only set GNU as default when `rustup show active-toolchain` fails, so an existing MSVC choice survives. Cargo's bin is on the user PATH via the Scoop manifest. A fresh `rustup` writes "no active toolchain" to stderr and exits 1; under `$ErrorActionPreference = 'Stop'` that is a terminating `NativeCommandError` in PowerShell 5.1, so both scripts run the check via `cmd /c ... 2>&1` and inspect `$LASTEXITCODE` instead.
- Firefox: the bootstraps call `firefox --setDefaultBrowser` after installing it (skipped when http is already handled by Firefox). Direct `UserChoice` registry writes are blocked on modern Windows, and Windows 11 may open Settings for confirmation; failures are non-fatal.
- Firefox extensions: `firefox-policies.template.json` is copied to `<scoop>\apps\firefox\current\distribution\policies.json` (Scoop persists that folder) and auto-installs Bitwarden and "I still don't care about cookies" (both AMO) plus mymind (pinned vendor XPI URL) with `normal_installed`. It also sets `DisplayBookmarksToolbar: always`, a `skoopub` managed-bookmarks folder (Hacker News, mymind, Scoop, OpenCode), and `Homepage` (ChatGPT as URL with `StartPage: homepage`). It disables the built-in password-saving prompt via `OfferToSaveLogins: false` plus `OfferToSaveLoginsDefault: false` (Bitwarden handles logins). Firefox reads policies at startup, so restart it after the first setup; switch to `force_installed` only if an extension should be locked.
- GitHub auth: `gh auth login` alone does not configure git. `setup-gh-auth.ps1` runs `gh auth setup-git`, which writes `credential.https://github.com.helper` (`gh auth git-credential`) so `git push` uses the gh token via HTTPS. Both bootstraps call it after the ShareX fix; `-SkipGhLogin` makes that step non-interactive, and failures are non-fatal.
- Temporary Herdr SSH: on a public machine, `setup-herdr-ssh.ps1` generates an ed25519 key pair in `%TEMP%\skoop-herdr-ssh` and only the public key is appended to the home machine's `authorized_keys` (SSH asks for the password). The private key never leaves the local machine, the `~/.ssh/config` block is delimited by `# >>> skoop-herdr <alias>` / `# <<< skoop-herdr <alias>` markers, and `-Revoke` removes all three pieces. Never commit these keys; the bootstraps call the script only when interactive and tailnet peers exist, and treat failures as non-fatal.
- Zed's in-app auto-update is disabled in `zed/settings.json` (`auto_update: false`); otherwise it installs outside Scoop and the pinned version in `scoop.json` stops matching reality. `innounp` is pulled in automatically as the installer dependency.
- Zed config lives in `%APPDATA%\Zed` (`settings.json`, `keymap.json`, `tasks.json`, `themes/`, `snippets/`); extensions install into `%LOCALAPPDATA%\Zed\extensions`. `configure-zed.ps1` is called by both bootstraps after gh auth and copies `zed/*.json` there with timestamped backups before overwriting (`-NoBackup` skips that). Piped installs fetch `zed/*.json` to `%LOCALAPPDATA%\skoop\zed`.
- Zed extensions: `auto_install_extensions` declares PowerShell, HTML, Dockerfile, Docker Compose, TOML, Nix and SQL; Zed installs them at startup. The PowerShell extension needs `pwsh` (now in `scoop.json`); Rust needs no extension because Zed ships `rust-analyzer` natively, so `lsp.rust-analyzer` is configured instead of a nonexistent `rust` extension ID.
- Alacritty font: `JetBrainsMono-NF` comes from the `nerd-fonts` bucket and installs "JetBrainsMono Nerd Font Mono". `configure-alacritty.ps1` copies `alacritty/alacritty.toml` to `%APPDATA%\alacritty` with timestamped backups unless `-NoBackup`; the config uses 12pt, all four styles, `builtin_box_drawing = true` and small offsets/padding so Nerd Font icons and Herdr TUI borders render. Restart Alacritty after the first setup. Alacritty has no ligatures or custom fallback list, so it looks similar to but not identical to WezTerm.
