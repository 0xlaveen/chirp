//! Windows input rules without Win32 calls, so every platform's `cargo test` covers them:
//! which virtual key is the hotkey, how low-level hook events become `KeyEvent`s, how AltGr
//! picks the default key, and how text becomes SendInput units.
use crate::hotkey::{HotKey, KeyEvent};
use std::collections::BTreeSet;

pub const VK_TAB: u16 = 0x09;
pub const VK_RETURN: u16 = 0x0D;
pub const VK_LCONTROL: u32 = 0xA2;
pub const VK_RCONTROL: u32 = 0xA3;
pub const VK_RMENU: u32 = 0xA5;
/// An unassigned virtual key. Pressing it while Alt is down stops a lone Alt release from
/// opening the focused app's menu bar (the same "menu mask" trick AutoHotkey uses).
pub const VK_MENU_MASK: u16 = 0xE8;
/// The scan code Windows gives the synthetic Left Ctrl it sends before an AltGr (Right Alt).
pub const ALTGR_FAKE_CTRL_SCAN: u32 = 0x21D;
/// Above this many UTF-16 units, paste through the clipboard instead of typing.
pub const PASTE_THRESHOLD: usize = 2000;

pub fn target_vk(key: HotKey) -> Option<u32> {
    match key {
        HotKey::RightAlt => Some(VK_RMENU),
        HotKey::RightCtrl => Some(VK_RCONTROL),
        HotKey::RightOption => None,
    }
}

/// Right Alt is free to use only when the layout has no AltGr; otherwise Right Ctrl.
pub fn default_hotkey(layout_has_altgr: bool) -> HotKey {
    if layout_has_altgr {
        HotKey::RightCtrl
    } else {
        HotKey::RightAlt
    }
}

/// Virtual keys that type characters: digits, letters and the OEM punctuation keys.
pub fn character_keys() -> impl Iterator<Item = u32> {
    (0x30..=0x39)
        .chain(0x41..=0x5A)
        .chain(0xBA..=0xC0)
        .chain(0xDB..=0xDF)
        .chain([0xE2])
}

/// True when Ctrl+Alt (what AltGr sends) types something on any character key. `probe`
/// returns ToUnicodeEx's result for a key with Ctrl and Alt held: >0 characters, <0 a dead key.
pub fn layout_has_altgr(probe: impl Fn(u32) -> i32) -> bool {
    character_keys().any(|vk| probe(vk) != 0)
}

/// Turns low-level keyboard hook events into the shared `KeyEvent`s: it reports a change
/// whenever the target key's state or "another key is down" changes, like the Linux observer.
pub struct KeyObserver {
    key: HotKey,
    target: u32,
    target_down: bool,
    others: BTreeSet<u32>,
    last: (bool, bool),
}

impl KeyObserver {
    pub fn new(key: HotKey) -> Option<Self> {
        Some(Self {
            key,
            target: target_vk(key)?,
            target_down: false,
            others: BTreeSet::new(),
            last: (false, false),
        })
    }

    pub fn target(&self) -> u32 {
        self.target
    }

    /// Feed one hook event. Injected events (ours, and other programs' SendInput) and the
    /// synthetic Left Ctrl of AltGr are ignored, so neither can start or block dictation.
    pub fn on_key(&mut self, vk: u32, scan: u32, down: bool, injected: bool) -> Option<KeyEvent> {
        if injected || (vk == VK_LCONTROL && scan == ALTGR_FAKE_CTRL_SCAN) {
            return None;
        }
        if vk == self.target {
            self.target_down = down;
        } else if down {
            self.others.insert(vk);
        } else {
            self.others.remove(&vk);
        }
        self.report()
    }

    /// Drop keys whose release the hook missed (for example across the lock screen).
    pub fn forget_released(&mut self, still_down: impl Fn(u32) -> bool) -> Option<KeyEvent> {
        self.others.retain(|vk| still_down(*vk));
        self.report()
    }

