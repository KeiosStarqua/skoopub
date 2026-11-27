//! skoopub mouse — wheel diagnostics and correction.
//!
//! Captures the same wheel notch at two layers at once:
//!   * HID Raw Input (WM_INPUT)  — what the device/driver actually reported
//!   * WM_MOUSEWHEEL via WH_MOUSE_LL — what applications will receive
//!
//! Comparing the two tells us whether an inverted scroll comes from the
//! hardware/driver (raw data is wrong) or from a software hook between raw
//! input and window messages (raw is fine, WM is flipped).

mod model;

use model::{analyze, Analysis, CorrectionConfig, Corrector, ExpectWindow, ScrollEvent};
use std::collections::HashMap;
use std::env;
use std::ffi::c_void;
use std::fs;
use std::io::Write;
use std::mem;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::ptr;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use windows::core::w;
use windows::Win32::Foundation::{HANDLE, HINSTANCE, HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::System::Diagnostics::Debug::MessageBeep;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Input::{
    GetRawInputData, GetRawInputDeviceInfoW, RegisterRawInputDevices, HRAWINPUT, RAWINPUTDEVICE,
    RAWINPUTDEVICE_FLAGS, RAWINPUTHEADER, RAW_INPUT_DATA_COMMAND_FLAGS,
    RAW_INPUT_DEVICE_INFO_COMMAND,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CallNextHookEx, CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW, HHOOK,
    PeekMessageW, RegisterClassW, SetWindowsHookExW, UnhookWindowsHookEx, MSLLHOOKSTRUCT, MSG,
    MB_ICONEXCLAMATION, MB_ICONINFORMATION, PEEK_MESSAGE_REMOVE_TYPE, WH_MOUSE_LL, WINDOW_EX_STYLE,
    WINDOW_STYLE, WNDCLASSW, WNDCLASS_STYLES, WM_INPUT, WM_MOUSEHWHEEL, WM_MOUSEWHEEL, WM_QUIT,
};

const WINDOW_CLASS: windows::core::PCWSTR = w!("SkoopubMouseRawInput");
const RID_INPUT: RAW_INPUT_DATA_COMMAND_FLAGS = RAW_INPUT_DATA_COMMAND_FLAGS(0x10000003);
const RIDI_DEVICENAME: RAW_INPUT_DEVICE_INFO_COMMAND = RAW_INPUT_DEVICE_INFO_COMMAND(0x20000007);
const RIDEV_INPUTSINK: RAWINPUTDEVICE_FLAGS = RAWINPUTDEVICE_FLAGS(0x00000100);
const PM_REMOVE: PEEK_MESSAGE_REMOVE_TYPE = PEEK_MESSAGE_REMOVE_TYPE(0x00000001);
const RIM_TYPEMOUSE: u32 = 0;
const RI_MOUSE_WHEEL: u16 = 0x0400;
const RI_MOUSE_HWHEEL: u16 = 0x0C00;
const LLMHF_INJECTED: u32 = 0x00000010;

struct State {
    started: Instant,
    events: Vec<ScrollEvent>,
    device_names: HashMap<isize, (String, bool, String)>,
    corrector: Option<Corrector>,
    monitor: bool,
    printed: usize,
    hook_calls: u32,
    raw_calls: u32,
    debug_raw: bool,
    debug_printed: usize,
    expect: Vec<ExpectWindow>,
    cues: bool,
    // Stored as raw addresses: windows-rs handle types are !Send, and the
    // shared state must be Sync for the static Mutex.
    hook: Option<isize>,
    window: Option<isize>,
    dry_run: bool,
}

impl Default for State {
    fn default() -> Self {
        Self {
            started: Instant::now(),
            events: Vec::new(),
            device_names: HashMap::new(),
            corrector: None,
            monitor: false,
            printed: 0,
            hook_calls: 0,
            raw_calls: 0,
            debug_raw: false,
            debug_printed: 0,
            expect: Vec::new(),
            cues: false,
            hook: None,
            window: None,
            dry_run: false,
        }
    }
}

static STATE: OnceLock<Mutex<State>> = OnceLock::new();

fn state() -> &'static Mutex<State> {
    STATE.get_or_init(|| Mutex::new(State::default()))
}

