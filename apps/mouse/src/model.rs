//! Event model, anomaly analysis and correction rules for the mouse wheel tool.
//!
//! No Windows API calls live here so the decision logic stays easy to reason
//! about (and can be unit tested later without a message loop).

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// A window of the capture where the operator says which way they are scrolling.
/// Example: `down@0-25,up@30-55` (seconds from the start).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExpectWindow {
    pub direction: String,
    pub sign: i32,
    pub start_ms: u128,
    pub end_ms: u128,
}

/// A wheel event captured from one of the two observable layers.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScrollEvent {
    /// Milliseconds since the capture session started.
    pub t_ms: u128,
    /// `raw` (HID Raw Input) or `wm` (WM_MOUSEWHEEL / WM_MOUSEHWHEEL hook).
    pub layer: String,
    /// HID device path for `raw`, `hook` for `wm`.
    pub device: String,
    /// Signed wheel delta. Positive = up / away from the user.
    pub delta: i32,
    /// `vertical` or `horizontal`.
    pub axis: String,
    /// WM events flagged LLMHF_INJECTED (synthetic input, e.g. SendInput).
    pub injected: bool,
    /// Whether the HID device path could be resolved for a raw event.
    pub identified: bool,
    /// VID/PID pair parsed from the HID path, empty when unidentified.
    pub vid_pid: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct DeviceStats {
    pub device: String,
    pub vid_pid: String,
    pub raw_up: u32,
    pub raw_down: u32,
    pub wm_up: u32,
    pub wm_down: u32,
    pub matched: u32,
    pub mismatched: u32,
    pub mismatch_rate: f64,
    pub noisy: u32,
    pub injected: u32,
    pub unexpected: u32,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct Analysis {
    pub raw_events: usize,
    pub wm_events: usize,
    pub matched: u32,
    pub mismatched: u32,
    pub mismatch_rate: f64,
    pub noisy_candidates: u32,
    pub injected_events: u32,
    pub burst_count: u32,
    pub isolated_reversals: u32,
    pub expected_windows: usize,
    pub expected_checked: u32,
    pub unexpected_direction: u32,
    pub expected_down_total: u32,
    pub expected_down_error: u32,
    pub expected_up_total: u32,
    pub expected_up_error: u32,
    pub outside_expect_events: u32,
    pub physical_sample: bool,
    pub conclusions: Vec<String>,
    pub warnings: Vec<String>,
    pub devices: Vec<DeviceStats>,
}

/// Max distance between a Raw Input wheel event and the WM_* event it produced.
const CORRELATION_MS: u128 = 150;
/// Two opposite-sign raw events closer than this are a noise candidate only
/// when they are small (one notch) — a deliberate reversal is usually slower.
const NOISE_WINDOW_MS: u128 = 80;
const NOISE_MAX_ABS_DELTA: i32 = 120;
/// Gap above which a run of wheel events is considered a separate scroll burst.
const BURST_PAUSE_MS: u128 = 500;

fn sign(delta: i32) -> i32 {
    if delta > 0 {
        1
    } else if delta < 0 {
        -1
    } else {
        0
    }
}

fn stats_for<'a>(map: &'a mut HashMap<String, DeviceStats>, e: &ScrollEvent) -> &'a mut DeviceStats {
    map.entry(e.device.clone()).or_insert_with(|| DeviceStats {
        device: e.device.clone(),
        vid_pid: e.vid_pid.clone(),
        ..Default::default()
    })
}