    fn report(&mut self) -> Option<KeyEvent> {
        let state = (self.target_down, !self.others.is_empty());
        if state == self.last {
            return None;
        }
        self.last = state;
        Some(KeyEvent {
            key: self.key,
            down: state.0,
            other_key_down: state.1,
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Unit {
    /// One UTF-16 code unit sent with KEYEVENTF_UNICODE; surrogate pairs stay adjacent.
    Char(u16),
    /// A virtual key: Enter for line breaks and Tab, which many apps ignore as characters.
    Key(u16),
}

/// The SendInput plan for `text`: CRLF and lone CR become one Enter.
pub fn units(text: &str) -> Vec<Unit> {
    let mut result = Vec::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\r' => {
                if chars.peek() == Some(&'\n') {
                    chars.next();
                }
                result.push(Unit::Key(VK_RETURN));
            }
            '\n' => result.push(Unit::Key(VK_RETURN)),
            '\t' => result.push(Unit::Key(VK_TAB)),
            _ => {
                let mut buffer = [0u16; 2];
                result.extend(c.encode_utf16(&mut buffer).iter().map(|u| Unit::Char(*u)));
            }
        }
    }
    result
}

/// Batches of units for SendInput that never split a surrogate pair.
pub fn batches(units: &[Unit], size: usize) -> Vec<&[Unit]> {
    let mut result = Vec::new();
    let mut start = 0;
    while start < units.len() {
        let mut end = (start + size.max(2)).min(units.len());
        if end < units.len() {
            if let Unit::Char(u) = units[end - 1] {
                if (0xD800..0xDC00).contains(&u) {
                    end -= 1;
                }
            }
        }
        result.push(&units[start..end]);
        start = end;
    }
    result
}

/// The text a partially typed plan still has to insert, from the first unsent unit on.
pub fn remainder(units: &[Unit]) -> String {
    let mut text = Vec::new();
    for unit in units {
        match unit {
            Unit::Char(u) => text.push(*u),
            Unit::Key(VK_RETURN) => text.extend("\r\n".encode_utf16()),
            Unit::Key(_) => text.push('\t' as u16),
        }
    }
    String::from_utf16_lossy(&text)
}

#[derive(Debug, PartialEq, Eq)]
pub enum Route {
    /// Type with SendInput, falling back to a paste if it is refused.
    Type,
    /// Paste with the clipboard and Ctrl+V, then restore the clipboard.
    Paste,
    /// The target runs elevated: Windows blocks synthetic input to it from a normal app, so
    /// leave the text on the clipboard for the user to paste.
    CopyOnly,
}

pub fn route(units: usize, target_elevated: bool, self_elevated: bool) -> Route {
    if target_elevated && !self_elevated {
        return Route::CopyOnly;
    }
    if units > PASTE_THRESHOLD {
        Route::Paste
    } else {
        Route::Type
    }
}

/// A protected DACL granting full control to the user and SYSTEM only; a directory's entries
/// are inherited by everything created inside it.
pub fn private_sddl(user_sid: &str, directory: bool) -> String {
    let flags = if directory { "OICI" } else { "" };
    format!("D:P(A;{flags};FA;;;{user_sid})(A;{flags};FA;;;SY)")
}

/// True when the DACL in `sddl` is protected from inheritance and every allow entry names
/// the user (in any form SDDL prints it, such as LA for the built-in Administrator) or SYSTEM.
pub fn sddl_is_private(sddl: &str, user_forms: &[String]) -> bool {
    let Some(dacl) = sddl.split_once("D:").map(|(_, rest)| rest) else {
        return false;
    };
    let dacl = dacl.split("S:").next().unwrap_or("");
    let flags = dacl.split('(').next().unwrap_or("");
    if !flags.contains('P') || flags.contains("NO_ACCESS_CONTROL") {
        return false;
    }
    let mut allowed = 0;
    for ace in dacl.split('(').skip(1) {
        let fields: Vec<&str> = ace.trim_end_matches(')').split(';').collect();
        if fields.len() < 6 {
            return false;
        }
        if matches!(fields[0], "A" | "OA" | "XA" | "ZA") {
            let trustee = fields[5];
            if trustee != "SY" && trustee != "S-1-5-18" && !user_forms.iter().any(|f| f == trustee)
            {
                return false;
            }
            allowed += 1;
        }
    }
    allowed > 0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event(down: bool, other: bool) -> Option<KeyEvent> {
        Some(KeyEvent {
            key: HotKey::RightCtrl,
            down,
            other_key_down: other,
        })
    }
    fn same(a: Option<KeyEvent>, b: Option<KeyEvent>) -> bool {
        match (a, b) {
            (None, None) => true,
            (Some(a), Some(b)) => {
                a.key == b.key && a.down == b.down && a.other_key_down == b.other_key_down
            }
            _ => false,
        }
    }

    #[test]
    fn hook_events_report_target_and_chord_changes() {
        let mut observer = KeyObserver::new(HotKey::RightCtrl).unwrap();
        assert!(same(
            observer.on_key(VK_RCONTROL, 0x1D, true, false),
            event(true, false)
        ));
        // Auto-repeat of the held key reports nothing new.
        assert!(same(observer.on_key(VK_RCONTROL, 0x1D, true, false), None));
        assert!(same(
            observer.on_key(0x43, 0x2E, true, false),
            event(true, true)
        ));
        assert!(same(
            observer.on_key(0x43, 0x2E, false, false),
            event(true, false)
        ));
        assert!(same(
            observer.on_key(VK_RCONTROL, 0x1D, false, false),
            event(false, false)
        ));
    }

    #[test]
    fn injected_input_and_altgr_fake_ctrl_are_ignored() {
        let mut observer = KeyObserver::new(HotKey::RightAlt).unwrap();
        assert!(same(
            observer.on_key(VK_LCONTROL, ALTGR_FAKE_CTRL_SCAN, true, false),
            None
        ));
        let down = observer.on_key(VK_RMENU, 0x38, true, false).unwrap();
        assert!(down.down && !down.other_key_down);
        // Our own typing (and the menu-mask key) arrives as injected events.
        assert!(same(observer.on_key(0x41, 0, true, true), None));
        assert!(same(
            observer.on_key(VK_MENU_MASK as u32, 0, true, true),
            None
        ));
        // A real Left Ctrl is another key.
        assert!(
            observer
                .on_key(VK_LCONTROL, 0x1D, true, false)
                .unwrap()
                .other_key_down
        );
    }

    #[test]
    fn a_key_held_before_the_target_blocks_it_and_missed_releases_are_forgotten() {
        let mut observer = KeyObserver::new(HotKey::RightCtrl).unwrap();
        assert!(same(
            observer.on_key(0x10, 0x2A, true, false),
            event(false, true)
        ));
        assert!(same(
            observer.on_key(VK_RCONTROL, 0x1D, true, false),
            event(true, true)
        ));
        assert!(same(
            observer.forget_released(|_| false),
            event(true, false)
        ));
    }

    #[test]
    fn right_option_has_no_windows_key() {
        assert!(KeyObserver::new(HotKey::RightOption).is_none());
        assert_eq!(target_vk(HotKey::RightAlt), Some(0xA5));
    }

    #[test]
    fn altgr_layouts_default_to_right_ctrl() {
        // US: Ctrl+Alt types nothing. German: Ctrl+Alt+Q types @. French dead key: -1.
        assert_eq!(default_hotkey(layout_has_altgr(|_| 0)), HotKey::RightAlt);
        assert_eq!(
            default_hotkey(layout_has_altgr(|vk| (vk == 0x51) as i32)),
            HotKey::RightCtrl
        );
        assert_eq!(
            default_hotkey(layout_has_altgr(|vk| if vk == 0xDE { -1 } else { 0 })),
            HotKey::RightCtrl
        );
    }

    #[test]
    fn units_keep_surrogates_and_map_line_breaks() {
        let plan = units("Hé 👋\r\nok\nx\ty");
        assert_eq!(
            &plan[..3],
            &[
                Unit::Char('H' as u16),
                Unit::Char(0xE9),
                Unit::Char(' ' as u16)
            ]
        );
        assert_eq!(&plan[3..5], &[Unit::Char(0xD83D), Unit::Char(0xDC4B)]);
        assert_eq!(plan[5], Unit::Key(VK_RETURN));
        assert_eq!(
            plan.iter().filter(|u| **u == Unit::Key(VK_RETURN)).count(),
            2
        );
        assert!(plan.contains(&Unit::Key(VK_TAB)));
        assert_eq!(remainder(&plan), "Hé 👋\r\nok\r\nx\ty");
    }

    #[test]
    fn batches_never_split_a_surrogate_pair() {
        let plan = units("ab👋cd👋");
        for size in 2..8 {
            let parts = batches(&plan, size);
            assert_eq!(parts.iter().map(|p| p.len()).sum::<usize>(), plan.len());
            for part in parts {
                assert!(
                    !matches!(part.last(), Some(Unit::Char(u)) if (0xD800..0xDC00).contains(u))
                );
            }
        }
    }

    #[test]
    fn private_dacls_allow_only_the_user_and_system() {
        let user = "S-1-5-21-1-2-3-1001".to_string();
        let forms = vec![user.clone()];
        assert_eq!(
            private_sddl(&user, false),
            format!("D:P(A;;FA;;;{user})(A;;FA;;;SY)")
        );
        assert!(sddl_is_private(&private_sddl(&user, true), &forms));
        // Not protected: inherited entries could widen it later.
        assert!(!sddl_is_private(&format!("D:(A;;FA;;;{user})"), &forms));
        assert!(!sddl_is_private(
            &format!("D:P(A;;FA;;;{user})(A;;FR;;;BU)"),
            &forms
        ));
        assert!(!sddl_is_private("D:P(A;;FA;;;S-1-5-21-1-2-3-1002)", &forms));
        assert!(!sddl_is_private("D:NO_ACCESS_CONTROL", &forms));
        assert!(!sddl_is_private("O:BA", &forms));
        // The built-in Administrator's SID prints as LA.
        let admin = vec![user.clone(), "LA".to_string()];
        assert!(sddl_is_private("D:PAI(A;;FA;;;LA)(A;;FA;;;SY)", &admin));
        // A deny entry never widens access.
        assert!(sddl_is_private(
            &format!("D:P(D;;FA;;;WD)(A;;FA;;;{user})"),
            &forms
        ));
    }

    #[test]
    fn routes() {
        assert_eq!(route(10, false, false), Route::Type);
        assert_eq!(route(PASTE_THRESHOLD + 1, false, false), Route::Paste);
        assert_eq!(route(10, true, false), Route::CopyOnly);
        assert_eq!(route(10, true, true), Route::Type);
    }
}
