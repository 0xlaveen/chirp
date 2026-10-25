use super::*;
use std::{io::Write, process::{Command, Stdio}, sync::{Arc, atomic::{AtomicBool, Ordering}}, time::Duration};
use x11rb::{connection::Connection, protocol::xproto::ConnectionExt};

pub struct Linux;
fn wayland() -> bool { std::env::var_os("WAYLAND_DISPLAY").is_some() }
fn available(program: &str) -> bool {
    std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default())
        .any(|p| p.join(program).is_file())
}
// Text is pipe data, never a shell command or process argument.
fn pipe(program: &str, args: &[&str], text: &str) -> Result<(), String> {
    let mut child = Command::new(program).args(args).stdin(Stdio::piped())
        .stdout(Stdio::null()).stderr(Stdio::null()).spawn()
        .map_err(|_| format!("Could not start {program}"))?;
    let result = child.stdin.take().ok_or("Input pipe unavailable")?
        .write_all(text.as_bytes());
    if result.is_err() { let _ = child.kill(); }
    let status = child.wait().map_err(|_| format!("Could not finish {program}"))?;
    if result.is_ok() && status.success() { Ok(()) } else { Err(format!("{program} failed")) }
}

fn keycode(key: HotKey) -> Result<u8, String> {
    let (conn, _) = x11rb::connect(None).map_err(|_| "Could not connect to X11")?;
    let setup = conn.setup();
    let count = setup.max_keycode - setup.min_keycode + 1;
    let mapping = conn.get_keyboard_mapping(setup.min_keycode, count)
        .map_err(|_| "Could not query X11 keyboard")?.reply()
        .map_err(|_| "Could not query X11 keyboard")?;
    let wanted: &[u32] = match key {
        HotKey::RightCtrl => &[0xffe4],
        _ => &[0xffea, 0xfe03], // Alt_R or ISO_Level3_Shift (AltGr).
    };
    mapping.keysyms.chunks(mapping.keysyms_per_keycode as usize)
        .position(|row| row.iter().any(|symbol| wanted.contains(symbol)))
        .map(|i| setup.min_keycode + i as u8).ok_or("Selected right modifier is unavailable".into())
}

impl Platform for Linux {
    fn default_hotkey(&self) -> HotKey {
        // Unknown layouts conservatively use Right Ctrl; AltGr must keep working.
        if wayland() { return HotKey::RightCtrl; }
        let altgr = (|| {
            let (conn, _) = x11rb::connect(None).ok()?;
            let setup = conn.setup();
            let mapping = conn.get_keyboard_mapping(setup.min_keycode, setup.max_keycode - setup.min_keycode + 1).ok()?.reply().ok()?;
            Some(mapping.keysyms.contains(&0xfe03))
        })().unwrap_or(true);
        if altgr { HotKey::RightCtrl } else { HotKey::RightAlt }
    }

    fn start_hotkey(&self, key: HotKey, tx: Sender<KeyEvent>) -> Result<HotkeyHandle, String> {
        if wayland() { return Err("Wayland global shortcuts require compositor portal support. Use the Record button for now.".into()); }
        let code = keycode(key)?;
        let (conn, _) = x11rb::connect(None).map_err(|_| "Could not connect to X11")?;
        let stop = Arc::new(AtomicBool::new(false));
        let flag = stop.clone();
        std::thread::spawn(move || {
            let mut previous = (false, false);
            while !flag.load(Ordering::Relaxed) {
                let result = conn.query_keymap().ok().and_then(|cookie| cookie.reply().ok());
                let Some(reply) = result else { break; };
                let down = reply.keys[(code / 8) as usize] & (1 << (code % 8)) != 0;
                let other = reply.keys.iter().enumerate().any(|(i, byte)| {
                    let mask = if i == (code / 8) as usize { !(1 << (code % 8)) } else { 0xff };
                    byte & mask != 0
                });
                if (down, other) != previous {
                    if tx.send(KeyEvent { key, down, other_key_down: other }).is_err() { break; }
                    previous = (down, other);
                }
                std::thread::sleep(Duration::from_millis(8));
            }
        });
        Ok(HotkeyHandle::new(move || stop.store(true, Ordering::Relaxed)))
    }

    fn insert_text(&self, text: &str) -> Result<InsertionOutcome, String> {
        if text.is_empty() { return Ok(InsertionOutcome::Typed); }
        if text.len() > 256 * 1024 { return Err("Dictation is too long to insert".into()); }
        if wayland() {
            if available("wtype") && pipe("wtype", &["-"], text).is_ok() {
                return Ok(InsertionOutcome::Typed);
            }
            pipe("wl-copy", &["--type", "text/plain;charset=utf-8"], text)?;
        } else {
            if available("xdotool") && pipe("xdotool", &["type", "--clearmodifiers", "--file", "-"], text).is_ok() {
                return Ok(InsertionOutcome::Typed);
            }
            pipe("xclip", &["-selection", "clipboard", "-in"], text)?;
        }
        Ok(InsertionOutcome::Clipboard)
    }

    fn capabilities(&self) -> Capabilities {
        let wl = wayland();
        let insertion = if wl { ["wtype", "wl-copy"] } else { ["xdotool", "xclip"] }
            .into_iter().filter(|program| available(program)).map(str::to_owned).collect();
        Capabilities { session: if wl { "wayland" } else { "x11" }.into(), insertion,
            hotkey: !wl && std::env::var_os("DISPLAY").is_some(),
            detail: if wl { "Wayland: use Record until portal shortcuts are available. wtype needs compositor virtual-keyboard support; otherwise the result is copied for you to paste." }
                else { "Hold the selected right modifier alone to dictate. Chords cancel dictation. X11 inserts using xdotool, with a clipboard fallback." }.into() }
    }
}