fn app_dir() -> PathBuf {
    let base = env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .or_else(|| {
            env::var_os("USERPROFILE")
                .map(|p| PathBuf::from(p).join("AppData").join("Local"))
        })
        .unwrap_or_else(|| PathBuf::from("."));
    base.join("skoop").join("mouse")
}

fn report_path() -> PathBuf {
    app_dir().join("scroll-report.json")
}

fn config_path() -> PathBuf {
    app_dir().join("config.json")
}

fn pid_path() -> PathBuf {
    app_dir().join("mouse.pid")
}

fn unix_ms() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
}

fn write_json(path: &Path, value: &impl serde::Serialize) -> std::io::Result<()> {
    let _ = fs::create_dir_all(path.parent().unwrap_or_else(|| Path::new(".")));
    let text = serde_json::to_string_pretty(value).unwrap_or_else(|_| "{}".to_string());
    fs::write(path, text.as_bytes())
}

fn option(args: &[String], name: &str) -> Option<String> {
    let exact = format!("--{}", name);
    let prefix = format!("--{}=", name);
    for (i, arg) in args.iter().enumerate() {
        if arg == &exact {
            return args.get(i + 1).cloned();
        }
        if let Some(value) = arg.strip_prefix(&prefix) {
            return Some(value.to_string());
        }
    }
    None
}

fn flag(args: &[String], name: &str) -> bool {
    args.iter().any(|a| a == &format!("--{}", name))
}

/// Pull a 4-hex-digit value following a marker such as `VID_` from an HID path.
fn hex_after(name: &str, marker: &str) -> Option<String> {
    let upper = name.to_uppercase();
    let start = upper.find(marker)? + marker.len();
    let value: String = upper[start..].chars().take(4).collect();
    if value.len() == 4 && value.chars().all(|c| c.is_ascii_hexdigit()) {
        Some(value)
    } else {
        None
    }
}

/// Resolve an HID device path plus a `VID_xxxx&PID_xxxx` summary.
/// `(name, identified, vid_pid)`; `identified` is false for injected/virtual
/// devices whose path Windows cannot report.
fn device_name(
    handle: HANDLE,
    cache: &mut HashMap<isize, (String, bool, String)>,
) -> (String, bool, String) {
    let key = handle.0 as isize;
    if let Some(cached) = cache.get(&key) {
        return cached.clone();
    }
    let mut size = 0u32;
    unsafe {
        let _ = GetRawInputDeviceInfoW(Some(handle), RIDI_DEVICENAME, None, &mut size);
    }
    let (name, identified) = if size > 0 && size < 4096 {
        // The first call may report either bytes or WCHARs depending on the
        // RIDI_* command. Overallocate and pass the real byte capacity so a
        // long physical HID path can never overflow the buffer.
        let mut buffer = vec![0u16; size as usize + 4];
        let mut capacity = (buffer.len() * mem::size_of::<u16>()) as u32;
        unsafe {
            GetRawInputDeviceInfoW(
                Some(handle),
                RIDI_DEVICENAME,
                Some(buffer.as_mut_ptr() as *mut c_void),
                &mut capacity,
            );
        }
        // The buffer is zero-filled and over-sized; read up to the first NUL
        // instead of trusting the return value's units.
        let raw = String::from_utf16_lossy(&buffer)
            .trim_end_matches('\0')
            .to_string();
        let identified = !raw.is_empty()
            && raw.to_uppercase().contains("VID_")
            && raw.to_uppercase().contains("PID_");
        (raw, identified)
    } else {
        ("unknown-hid".to_string(), false)
    };
    let vid_pid = match (hex_after(&name, "VID_"), hex_after(&name, "PID_")) {
        (Some(vid), Some(pid)) => format!("VID_{}&PID_{}", vid, pid),
        _ => String::new(),
    };
    let result = (name.clone(), identified, vid_pid);
    cache.insert(key, result.clone());
    result
}

/// Parse `--expect down@0-25,up@30-55` (seconds from capture start).
fn parse_expect(spec: &str) -> Vec<ExpectWindow> {
    let mut windows = Vec::new();
    for part in spec.split(',') {
        let (direction, range) = match part.split_once('@') {
            Some(pair) => pair,
            None => continue,
        };
        let sign = match direction.trim().to_ascii_lowercase().as_str() {
            "up" => 1,
            "down" => -1,
            _ => continue,
        };
        let (start, end) = match range.split_once('-') {
            Some(pair) => pair,
            None => continue,
        };
        if let (Ok(start), Ok(end)) = (start.trim().parse::<u64>(), end.trim().parse::<u64>()) {
            windows.push(ExpectWindow {
                direction: direction.trim().to_ascii_lowercase(),
                sign,
                start_ms: start as u128 * 1000,
                end_ms: end as u128 * 1000,
            });
        }
    }
    windows
}

