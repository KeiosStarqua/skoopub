// HID++ 2.0 Adjustable DPI (feature 0x2201) over hidapi.
//
// Protocol reference: libratbag's hidpp20.c (hidpp20_adjustable_dpi_*).
// On Windows the Logitech vendor collection exposes two HID interfaces:
//   usage_page 0xff00, usage 0x01 -> interrupt OUT (requests)
//   usage_page 0xff00, usage 0x02 -> interrupt IN  (replies)
// A short HID++ request is 7 bytes: [0x10, 0xff, feature, func|0x08, p0, p1, p2].
// Replies can arrive as long (0x11) reports, so read up to 20 bytes and match
// on feature/function before accepting one.

use hidapi::{HidApi, HidDevice};
use std::time::{Duration, Instant};

const LOGITECH_VID: u16 = 0x046d;
const HIDPP_SHORT: u8 = 0x10;
const RECEIVER_IDX: u8 = 0xff;
const SW_ID: u8 = 0x08;
const FEATURE_ROOT: u8 = 0x00;
const FEATURE_ADJUSTABLE_DPI: [u8; 3] = [0x22, 0x01, 0x00];

const GET_SENSOR_COUNT: u8 = 0x00;
const GET_DPI_LIST: u8 = 0x10;
const GET_DPI: u8 = 0x20;
const SET_DPI: u8 = 0x30;

fn be16(bytes: &[u8]) -> u16 {
    ((bytes[0] as u16) << 8) | bytes[1] as u16
}

// Interfaces of one physical device share the path up to `&ColNN`.
fn device_key(path: &std::ffi::CStr) -> String {
    let text = path.to_string_lossy();
    match text.find("&Col") {
        Some(i) => text[..i].to_string(),
        None => text.to_string(),
    }
}

struct Mouse {
    product: String,
    vid: u16,
    pid: u16,
    write: HidDevice,
    read: HidDevice,
}

fn open_mouse(api: &HidApi) -> Result<Mouse, String> {
    let mut found: Vec<(String, u16, u16, Option<HidDevice>, Option<HidDevice>)> = Vec::new();
    for info in api.device_list() {
        if info.vendor_id() != LOGITECH_VID || info.usage_page() != 0xff00 {
            continue;
        }
        let key = device_key(info.path());
        let entry = if let Some(e) = found.iter_mut().find(|e| e.0 == key) {
            e
        } else {
            found.push((
                key,
                info.vendor_id(),
                info.product_id(),
                None,
                None,
            ));
            found.last_mut().unwrap()
        };
        if let Ok(dev) = info.open_device(api) {
            match info.usage() {
                1 => entry.3 = Some(dev),
                2 => entry.4 = Some(dev),
                _ => {}
            }
        }
    }

    for (_, vid, pid, write, read) in found {
        let (write, read) = match (write, read) {
            (Some(w), Some(r)) => (w, r),
            _ => continue,
        };
        let product = api
            .device_list()
            .find(|i| i.vendor_id() == vid && i.product_id() == pid && i.usage_page() == 0xff00)
            .and_then(|i| i.product_string())
            .unwrap_or("Logitech mouse")
            .to_string();
        return Ok(Mouse { product, vid, pid, write, read });
    }
    Err("no Logitech HID++ mouse found (vendor interface 0xff00 not accessible)".to_string())
}

fn request(mouse: &mut Mouse, feature: u8, func: u8, params: [u8; 3]) -> Result<[u8; 20], String> {
    let msg = [
        HIDPP_SHORT,
        RECEIVER_IDX,
        feature,
        func | SW_ID,
        params[0],
        params[1],
        params[2],
    ];
    mouse
        .write
        .write(&msg)
        .map_err(|e| format!("HID++ write failed: {}", e))?;

    let expected = func | SW_ID;
    let deadline = Instant::now() + Duration::from_millis(1500);
    while Instant::now() < deadline {
        let mut buf = [0u8; 20];
        match mouse.read.read_timeout(&mut buf, 250) {
            Ok(n) if n >= 4 => {
                if buf[1] == RECEIVER_IDX && buf[2] == feature && buf[3] == expected {
                    return Ok(buf);
                }
            }
            Ok(_) => {}
            Err(e) => return Err(format!("HID++ read failed: {}", e)),
        }
    }
    Err(format!(
        "no HID++ reply to feature 0x{:02x} function 0x{:02x} (G HUB may be holding the device)",
        feature, func
    ))
}

