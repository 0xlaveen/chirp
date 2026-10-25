use crate::hotkey::{HotKey, KeyEvent};
use serde::Serialize;
use std::sync::mpsc::Sender;

#[cfg(target_os = "linux")]
pub mod linux;
#[cfg(target_os = "windows")]
pub mod windows;

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum InsertionOutcome {
    Typed,
    Clipboard,
}

#[derive(Clone, Serialize)]
pub struct Capabilities {
    pub session: String,
    pub insertion: Vec<String>,
    pub hotkey: bool,
    pub detail: String,
}

pub struct HotkeyHandle(Option<Box<dyn FnOnce() + Send>>);
impl HotkeyHandle {
    pub fn new(stop: impl FnOnce() + Send + 'static) -> Self {
        Self(Some(Box::new(stop)))
    }
}
impl Drop for HotkeyHandle {
    fn drop(&mut self) {
        if let Some(stop) = self.0.take() {
            stop();
        }
    }
}

pub trait Platform: Send + Sync {
    fn default_hotkey(&self) -> HotKey;
    fn start_hotkey(&self, key: HotKey, tx: Sender<KeyEvent>) -> Result<HotkeyHandle, String>;
    fn insert_text(&self, text: &str) -> Result<InsertionOutcome, String>;
    fn capabilities(&self) -> Capabilities;
}

pub fn native() -> Box<dyn Platform> {
    #[cfg(target_os = "linux")]
    {
        Box::new(linux::Linux)
    }
    #[cfg(target_os = "windows")]
    {
        Box::new(windows::Windows)
    }
    #[cfg(not(any(target_os = "linux", target_os = "windows")))]
    {
        Box::new(Unsupported)
    }
}

#[cfg(not(any(target_os = "linux", target_os = "windows")))]
struct Unsupported;
#[cfg(not(any(target_os = "linux", target_os = "windows")))]
impl Platform for Unsupported {
    fn default_hotkey(&self) -> HotKey {
        HotKey::RightOption
    }
    fn start_hotkey(&self, _: HotKey, _: Sender<KeyEvent>) -> Result<HotkeyHandle, String> {
        Err("Use the native Chirp Mac app for global dictation on macOS".into())
    }
    fn insert_text(&self, _: &str) -> Result<InsertionOutcome, String> {
        Err("Use the native Chirp Mac app for text insertion on macOS".into())
    }
    fn capabilities(&self) -> Capabilities {
        Capabilities {
            session: "unsupported".into(),
            insertion: vec![],
            hotkey: false,
            detail: "The native Chirp Mac app remains the supported macOS client.".into(),
        }
    }
}