unsafe fn read_u16_at(base: *const u8, offset: usize) -> u16 {
    ptr::read_unaligned(base.add(offset) as *const u16)
}

unsafe fn read_i16_at(base: *const u8, offset: usize) -> i16 {
    ptr::read_unaligned(base.add(offset) as *const i16)
}

/// WM_INPUT: decode the RAWMOUSE wheel usage and store it with its HID path.
unsafe fn handle_raw_input(lparam: LPARAM) {
    if let Ok(mut guard) = state().lock() {
        guard.raw_calls += 1;
    }
    let hraw = HRAWINPUT(lparam.0 as *mut c_void);
    let mut size = 0u32;
    let header_size = mem::size_of::<RAWINPUTHEADER>() as u32;
    // With pData = NULL the function writes the required size into `size`
    // (and may return either 0 or that size depending on OS version).
    let _ = GetRawInputData(hraw, RID_INPUT, None, &mut size, header_size);
    if size == 0 || size > 4096 {
        return;
    }
    let mut buffer = vec![0u8; size as usize];
    let mut copied = buffer.len() as u32;
    let read = GetRawInputData(
        hraw,
        RID_INPUT,
        Some(buffer.as_mut_ptr() as *mut c_void),
        &mut copied,
        header_size,
    );
    if read == 0 || copied as usize > buffer.len() {
        return;
    }
    // A mouse RAWMOUSE needs at least usButtonFlags (+4) and usButtonData (+6)
    // after the header. Never read past the buffer even if Windows reports a
    // short struct for an unexpected device.
    if buffer.len() < header_size as usize + 8 {
        return;
    }
    let header = ptr::read_unaligned(buffer.as_ptr() as *const RAWINPUTHEADER);
    let debug = state().lock().map(|g| g.debug_raw).unwrap_or(false);
    if debug {
        let mut guard = state().lock().unwrap();
        if guard.debug_printed < 8 {
            guard.debug_printed += 1;
            let hex = buffer
                .iter()
                .take(64)
                .map(|b| format!("{:02x}", b))
                .collect::<Vec<_>>()
                .join(" ");
            println!(
                "RAWBUF#{} dwType={} size={} : {}",
                guard.debug_printed, header.dwType, size, hex
            );
        }
    }
    if header.dwType != RIM_TYPEMOUSE {
        return;
    }
    // RAWMOUSE starts right after RAWINPUTHEADER:
    // usFlags +0, ulButtons union +4 => usButtonFlags +4, usButtonData +6.
    let mouse = buffer.as_ptr().add(header_size as usize);
    let buttons = read_u16_at(mouse, 4);
    let (axis, raw_delta) = if buttons & RI_MOUSE_WHEEL != 0 {
        ("vertical", read_i16_at(mouse, 6) as i32)
    } else if buttons & RI_MOUSE_HWHEEL != 0 {
        ("horizontal", read_i16_at(mouse, 6) as i32)
    } else {
        return;
    };
    if raw_delta == 0 {
        return;
    }

    let mut guard = match state().lock() {
        Ok(g) => g,
        Err(_) => return,
    };
    let t_ms = guard.started.elapsed().as_millis();
    let (device, identified, vid_pid) = device_name(header.hDevice, &mut guard.device_names);
    guard.events.push(ScrollEvent {
        t_ms,
        layer: "raw".to_string(),
        device,
        delta: raw_delta,
        axis: axis.to_string(),
        injected: false,
        identified,
        vid_pid,
    });
}

unsafe extern "system" fn wnd_proc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    if msg == WM_INPUT {
        handle_raw_input(lparam);
        return LRESULT(0);
    }
    DefWindowProcW(hwnd, msg, wparam, lparam)
}

