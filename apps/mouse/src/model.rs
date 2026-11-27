//! Event model, anomaly analysis and correction rules for the mouse wheel tool.
//!
//! No Windows API calls live here so the decision logic stays easy to reason
//! about (and can be unit tested later without a message loop).

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

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
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct DeviceStats {
    pub device: String,
    pub raw_up: u32,
    pub raw_down: u32,
    pub wm_up: u32,
    pub wm_down: u32,
    pub matched: u32,
    pub mismatched: u32,
    pub noisy: u32,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct Analysis {
    pub raw_events: usize,
    pub wm_events: usize,
    pub matched: u32,
    pub mismatched: u32,
    pub mismatch_rate: f64,
    pub noisy_candidates: u32,
    pub conclusion: String,
    pub devices: Vec<DeviceStats>,
}

/// Max distance between a Raw Input wheel event and the WM_* event it produced.
const CORRELATION_MS: u128 = 150;
/// Two opposite-sign raw events closer than this are a noise candidate only
/// when they are small (one notch) — a deliberate reversal is usually slower.
const NOISE_WINDOW_MS: u128 = 80;
const NOISE_MAX_ABS_DELTA: i32 = 120;

fn sign(delta: i32) -> i32 {
    if delta > 0 {
        1
    } else if delta < 0 {
        -1
    } else {
        0
    }
}

fn stats_for<'a>(map: &'a mut HashMap<String, DeviceStats>, device: &str) -> &'a mut DeviceStats {
    map.entry(device.to_string()).or_insert_with(|| DeviceStats {
        device: device.to_string(),
        ..Default::default()
    })
}

pub fn analyze(events: &[ScrollEvent]) -> Analysis {
    let mut devices: HashMap<String, DeviceStats> = HashMap::new();
    let mut raw: Vec<(usize, &ScrollEvent)> = Vec::new();
    let mut wm: Vec<&ScrollEvent> = Vec::new();

    for (i, e) in events.iter().enumerate() {
        if e.layer == "raw" {
            raw.push((i, e));
            let s = stats_for(&mut devices, &e.device);
            if e.delta > 0 {
                s.raw_up += 1;
            } else if e.delta < 0 {
                s.raw_down += 1;
            }
        } else if e.layer == "wm" {
            wm.push(e);
            let s = stats_for(&mut devices, &e.device);
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
            let s = stats_for(&mut devices, &r.device);
            if sign(r.delta) == sign(w.delta) {
                matched += 1;
                s.matched += 1;
            } else {
                mismatched += 1;
                s.mismatched += 1;
            }
        }
    }

    // Short opposite-sign bursts in the raw stream are the hardware/encoder
    // signature. We never auto-correct these — they need a physical check.
    let mut noisy = 0u32;
    let mut by_stream: HashMap<(String, String), Vec<&ScrollEvent>> = HashMap::new();
    for &(_, r) in &raw {
        by_stream
            .entry((r.device.clone(), r.axis.clone()))
            .or_default()
            .push(r);
    }
    for ((device, _axis), list) in &mut by_stream {
        list.sort_by_key(|e| e.t_ms);
        for pair in list.windows(2) {
            let (a, b) = (pair[0], pair[1]);
            if sign(a.delta) != 0
                && sign(a.delta) == -sign(b.delta)
                && b.t_ms.saturating_sub(a.t_ms) <= NOISE_WINDOW_MS
                && a.delta.abs() <= NOISE_MAX_ABS_DELTA
                && b.delta.abs() <= NOISE_MAX_ABS_DELTA
            {
                noisy += 1;
                stats_for(&mut devices, device).noisy += 1;
            }
        }
    }

    let total = matched + mismatched;
    let mismatch_rate = if total == 0 {
        0.0
    } else {
        mismatched as f64 / total as f64
    };

    let conclusion = if raw.is_empty() {
        "No Raw Input wheel data captured. Either no wheel was turned, or raw input registration failed; this sample is inconclusive."
    } else if mismatched >= 3 && mismatch_rate >= 0.5 {
        "Sign is flipped between HID Raw Input and WM_MOUSEWHEEL. The device data is consistent but something in the Windows input/hook chain inverts it (G HUB, cafe client, or another hook)."
    } else if noisy >= 3 {
        "Raw Input itself contains short alternating-sign bursts. Suspect a noisy encoder, a duplicate pointing device, or a flaky USB receiver rather than Windows."
    } else if total == 0 {
        "Raw Input and WM_MOUSEWHEEL events did not line up in time. Scroll longer, or try again with the window focused."
    } else if mismatch_rate > 0.0 {
        "Only a few inverted events were seen. The fault is likely intermittent; capture for longer before enabling correction."
    } else {
        "No inversion in this sample. The symptom is intermittent or specific to one application; repeat the capture while it happens."
    };

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
        conclusion: conclusion.to_string(),
        devices: device_list,
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
