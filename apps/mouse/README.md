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

## Reading the report

- `injected` on an event is true when `WH_MOUSE_LL` flagged it with
  `LLMHF_INJECTED` (synthetic input). `SendInput` does not always set that flag,
  so the tool also checks HID identity: an unresolved `unknown-hid` path makes
  `identified=false` and sets `physical_sample=false`.
- `expect` windows (seconds from capture start) define the direction the
  operator says they are scrolling. `unexpected_direction` counts raw events
  that contradict the schedule; the protocol below uses two windows.
- `devices[].mismatch_rate` is the per-device error rate; `devices[].vid_pid`
  summarises the HID path (`VID_046D&PID_C08F`, …).
- `burst_count` / `isolated_reversals` describe runs of same-direction scrolls
  and one-off reversals inside a run (noise or accidental double input).
- `expected_down_*` / `expected_up_*` separate the error rate per intended
  direction, and `outside_expect_events` counts wheel events during declared
  rest windows (a mouse that scrolls by itself will show them).
- The conclusion now distinguishes the layers: *"already present in Raw Input"*
  means raw and WM agree and both are wrong (device/driver/earlier layer), while
  *"cross-layer mismatch"* means raw is right and WM is flipped (software hook).
- Never enable `fix` from a sample with `physical_sample=false` or with
  `warnings` about injected/unidentified input.

## Driver diagnostics

Static, read-only inspection of the HID/mouse driver stack (no driver, service,
registry value or cafe software is changed):

```powershell
.\apps\mouse\mouse.ps1 driver                     # full report JSON + summary
.\apps\mouse\mouse.ps1 driver -Action inspect     # PnP devices, INF, version, service
.\apps\mouse\mouse.ps1 driver -Action stack       # parent chain (HID → USB → root hub)
.\apps\mouse\mouse.ps1 driver -Action filters     # Mouse/HID/USB Upper/LowerFilters
.\apps\mouse\mouse.ps1 driver -Action integrity   # Authenticode + file version of HID/USB drivers
.\apps\mouse\mouse.ps1 driver -Action events -Days 7
.\apps\mouse\mouse.ps1 driver -Action report -Out "$env:TEMP\driver-report.json"
```

`filters` flags anything outside the known-good sets (`mouclass` for Mouse,
`usbccgp` for USB); a third-party filter there is active even when its GUI is
closed. `-Deep` adds `sfc /verifyonly` (slow, needs an elevated shell).

### 60-second physical-mouse protocol

```powershell
.\apps\mouse\mouse.ps1 diagnose -Seconds 60 -Expect 'down@0-25,up@30-55' -Cues
```

`-Cues` beeps at 0 s (start down), 25 s (rest), 30 s (start up) and 55 s (rest).
Scroll **only down** from 0–25 s, rest 25–30 s, scroll **only up** from
30–55 s, rest 55–60 s. A real mouse should resolve a `VID_*/PID_*` path and
produce `physical_sample=true`. Try to reproduce the random reversal during
those windows; `outside_expect_events > 0` means input arrived while resting.

## Commands

```powershell
.\apps\mouse\mouse.ps1 install                     # download the release exe
.\apps\mouse\mouse.ps1 diagnose -Seconds 60 -Expect 'down@0-25,up@30-55' -Cues
.\apps\mouse\mouse.ps1 monitor                     # stream events live
.\apps\mouse\mouse.ps1 status                      # is correction running?
.\apps\mouse\mouse.ps1 fix                         # start correction (hidden)
.\apps\mouse\mouse.ps1 fix -DryRun                 # observe without changing events
.\apps\mouse\mouse.ps1 fix -Adaptive               # experimental per-trend filter
.\apps\mouse\mouse.ps1 restore                     # stop correction, keep config
```

Direct binary (same commands without the `.ps1` wrapper):

```
skoopub-mouse diagnose [--seconds 30] [--out <path>] [--debug-raw] [--cues]
                       [--expect down@0-25,up@30-55]
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

- `diagnose`/`monitor`/`fix` observe wheel events only; they do not touch mouse
  buttons, pointer speed, "Enhance pointer precision", drivers, registry, or
  cafe client software. The `driver` commands are read-only inspection and
  change nothing either.
- `diagnose` needs actual wheel turns during the capture window. Running it
  with no input correctly reports an inconclusive sample.
- On a machine with KMSpico remnants, disabled Windows Update and no Defender
  status, do not enter sensitive credentials while experimenting with input
  hooks. Diagnostics (`diagnose`/`monitor`/`status`) are read-only with respect
  to the input stream; `fix` deliberately hooks it.