pub fn analyze(events: &[ScrollEvent], expect: &[ExpectWindow]) -> Analysis {
    let mut devices: HashMap<String, DeviceStats> = HashMap::new();
    let mut raw: Vec<(usize, &ScrollEvent)> = Vec::new();
    let mut wm: Vec<&ScrollEvent> = Vec::new();
    let mut injected_events = 0u32;
    let mut unexpected_direction = 0u32;
    let mut expected_checked = 0u32;
    let mut expected_down_total = 0u32;
    let mut expected_down_error = 0u32;
    let mut expected_up_total = 0u32;
    let mut expected_up_error = 0u32;
    let mut outside_expect_events = 0u32;

    for (i, e) in events.iter().enumerate() {
        if e.injected {
            injected_events += 1;
        }
        let s = stats_for(&mut devices, e);
        if e.injected {
            s.injected += 1;
        }
        if !expect.is_empty() && e.layer == "raw" {
            match expect
                .iter()
                .find(|w| e.t_ms >= w.start_ms && e.t_ms <= w.end_ms)
            {
                Some(window) => {
                    expected_checked += 1;
                    if window.sign < 0 {
                        expected_down_total += 1;
                    } else {
                        expected_up_total += 1;
                    }
                    if sign(e.delta) != window.sign {
                        unexpected_direction += 1;
                        s.unexpected += 1;
                        if window.sign < 0 {
                            expected_down_error += 1;
                        } else {
                            expected_up_error += 1;
                        }
                    }
                }
                None => outside_expect_events += 1,
            }
        }
        if e.layer == "raw" {
            raw.push((i, e));
            if e.delta > 0 {
                s.raw_up += 1;
            } else if e.delta < 0 {
                s.raw_down += 1;
            }
        } else if e.layer == "wm" {
            wm.push(e);
            if e.delta > 0 {
                s.wm_up += 1;
            } else if e.delta < 0 {
                s.wm_down += 1;
            }
        }
    }

    // Pair each WM event with the closest unclaimed raw event on the same axis.
    let mut claimed = vec![false; events.len()];
    let mut matched = 0u32;
    let mut mismatched = 0u32;
    for w in &wm {
        let mut best: Option<(u128, usize)> = None;
        for &(idx, r) in &raw {
            if claimed[idx] || r.axis != w.axis {
                continue;
            }
            let gap = if r.t_ms <= w.t_ms {
                w.t_ms - r.t_ms
            } else {
                r.t_ms - w.t_ms
            };
            if gap <= CORRELATION_MS && best.map_or(true, |(b, _)| gap < b) {
                best = Some((gap, idx));
            }
        }
        if let Some((_, idx)) = best {
            claimed[idx] = true;
            let r = &events[idx];
            let s = stats_for(&mut devices, r);
            if sign(r.delta) == sign(w.delta) {
                matched += 1;
                s.matched += 1;
            } else {
                mismatched += 1;
                s.mismatched += 1;
            }
        }
    }

    for s in devices.values_mut() {
        let total = s.matched + s.mismatched;
        s.mismatch_rate = if total == 0 {
            0.0
        } else {
            ((s.mismatched as f64 / total as f64) * 1000.0).round() / 1000.0
        };
    }

    // Short opposite-sign bursts in the raw stream are the hardware/encoder
    // signature. We never auto-correct these — they need a physical check.
    let mut noisy = 0u32;
    let mut burst_count = 0u32;
    let mut isolated_reversals = 0u32;
    let mut by_stream: HashMap<(String, String), Vec<&ScrollEvent>> = HashMap::new();
    for &(_, r) in &raw {
        by_stream
            .entry((r.device.clone(), r.axis.clone()))
            .or_default()
            .push(r);
    }
    for ((_device, _axis), list) in &mut by_stream {
        list.sort_by_key(|e| e.t_ms);
        let mut burst_sign = 0i32;
        let mut last_t = 0u128;
        for e in list.iter() {
            if burst_sign == 0 || e.t_ms.saturating_sub(last_t) > BURST_PAUSE_MS {
                burst_count += 1;
                burst_sign = sign(e.delta);
            } else if sign(e.delta) != 0 && sign(e.delta) != burst_sign {
                isolated_reversals += 1;
            }
            last_t = e.t_ms;
        }
        for pair in list.windows(2) {
            let (a, b) = (pair[0], pair[1]);
            if sign(a.delta) != 0
                && sign(a.delta) == -sign(b.delta)
                && b.t_ms.saturating_sub(a.t_ms) <= NOISE_WINDOW_MS
                && a.delta.abs() <= NOISE_MAX_ABS_DELTA
                && b.delta.abs() <= NOISE_MAX_ABS_DELTA
            {
                noisy += 1;
                stats_for(&mut devices, a).noisy += 1;
            }
        }
    }

    let total = matched + mismatched;
    let mismatch_rate = if total == 0 {
        0.0
    } else {
        mismatched as f64 / total as f64
    };
    let identified_raw = raw.iter().filter(|(_, r)| r.identified).count();
    let physical_sample = raw.len() > 0
        && identified_raw > 0
        && raw.iter().all(|(_, r)| !r.injected)
        && injected_events == 0;

    let mut conclusions = Vec::new();
    let direction_checked = !expect.is_empty() && expected_checked > 0;
    if raw.is_empty() {
        conclusions.push("No Raw Input wheel data captured. Either no wheel was turned, or raw input registration failed; this sample is inconclusive.".to_string());
    } else if direction_checked {
        if unexpected_direction > 0 {
            if mismatched == 0 {
                conclusions.push("Unexpected direction is already present in Raw Input: raw and WM agree with each other, so the sign is wrong before WM_MOUSEWHEEL. Look at the device, firmware, HID driver or an earlier input layer rather than at an app-level hook.".to_string());
            } else {
                conclusions.push("Unexpected direction plus a cross-layer mismatch: Raw Input is wrong in places and WM does not consistently match it. Check both the device/driver and software hooks.".to_string());
            }
        } else if mismatched > 0 {
            conclusions.push("Cross-layer mismatch detected: Raw Input follows the expected direction but WM_MOUSEWHEEL is flipped. A software hook/filter is the likely cause.".to_string());
        } else {
            conclusions.push("No direction anomaly detected: every raw event matched the expected schedule and WM matched Raw Input.".to_string());
        }
        if noisy >= 3 {
            conclusions.push("Raw Input also contains short alternating-sign bursts, which supports encoder/USB noise in addition to wrong-direction events.".to_string());
        }
    } else if mismatched >= 3 && mismatch_rate >= 0.5 {
        conclusions.push("Sign is flipped between HID Raw Input and WM_MOUSEWHEEL. The device data is consistent but something in the Windows input/hook chain inverts it (G HUB, cafe client, or another hook).".to_string());
    } else if noisy >= 3 {
        conclusions.push("Raw Input itself contains short alternating-sign bursts. Suspect a noisy encoder, a duplicate pointing device, or a flaky USB receiver rather than Windows.".to_string());
    } else if total == 0 {
        conclusions.push("Raw Input and WM_MOUSEWHEEL events did not line up in time. Scroll longer, or try again with the window focused.".to_string());
    } else if mismatch_rate > 0.0 {
        conclusions.push("Only a few inverted events were seen. The fault is likely intermittent; capture for longer before enabling correction.".to_string());
    } else {
        conclusions.push("No inversion in this sample. The symptom is intermittent or specific to one application; repeat the capture while it happens.".to_string());
    }
    if direction_checked {
        conclusions.push(format!(
            "Direction check: down {}/{} wrong, up {}/{} wrong, {} events outside the declared windows.",
            expected_down_error, expected_down_total, expected_up_error, expected_up_total, outside_expect_events
        ));
    }

    let mut warnings = Vec::new();
    if injected_events > 0 {
        warnings.push(format!(
            "{} WM wheel events are marked LLMHF_INJECTED (synthetic input). This sample cannot prove a physical mouse fault.",
            injected_events
        ));
    }
    if identified_raw == 0 && !raw.is_empty() {
        warnings.push("No raw event resolved a HID device path (all show unknown-hid). Injected/virtual input is likely; repeat with a physical mouse.".to_string());
    }
    if !expect.is_empty() && expected_checked == 0 {
        warnings.push("The expected-direction windows did not overlap any raw events; check the --expect seconds.".to_string());
    }
    if outside_expect_events > 0 {
        warnings.push(format!(
            "{} raw wheel events happened outside the declared expect windows (during rest). Confirm you really stopped scrolling; otherwise the device is sending input on its own.",
            outside_expect_events
        ));
    }

    let mut device_list: Vec<DeviceStats> = devices.into_values().collect();
    device_list.sort_by(|a, b| {
        let count = |s: &DeviceStats| s.raw_up + s.raw_down + s.wm_up + s.wm_down;
        count(b).cmp(&count(a))
    });

    Analysis {
        raw_events: raw.len(),
        wm_events: wm.len(),
        matched,
        mismatched,
        mismatch_rate: (mismatch_rate * 1000.0).round() / 1000.0,
        noisy_candidates: noisy,
        injected_events,
        burst_count,
        isolated_reversals,
        expected_windows: expect.len(),
        expected_checked,
        unexpected_direction,
        expected_down_total,
        expected_down_error,
        expected_up_total,
        expected_up_error,
        outside_expect_events,
        physical_sample,
        conclusions,
        warnings,
        devices: device_list,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event(t_ms: u128, layer: &str, device: &str, delta: i32) -> ScrollEvent {
        ScrollEvent {
            t_ms,
            layer: layer.to_string(),
            device: device.to_string(),
            delta,
            axis: "vertical".to_string(),
            injected: false,
            identified: device.starts_with(r"\\?\HID"),
            vid_pid: if device.starts_with(r"\\?\HID") {
                "VID_046D&PID_C08F".to_string()
            } else {
                String::new()
            },
        }
    }

    fn windows() -> Vec<ExpectWindow> {
        vec![
            ExpectWindow {
                direction: "down".to_string(),
                sign: -1,
                start_ms: 0,
                end_ms: 6000,
            },
            ExpectWindow {
                direction: "up".to_string(),
                sign: 1,
                start_ms: 8000,
                end_ms: 12000,
            },
        ]
    }

    #[test]
    fn raw_and_wm_both_wrong_is_not_cross_layer_mismatch() {
        // Operator scrolled down, but raw and WM both say up.
        let events = vec![
            event(1000, "raw", r"\\?\HID#VID_046D&PID_C08F", 120),
            event(1000, "wm", "hook", 120),
        ];
        let a = analyze(&events, &windows());
        assert_eq!(a.mismatched, 0);
        assert_eq!(a.unexpected_direction, 1);
        assert!(a.conclusions[0].contains("already present in Raw Input"));
        assert!(!a.conclusions[0].contains("Cross-layer"));
    }

    #[test]
    fn raw_expected_but_wm_flipped_is_cross_layer() {
        let events = vec![
            event(1000, "raw", r"\\?\HID#VID_046D&PID_C08F", -120),
            event(1000, "wm", "hook", 120),
        ];
        let a = analyze(&events, &windows());
        assert_eq!(a.mismatched, 1);
        assert_eq!(a.unexpected_direction, 0);
        assert!(a.conclusions[0].contains("Cross-layer mismatch"));
    }

    #[test]
    fn events_in_rest_window_are_counted_and_warned() {
        let events = vec![event(7000, "raw", r"\\?\HID#VID_046D&PID_C08F", -120)];
        let a = analyze(&events, &windows());
        assert_eq!(a.outside_expect_events, 1);
        assert!(a.warnings.iter().any(|w| w.contains("outside the declared expect")));
    }

    #[test]
    fn per_direction_errors_are_separated() {
        let events = vec![
            event(1000, "raw", r"\\?\HID#VID_046D&PID_C08F", 120), // down window, wrong
            event(2000, "raw", r"\\?\HID#VID_046D&PID_C08F", -120), // down window, right
            event(9000, "raw", r"\\?\HID#VID_046D&PID_C08F", -120), // up window, wrong
        ];
        let a = analyze(&events, &windows());
        assert_eq!(a.expected_down_total, 2);
        assert_eq!(a.expected_down_error, 1);
        assert_eq!(a.expected_up_total, 1);
        assert_eq!(a.expected_up_error, 1);
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CorrectionConfig {
    pub version: u32,
    pub enabled: bool,
    pub mode: String,
    pub invert_vertical: bool,
    pub invert_horizontal: bool,
    pub adaptive_window_ms: u128,
    pub adaptive_min_votes: usize,
}

impl Default for CorrectionConfig {
    fn default() -> Self {
        Self {
            version: 1,
            enabled: false,
            mode: "static".to_string(),
            invert_vertical: false,
            invert_horizontal: false,
            adaptive_window_ms: 500,
            adaptive_min_votes: 3,
        }
    }
}

/// Stateful decision maker used by the WH_MOUSE_LL callback.
pub struct Corrector {
    pub config: CorrectionConfig,
    recent: Vec<(u128, i32)>,
}

impl Corrector {
    pub fn new(config: CorrectionConfig) -> Self {
        Self {
            config,
            recent: Vec::new(),
        }
    }

    /// Returns the corrected delta when this event should be flipped.
    pub fn decide(&mut self, delta: i32, axis: &str, t_ms: u128) -> Option<i32> {
        if !self.config.enabled {
            return None;
        }
        let vertical = axis == "vertical";
        if !(vertical && self.config.invert_vertical) && !(!vertical && self.config.invert_horizontal) {
            return None;
        }

        if self.config.mode == "adaptive" {
            self.recent
                .retain(|(t, _)| t_ms.saturating_sub(*t) <= self.config.adaptive_window_ms);
            let votes = self.recent.iter().filter(|(_, d)| sign(*d) == sign(delta)).count();
            let against = self.recent.len() - votes;
            self.recent.push((t_ms, delta));
            // Only flip a lone outlier that contradicts a clear recent trend.
            if votes >= self.config.adaptive_min_votes || against < 2 {
                return None;
            }
        }
        Some(-delta)
    }
}
