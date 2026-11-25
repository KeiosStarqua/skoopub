# AGENTS.md

Index of this repository for agents and humans. **skoop** is a declarative Windows
dev setup: [Scoop](https://scoop.sh) packages plus a repo-managed PowerShell profile,
restored from one manifest. There is no build system, no tests, and no package
manager of its own — the files are the product.

## File index

| Path | Type | Purpose |
|---|---|---|
| `scoop.json` | Manifest (JSON) | Single source of truth: `buckets` (main, extras, zeldrisho) + `apps` (name/source pairs) in `scoop export` format. Replayed with `scoop import scoop.json`. |
| `install.ps1` | PowerShell 5.1 script | Primary one-shot bootstrap. Works locally (`.\install.ps1`) or piped (`irm ... \| iex`); downloads the manifest when there is no checkout, installs Scoop (per-user or system-wide when elevated), ensures git, runs `scoop import`, applies the ShareX PrtSc fix, then hooks `profile.ps1` into `$PROFILE`. Skips UniKey if one is already installed unless `-ForceUniKey`. |
| `bootstrap.ps1` | PowerShell script | Older/simpler equivalent of `install.ps1`: install Scoop, `scoop import scoop.json`, apply the ShareX PrtSc fix, append the profile dot-source line. Also skips an existing UniKey unless `-ForceUniKey`. Kept for `-File` usage from a clone. |
| `profile.ps1` | PowerShell profile fragment | Shell config dot-sourced from `$PROFILE`. Must stay idempotent; currently initialises `zoxide`. |
| `fix-sharex-printscreen.ps1` | PowerShell utility | Disables the Windows "Print screen opens Snipping Tool" setting (`PrintScreenKeyForSnippingEnabled = 0`), optionally restarts Explorer (`-RestartExplorer`), seeds ShareX config so hotkeys register without the first-run welcome screen, then restarts ShareX unless `-NoRestart`. Run by `install.ps1`/`bootstrap.ps1` after the import; safe to run standalone. |
| `sharex-hotkeys.template.json` | JSON template | Default ShareX hotkey set (PrtSc, Ctrl/PrtSc, Alt/PrtSc, Shift/PrtSc, Ctrl+Shift/PrtSc) copied on first run when `HotkeysConfig.json` is missing. |
| `README.md` | Docs | User-facing overview, install commands, update workflow, and per-user vs elevated behavior. |
| `AGENTS.md` | Docs | This index and the conventions below. |
| `.git/` | Git metadata | Version control only; not part of the setup. No tracked content should be added here by hand. |

## Current inventory

Buckets: `main`, `extras`, `zeldrisho` (community bucket for Vietnamese IMEs).

Apps — `main`: git, herdr, herdr-core, 7zip, mise, uv, ripgrep, fd, bat, fzf, jq,
gh, less, starship, delta, zoxide.
Apps — `extras`: vscode, lazygit, wezterm, sharex, tailscale.
Apps — `zeldrisho`: unikey (Vietnamese IME; third-party bucket).

## Conventions

- **Add or remove a package** by editing `scoop.json`; keep the `{ "Info": "", "Source": ..., "Name": ... }` shape and keep apps grouped by source. Real-world workflow: `scoop install <app>` then `scoop export | Out-File -Encoding utf8 scoop.json` (verify the diff before committing).
- **Buckets must exist before their apps**; if you introduce a new bucket, add it to `buckets` and make sure `install.ps1`/`bootstrap.ps1` still import cleanly (buckets are git repos, hence the git step).
- **Scripts target Windows PowerShell 5.1+** with `$ErrorActionPreference = 'Stop'`, and must run without admin unless explicitly elevated. Avoid PowerShell 7-only syntax.
- **Idempotence matters.** `install.ps1`/`bootstrap.ps1` and `profile.ps1` may run repeatedly; check before appending to `$PROFILE` and guard optional commands with `Get-Command ... -ErrorAction SilentlyContinue`.
- **Keep the three docs in sync** when behavior changes: `README.md` (users), `AGENTS.md` (inventory/conventions), and the comment-based help in `install.ps1`.
- **Verify changes** with `scoop export` (manifest fidelity) and by re-running the affected script in a fresh `powershell` process; there is no automated test suite.

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
- Tailscale installs its service separately; the Scoop package provides the CLI (`tailscale`, `tailscaled`) and needs `tailscaled` running before `tailscale status` works.
- `zeldrisho/scoop-bucket` is third-party: the UniKey manifest installs the official `unikey.org` archive with a pinned SHA-256 hash. Verify the diff when bumping versions.
- Public PCs may already have UniKey installed outside Scoop. Both bootstraps detect it (running `UniKeyNT`, uninstall registry, existing Scoop app dir) and import a temporary manifest without `unikey`; `-ForceUniKey` overrides.