/// WH_MOUSE_LL: see (and optionally flip) WM_MOUSEWHEEL before the target window.
unsafe extern "system" fn mouse_hook(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code >= 0 {
        if let Ok(mut guard) = state().lock() {
            guard.hook_calls += 1;
        }
        let message = wparam.0 as u32;
        if message == WM_MOUSEWHEEL || message == WM_MOUSEHWHEEL {
            let data = lparam.0 as *mut MSLLHOOKSTRUCT;
            if !data.is_null() {
                let entry = &mut *data;
                let injected = entry.flags & LLMHF_INJECTED != 0;
                let delta = (entry.mouseData >> 16) as i16 as i32;
                let axis = if message == WM_MOUSEWHEEL {
                    "vertical"
                } else {
                    "horizontal"
                };
                let mut new_delta = None;
                if let Ok(mut guard) = state().lock() {
                    let t_ms = guard.started.elapsed().as_millis();
                    guard.events.push(ScrollEvent {
                        t_ms,
                        layer: "wm".to_string(),
                        device: if injected { "hook-injected" } else { "hook" }.to_string(),
                        delta,
                        axis: axis.to_string(),
                        injected,
                        identified: false,
                        vid_pid: String::new(),
                    });
                    // Never feed injected input into correction: that would
                    // create a feedback loop with our own (or another) tool.
                    if !injected && !guard.dry_run {
                        if let Some(corrector) = guard.corrector.as_mut() {
                            new_delta = corrector.decide(delta, axis, t_ms);
                        }
                    }
                }
                if let Some(fixed) = new_delta {
                    // Low-level hooks may edit MSLLHOOKSTRUCT in place; the
                    // changed value flows to the rest of the hook chain.
                    entry.mouseData = ((fixed as u16 as u32) << 16) | (entry.mouseData & 0xFFFF);
                }
            }
        }
    }
    CallNextHookEx(None, code, wparam, lparam)
}

fn init_capture() -> windows::core::Result<()> {
    let hmodule = unsafe { GetModuleHandleW(None)? };
    let hinst: HINSTANCE = hmodule.into();
    let class = WNDCLASSW {
        style: WNDCLASS_STYLES(0),
        lpfnWndProc: Some(wnd_proc),
        hInstance: hinst,
        lpszClassName: WINDOW_CLASS,
        ..Default::default()
    };
    unsafe {
        RegisterClassW(&class); // ERROR_CLASS_ALREADY_EXISTS is fine on a re-run.
    }
    // HWND_MESSAGE (-3): a message-only window, invisible and unpainted.
    let message_only = HWND(-3isize as *mut c_void);
    let window = unsafe {
        CreateWindowExW(
            WINDOW_EX_STYLE(0),
            WINDOW_CLASS,
            w!(""),
            WINDOW_STYLE(0),
            0,
            0,
            0,
            0,
            Some(message_only),
            None,
            Some(hinst),
            None,
        )?
    };
    let device = RAWINPUTDEVICE {
        usUsagePage: 1, // HID_USAGE_PAGE_GENERIC
        usUsage: 2,     // HID_USAGE_GENERIC_MOUSE
        dwFlags: RIDEV_INPUTSINK,
        hwndTarget: window,
    };
    unsafe { RegisterRawInputDevices(&[device], mem::size_of::<RAWINPUTDEVICE>() as u32)? };
    let hook = unsafe { SetWindowsHookExW(WH_MOUSE_LL, Some(mouse_hook), Some(hinst), 0)? };

    let mut guard = state().lock().unwrap();
    guard.window = Some(window.0 as isize);
    guard.hook = Some(hook.0 as isize);
    Ok(())
}

fn cleanup() {
    let (hook, window) = {
        let guard = state().lock().unwrap();
        (guard.hook, guard.window)
    };
    if let Some(hook) = hook {
        unsafe {
            let _ = UnhookWindowsHookEx(HHOOK(hook as *mut c_void));
        }
    }
    if let Some(window) = window {
        unsafe {
            let _ = DestroyWindow(HWND(window as *mut c_void));
        }
    }
}

