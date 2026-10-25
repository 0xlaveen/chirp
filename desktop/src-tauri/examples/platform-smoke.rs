//! Native insertion probe. Synthetic text arrives on stdin, never in arguments/logs.
use chirp_desktop::{
    hotkey::{HotKey, HotkeyMode, HotkeyState},
    platform,
};
use std::{
    io::{Read, Write},
    time::Duration,
};
fn main() {
    let backend = platform::native();
    match std::env::args().nth(1).as_deref() {
        Some("insert") => {
            let mut text = String::new();
            std::io::stdin().read_to_string(&mut text).unwrap();
            let outcome = backend.insert_text(&text).expect("native insertion failed");
            println!("{}", serde_json::to_string(&outcome).unwrap());
        }
        Some("hotkey") => {
            let (tx, rx) = std::sync::mpsc::channel();
            let _hook = backend.start_hotkey(HotKey::RightCtrl, tx).unwrap();
            let mut state = HotkeyState::new(HotKey::RightCtrl, HotkeyMode::Hold);
            println!("ready");
            std::io::stdout().flush().unwrap();
            while let Ok(event) = rx.recv_timeout(Duration::from_secs(10)) {
                println!("probe down={} chord={}", event.down, event.other_key_down);
                std::io::stdout().flush().unwrap();
                if let Some(action) = state.event(event) {
                    println!("{action:?}");
                    std::io::stdout().flush().unwrap();
                }
            }
        }
        Some("default-key") => println!("{:?}", backend.default_hotkey()),
        _ => panic!("expected insert, hotkey or default-key"),
    }
}
