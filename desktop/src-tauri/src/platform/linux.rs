use super::*;
use std::{
    io::Write,
    process::{Command, Stdio},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::Duration,
};
use x11rb::protocol::{
    xkb::{ConnectionExt as _, NameDetail, ID},
    xproto::ConnectionExt,
};

pub struct Linux;
fn wayland() -> bool {
    std::env::var_os("WAYLAND_DISPLAY").is_some()
}
fn available(program: &str) -> bool {
    std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default())
        .any(|p| p.join(program).is_file())
}
// Text is pipe data, never a shell command or process argument.
fn pipe(program: &str, args: &[&str], text: &str) -> Result<(), String> {
    let mut child = Command::new(program)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| format!("Could not start {program}"))?;
    let result = child
        .stdin
        .take()
        .ok_or("Input pipe unavailable")?
        .write_all(text.as_bytes());
    if result.is_err() {
        let _ = child.kill();
    }
    let status = child
        .wait()
        .map_err(|_| format!("Could not finish {program}"))?;
    if result.is_ok() && status.success() {
        Ok(())
    } else {
        Err(format!("{program} failed"))
    }
}

fn keycode(key: HotKey) -> Result<u8, String> {
    let (conn, _) = x11rb::connect(None).map_err(|_| "Could not connect to X11")?;
    conn.xkb_use_extension(1, 0)
        .map_err(|_| "XKB is unavailable")?
        .reply()
        .map_err(|_| "XKB is unavailable")?;
    let names = conn
        .xkb_get_names(ID::USE_CORE_KBD.into(), NameDetail::KEY_NAMES)
        .map_err(|_| "Could not read physical key names")?
        .reply()
        .map_err(|_| "Could not read physical key names")?;
    let wanted = match key {
        HotKey::RightCtrl => *b"RCTL",
        _ => *b"RALT",
    };
    names
        .value_list
        .key_names
        .as_ref()
        .and_then(|keys| keys.iter().position(|k| k.name == wanted))
        .map(|i| names.first_key + i as u8)
        .ok_or("Selected right modifier is unavailable".into())
}

impl Platform for Linux {
    fn default_hotkey(&self) -> HotKey {
        // Unknown layouts conservatively use Right Ctrl; AltGr must keep working.
        if wayland() {
            return HotKey::RightCtrl;
        }
        let altgr = (|| {
            let (conn, _) = x11rb::connect(None).ok()?;
            let code = keycode(HotKey::RightAlt).ok()?;
            let mapping = conn.get_keyboard_mapping(code, 1).ok()?.reply().ok()?;
            Some(
                mapping
                    .keysyms
                    .iter()
                    .any(|sym| matches!(sym, 0xfe03 | 0xff7e)),
            )
        })()
        .unwrap_or(true);
        if altgr {
            HotKey::RightCtrl
        } else {
            HotKey::RightAlt
        }
    }

    fn start_hotkey(&self, key: HotKey, tx: Sender<KeyEvent>) -> Result<HotkeyHandle, String> {
        if wayland() {
            return Err("Wayland global shortcuts require compositor portal support. Use the Record button for now.".into());
        }
        let code = keycode(key)?;
        let (conn, _) = x11rb::connect(None).map_err(|_| "Could not connect to X11")?;
        let stop = Arc::new(AtomicBool::new(false));
        let flag = stop.clone();
        std::thread::spawn(move || {
            let mut previous = (false, false);
            while !flag.load(Ordering::Relaxed) {
                let result = conn
                    .query_keymap()
                    .ok()
                    .and_then(|cookie| cookie.reply().ok());
                let Some(reply) = result else {
                    break;
                };
                let down = reply.keys[(code / 8) as usize] & (1 << (code % 8)) != 0;
                let other = reply.keys.iter().enumerate().any(|(i, byte)| {
                    let mask = if i == (code / 8) as usize {
                        !(1 << (code % 8))
                    } else {
                        0xff
                    };
                    byte & mask != 0
                });
                if (down, other) != previous {
                    if tx
                        .send(KeyEvent {
                            key,
                            down,
                            other_key_down: other,
                        })
                        .is_err()
                    {
                        break;
                    }
                    previous = (down, other);
                }
                std::thread::sleep(Duration::from_millis(8));
            }
        });
        Ok(HotkeyHandle::new(move || {
            stop.store(true, Ordering::Relaxed)
        }))
    }

    fn insert_text(&self, text: &str) -> Result<InsertionOutcome, String> {
        if text.is_empty() {
            return Ok(InsertionOutcome::Typed);
        }
        if text.len() > 256 * 1024 {
            return Err("Dictation is too long to insert".into());
        }
        if wayland() {
            if available("wtype") && pipe("wtype", &["-"], text).is_ok() {
                return Ok(InsertionOutcome::Typed);
            }
            pipe("wl-copy", &["--type", "text/plain;charset=utf-8"], text)?;
        } else {
            if !text.contains(['\n', '\r'])
                && available("xdotool")
                && pipe(
                    "xdotool",
                    &["type", "--clearmodifiers", "--file", "-"],
                    text,
                )
                .is_ok()
            {
                return Ok(InsertionOutcome::Typed);
            }
            pipe("xclip", &["-selection", "clipboard", "-in"], text)?;
            // XTest typing drops LF in some toolkits. Paste multiline text as a unit;
            // synthesizing Return would submit commands in a terminal.
            if available("xdotool") {
                let class = Command::new("xdotool")
                    .args(["getwindowfocus", "getwindowclassname"])
                    .stderr(Stdio::null())
                    .output()
                    .ok()
                    .map(|result| String::from_utf8_lossy(&result.stdout).to_lowercase())
                    .unwrap_or_default();
                let terminal = [
                    "terminal",
                    "konsole",
                    "alacritty",
                    "xterm",
                    "kitty",
                    "wezterm",
                    "tilix",
                    "terminator",
                    "kgx",
                ]
                .iter()
                .any(|name| class.contains(name));
                let shortcut = if terminal { "ctrl+shift+v" } else { "ctrl+v" };
                if Command::new("xdotool")
                    .args(["key", "--clearmodifiers", shortcut])
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .status()
                    .is_ok_and(|status| status.success())
                {
                    return Ok(InsertionOutcome::Typed);
                }
            }
        }
        Ok(InsertionOutcome::Clipboard)
    }

    fn capabilities(&self) -> Capabilities {
        let wl = wayland();
        let insertion = if wl {
            ["wtype", "wl-copy"]
        } else {
            ["xdotool", "xclip"]
        }
        .into_iter()
        .filter(|program| available(program))
        .map(str::to_owned)
        .collect();
        Capabilities { session: if wl { "wayland" } else { "x11" }.into(), insertion,
            hotkey: !wl && std::env::var_os("DISPLAY").is_some(),
            detail: if wl { "Wayland: use Record until portal shortcuts are available. wtype needs compositor virtual-keyboard support; otherwise the result is copied for you to paste." }
                else { "Hold the selected right modifier alone to dictate. Chords cancel dictation. X11 inserts using xdotool, with a clipboard fallback." }.into() }
    }
}
