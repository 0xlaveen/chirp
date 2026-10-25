//! Windows implementation is supplied by the coordinated Windows platform PR.
use super::*;
pub struct Windows;
impl Platform for Windows {
    fn default_hotkey(&self) -> HotKey { HotKey::RightCtrl }
    fn start_hotkey(&self, _: HotKey, _: Sender<KeyEvent>) -> Result<HotkeyHandle, String> {
        Err("Windows hotkey support is being added in the Windows platform PR".into())
    }
    fn insert_text(&self, _: &str) -> Result<InsertionOutcome, String> {
        Err("Windows insertion is being added in the Windows platform PR".into())
    }
    fn capabilities(&self) -> Capabilities {
        Capabilities { session: "windows".into(), insertion: vec![], hotkey: false,
            detail: "Windows platform integration is being added in a separate PR.".into() }
    }
}
