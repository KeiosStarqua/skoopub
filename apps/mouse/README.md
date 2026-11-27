# skoopub mouse

Wheel diagnostics and (opt-in) correction for the "scroll randomly goes the
wrong way" symptom on shared/public Windows PCs. The executable is built by
`.github/workflows/mouse-release.yml` on every `mouse-v*` tag and downloaded
from the GitHub Release — no Rust toolchain is needed on the target machine.

## Why two event streams

| Layer | Source | Meaning |
|---|---|---|
| `raw` | HID Raw Input (`WM_INPUT`) | What the mouse/driver actually reported. |
| `wm` | `WH_MOUSE_LL` (`WM_MOUSEWHEEL`) | What applications are about to receive. |

If `raw` is fine but `wm` is inverted, a software hook or filter (G HUB, a cafe
client, another utility) flips the sign. If `raw` itself contains short
alternating-sign bursts, suspect the encoder, USB receiver, or a second pointing
device. A device reporting `OK` in Device Manager only means it is recognized,
not that its wheel data is correct.

## Commands

```powershell
.\apps\mouse\mouse.ps1 install                     # download the release exe
.\apps\mouse\mouse.ps1 diagnose -Seconds 30         # capture + JSON report
.\apps\mouse\mouse.ps1 monitor                     # stream events live
.\apps\mouse\mouse.ps1 status                      # is correction running?
.\apps\mouse\mouse.ps1 fix                         # start correction (hidden)
.\apps\mouse\mouse.ps1 fix -DryRun                 # observe without changing events
.\apps\mouse\mouse.ps1 fix -Adaptive               # experimental per-trend filter
.\apps\mouse\mouse.ps1 restore                     # stop correction, keep config
```

Direct binary (same commands without the `.ps1` wrapper):

```
skoopub-mouse diagnose [--seconds 30] [--out <path>] [--debug-raw]
skoopub-mouse monitor  [--seconds 30]
skoopub-mouse fix [--adaptive] [--dry-run] [--from <report>] [--force]
skoopub-mouse restore
skoopub-mouse status
```

Data is written to `%LOCALAPPDATA%\skoop\mouse\`: `scroll-report.json`,
`config.json`, `mouse.pid`.

## Before enabling `fix`

`fix` only flips the wheel sign when `diagnose` shows a strong mismatch
(>= 5 inverted events and >= 60% of correlated events). Otherwise it leaves
correction disabled and tells you to capture again; `--force` overrides that.
`restore` always stops the hook and disables the config.

Correction is a `WH_MOUSE_LL` hook that edits `MSLLHOOKSTRUCT.mouseData`. In the
Windows hook chain the most recently installed hook is called first, so a
long-lived hook installed by another utility *before* skoopub-mouse may still
change the value afterwards. For persistent correction, start `fix` early in
the session and re-run `diagnose` to confirm the resolved event stream.

`--adaptive` flips only an isolated outlier that contradicts at least three
recent wheel events in the same 500 ms window. It is experimental: a deliberate
quick reverse can be mistaken for noise. Prefer plain `fix` unless you have
captured enough data to justify it.

## Limits

- The tool observes wheel events only; it does not touch mouse buttons, pointer
  speed, "Enhance pointer precision", drivers, registry, or cafe client software.
- `diagnose` needs actual wheel turns during the capture window. Running it
  with no input correctly reports an inconclusive sample.
- On a machine with KMSpico remnants, disabled Windows Update and no Defender
  status, do not enter sensitive credentials while experimenting with input
  hooks. Diagnostics (`diagnose`/`monitor`/`status`) are read-only with respect
  to the input stream; `fix` deliberately hooks it.