struct SensorInfo {
    min: u16,
    max: u16,
    step: u16,
}

fn dpi_list(mouse: &mut Mouse, feature: u8, sensor: u8) -> Result<SensorInfo, String> {
    let reply = request(mouse, feature, GET_DPI_LIST, [sensor, 0, 0])?;
    let mut info = SensorInfo { min: 0xffff, max: 0, step: 0 };
    let mut i = 5usize; // parameters start at byte 4; DPI values start at parameters[1]
    while i + 1 < reply.len() {
        let value = be16(&reply[i..i + 2]);
        if value == 0 {
            break;
        }
        if value > 0xe000 {
            info.step = value - 0xe000;
        } else {
            info.min = info.min.min(value);
            info.max = info.max.max(value);
        }
        i += 2;
    }
    Ok(info)
}

fn current_dpi(mouse: &mut Mouse, feature: u8, sensor: u8) -> Result<u16, String> {
    let reply = request(mouse, feature, GET_DPI, [sensor, 0, 0])?;
    Ok(be16(&reply[5..7]))
}

fn set_dpi(mouse: &mut Mouse, feature: u8, sensor: u8, dpi: u16) -> Result<(), String> {
    let params = [sensor, (dpi >> 8) as u8, (dpi & 0xff) as u8];
    request(mouse, feature, SET_DPI, params)?;
    Ok(())
}

fn option(args: &[String], name: &str) -> Result<Option<String>, String> {
    let mut found = None;
    for (i, arg) in args.iter().enumerate() {
        if arg == &format!("--{}", name) {
            found = Some(
                args.get(i + 1)
                    .cloned()
                    .ok_or_else(|| format!("--{} needs a value", name))?,
            );
        }
    }
    Ok(found)
}

pub fn run(args: &[String]) -> Result<(), String> {
    let raw = option(args, "value")?
        .or(option(args, "dpi")?)
        .unwrap_or_else(|| "1000".to_string());
    let dpi: u16 = raw
        .parse()
        .map_err(|_| format!("invalid DPI value: {}", raw))?;
    let dry_run = args.iter().any(|a| a == "--dry-run");

    let api = HidApi::new().map_err(|e| format!("hidapi init failed: {}", e))?;
    let mut mouse = open_mouse(&api)?;

    let root = request(&mut mouse, FEATURE_ROOT, 0x00, FEATURE_ADJUSTABLE_DPI)?;
    let feature = root[4];
    if feature == 0 {
        return Err(format!(
            "{} does not expose HID++ feature 0x2201 (Adjustable DPI)",
            mouse.product
        ));
    }

    let count = request(&mut mouse, feature, GET_SENSOR_COUNT, [0, 0, 0])?[4];
    if count == 0 {
        return Err("no DPI sensor reported by the mouse".to_string());
    }
    let sensor = 0u8;
    let info = dpi_list(&mut mouse, feature, sensor)?;
    let before = current_dpi(&mut mouse, feature, sensor)?;

    println!(
        "{} (VID {:04x}:PID {:04x}), sensor {}: DPI {} (range {}..{} step {}).",
        mouse.product, mouse.vid, mouse.pid, sensor, before, info.min, info.max, info.step
    );

    if before == dpi {
        println!("DPI already {} - nothing to do.", dpi);
        return Ok(());
    }
    if dpi < info.min || dpi > info.max {
        return Err(format!("DPI {} is outside the mouse range {}..{}", dpi, info.min, info.max));
    }
    if dry_run {
        println!("Dry run: would change DPI {} -> {}.", before, dpi);
        return Ok(());
    }

    println!("Setting DPI {} -> {} ...", before, dpi);
    set_dpi(&mut mouse, feature, sensor, dpi)?;
    std::thread::sleep(Duration::from_millis(150));
    let after = current_dpi(&mut mouse, feature, sensor)?;
    if after != dpi {
        return Err(format!("DPI change did not stick (expected {}, got {})", dpi, after));
    }
    println!("DPI is now {} (verified).", after);
    Ok(())
}