fn pump(seconds: Option<u64>) {
    let deadline = seconds.map(|s| Instant::now() + Duration::from_secs(s));
    let (started, cues) = {
        let guard = state().lock().unwrap();
        (guard.started, guard.cues)
    };
    // Protocol cues: low beep = start scrolling down, high = rest, low =
    // start scrolling up, high = rest again.
    let cue_times = [0u64, 25, 30, 55];
    let mut cue_index = 0usize;
    let mut msg = MSG::default();
    loop {
        if cues && cue_index < cue_times.len() && started.elapsed().as_secs() >= cue_times[cue_index] {
            let beep = if cue_index % 2 == 0 {
                MB_ICONEXCLAMATION
            } else {
                MB_ICONINFORMATION
            };
            unsafe {
                let _ = MessageBeep(beep);
            }
            cue_index += 1;
        }
        if let Some(deadline) = deadline {
            if Instant::now() >= deadline {
                break;
            }
        }
        while unsafe { PeekMessageW(&mut msg, None, 0, 0, PM_REMOVE) }.as_bool() {
            if msg.message == WM_QUIT {
                return;
            }
            unsafe {
                DispatchMessageW(&msg);
            }
        }
        // Monitor mode streams new events while the capture is still running.
        let (monitor, pending) = {
            let mut guard = state().lock().unwrap();
            let pending: Vec<ScrollEvent> = if guard.monitor {
                guard.events[guard.printed..].to_vec()
            } else {
                Vec::new()
            };
            guard.printed += pending.len();
            (guard.monitor, pending)
        };
        if monitor {
            for event in pending {
                if let Ok(line) = serde_json::to_string(&event) {
                    println!("{}", line);
                    let _ = std::io::stdout().flush();
                }
            }
        }
        std::thread::sleep(Duration::from_millis(8));
    }
}

#[derive(serde::Deserialize)]
struct SavedReport {
    analysis: Analysis,
}

#[derive(serde::Serialize)]
struct Report {
    tool: &'static str,
    mode: String,
    started_unix_ms: u128,
    duration_ms: u128,
    hook_calls: u32,
    raw_calls: u32,
    expect: Vec<ExpectWindow>,
    analysis: Analysis,
    events: Vec<ScrollEvent>,
    note: String,
}

fn run_capture(args: &[String], monitor: bool) -> Result<(), String> {
    let seconds = option(args, "seconds")
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(30);
    {
        let mut guard = state().lock().unwrap();
        guard.monitor = monitor;
        guard.corrector = None;
        guard.debug_raw = flag(args, "debug-raw");
        guard.debug_printed = 0;
        guard.expect = option(args, "expect")
            .map(|s| parse_expect(&s))
            .unwrap_or_default();
        guard.cues = flag(args, "cues");
    }
    let expect = state().lock().unwrap().expect.clone();
    init_capture().map_err(|e| format!("could not register raw input or the mouse hook: {e}"))?;
    println!(
        "capturing for {}s — turn the wheel normally, then reverse it a few times...",
        seconds
    );

    pump(Some(seconds));
    let started = state().lock().unwrap().started;
    let (events, hook_calls, raw_calls) = {
        let guard = state().lock().unwrap();
        (guard.events.clone(), guard.hook_calls, guard.raw_calls)
    };
    let analysis = analyze(&events, &expect);
    let report = Report {
        tool: "skoopub-mouse",
        mode: if monitor { "monitor" } else { "diagnose" }.to_string(),
        started_unix_ms: unix_ms() - started.elapsed().as_millis(),
        duration_ms: started.elapsed().as_millis(),
        hook_calls,
        raw_calls,
        expect,
        analysis,
        events: if monitor { Vec::new() } else { events },
        note: "Positive delta = up/away. Compare `raw` (HID) with `wm` (what apps receive). `injected=true` marks synthetic input (LLMHF_INJECTED).".to_string(),
    };
    let path = option(args, "out")
        .map(PathBuf::from)
        .unwrap_or_else(report_path);
    write_json(&path, &report).map_err(|e| format!("could not write {}: {e}", path.display()))?;
    println!("{}", serde_json::to_string_pretty(&report).unwrap());
    println!("report written to {}", path.display());
    cleanup();
    Ok(())
}

fn load_config() -> CorrectionConfig {
    fs::read_to_string(config_path())
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

fn save_config(config: &CorrectionConfig) -> Result<(), String> {
    write_json(&config_path(), config)
        .map_err(|e| format!("could not write {}: {e}", config_path().display()))
}

fn run_fix(args: &[String]) -> Result<(), String> {
    let mut config = load_config();
    let report_file = option(args, "from").map(PathBuf::from).unwrap_or_else(report_path);
    if let Ok(text) = fs::read_to_string(&report_file) {
        if let Ok(saved) = serde_json::from_str::<SavedReport>(&text) {
            let a = saved.analysis;
            let confident = a.mismatched >= 5 && a.mismatch_rate >= 0.6;
            config.invert_vertical = confident && a.wm_events > 0;
            config.invert_horizontal = false;
            if confident {
                println!(
                    "calibration from {}: {}/{} inverted (rate {:.2}) — flipping vertical wheel",
                    report_file.display(),
                    a.mismatched,
                    a.matched + a.mismatched,
                    a.mismatch_rate
                );
            } else {
                println!(
                    "{} is not conclusive ({} inverted of {} correlated); no inversion enabled. Use --force to override.",
                    report_file.display(),
                    a.mismatched,
                    a.matched + a.mismatched
                );
            }
        }
    } else {
        println!(
            "no report at {} — run `mouse diagnose` first, or use --force",
            report_file.display()
        );
    }
    if flag(args, "force") {
        config.invert_vertical = true;
    }
    if flag(args, "adaptive") {
        config.mode = "adaptive".to_string();
    } else {
        config.mode = "static".to_string();
    }
    config.enabled = true;
    save_config(&config)?;

    let dry_run = flag(args, "dry-run");
    {
        let mut guard = state().lock().unwrap();
        guard.corrector = Some(Corrector::new(config.clone()));
        guard.dry_run = dry_run;
    }
    init_capture().map_err(|e| format!("could not register raw input or the mouse hook: {e}"))?;
    let pid = std::process::id();
    let _ = fs::create_dir_all(app_dir());
    let _ = fs::write(pid_path(), pid.to_string());
    println!(
        "correction active (pid {}, mode {}, dry-run={}). Run `mouse restore` to stop.",
        pid, config.mode, dry_run
    );
    pump(None); // runs until restore kills this process
    cleanup();
    Ok(())
}

fn running_pid() -> Option<u32> {
    fs::read_to_string(pid_path())
        .ok()
        .and_then(|s| s.trim().parse::<u32>().ok())
}

fn run_restore() -> Result<(), String> {
    if let Some(pid) = running_pid() {
        let status = std::process::Command::new("taskkill")
            .args(["/PID", &pid.to_string(), "/F"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
        match status {
            Ok(s) if s.success() => println!("stopped correction process {}", pid),
            Ok(_) => println!("process {} was not running (already stopped?)", pid),
            Err(e) => println!("could not stop {}: {e}", pid),
        }
    } else {
        println!("no correction process recorded");
    }
    let _ = fs::remove_file(pid_path());
    let mut config = load_config();
    config.enabled = false;
    save_config(&config)?;
    println!("correction disabled; config kept at {}", config_path().display());
    Ok(())
}

fn run_status() {
    let config = load_config();
    let status = serde_json::json!({
        "running": running_pid().is_some(),
        "pid": running_pid(),
        "config": config,
        "report": report_path().to_string_lossy(),
    });
    println!("{}", serde_json::to_string_pretty(&status).unwrap());
}

fn usage() {
    println!(
        "skoopub-mouse — mouse wheel diagnostics and correction\n\n\
Usage:\n\
  skoopub-mouse diagnose [--seconds 30] [--out <path>] [--debug-raw] [--cues]\n\
                         [--expect down@0-25,up@30-55]\n\
  skoopub-mouse monitor  [--seconds 30]\n\
  skoopub-mouse fix [--adaptive] [--dry-run] [--from <report>] [--force]\n\
  skoopub-mouse restore\n\
  skoopub-mouse status\n\n\
--expect gives windows (seconds from start) where you scroll down/up, so the\n\
report can count events that contradict the expected direction.\n\
diagnose/monitor capture HID Raw Input and WM_MOUSEWHEEL together.\n\
fix flips the wheel sign using the calibration from `diagnose`; restore stops it."
    );
}

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    let command = args.first().map(String::as_str).unwrap_or("help");
    let result = match command {
        "diagnose" => run_capture(&args[1..], false),
        "monitor" => run_capture(&args[1..], true),
        "fix" => run_fix(&args[1..]),
        "restore" => run_restore(),
        "status" => {
            run_status();
            Ok(())
        }
        "help" | "--help" | "-h" => {
            usage();
            Ok(())
        }
        other => {
            println!("unknown command: {other}");
            usage();
            Err("unknown command".to_string())
        }
    };
    if result.is_err() {
        std::process::exit(1);
    }
}
