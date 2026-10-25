//! Platform observers report only modifier transitions/chord presence, never typed text.
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum HotKey {
    RightAlt,
    RightCtrl,
    RightOption,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum HotkeyMode {
    Hold,
    Toggle,
}

#[derive(Clone, Copy, Debug)]
pub struct KeyEvent {
    pub key: HotKey,
    pub down: bool,
    pub other_key_down: bool,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Action {
    Start,
    Stop,
    Cancel,
}

pub struct HotkeyState {
    key: HotKey,
    mode: HotkeyMode,
    down: bool,
    blocked: bool,
    recording: bool,
}

impl HotkeyState {
    pub fn new(key: HotKey, mode: HotkeyMode) -> Self {
        Self {
            key,
            mode,
            down: false,
            blocked: false,
            recording: false,
        }
    }

    pub fn set_recording(&mut self, recording: bool) {
        self.recording = recording;
    }

    pub fn event(&mut self, event: KeyEvent) -> Option<Action> {
        if event.key != self.key {
            return None;
        }
        if event.other_key_down {
            self.blocked = event.down;
            self.down = event.down;
            if self.recording {
                self.recording = false;
                return Some(Action::Cancel);
            }
            return None;
        }
        if event.down == self.down {
            return None;
        }
        self.down = event.down;
        if event.down {
            self.blocked = false;
            if self.mode == HotkeyMode::Hold {
                self.recording = true;
                return Some(Action::Start);
            }
        } else if !self.blocked {
            if self.mode == HotkeyMode::Toggle {
                self.recording = !self.recording;
                return Some(if self.recording {
                    Action::Start
                } else {
                    Action::Stop
                });
            }
            if self.recording {
                self.recording = false;
                return Some(Action::Stop);
            }
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn event(down: bool, chord: bool) -> KeyEvent {
        KeyEvent {
            key: HotKey::RightCtrl,
            down,
            other_key_down: chord,
        }
    }
    #[test]
    fn hold_rejects_chords_and_repeat() {
        let mut state = HotkeyState::new(HotKey::RightCtrl, HotkeyMode::Hold);
        assert_eq!(state.event(event(true, false)), Some(Action::Start));
        assert_eq!(state.event(event(true, false)), None);
        assert_eq!(state.event(event(true, true)), Some(Action::Cancel));
        assert_eq!(state.event(event(false, false)), None);
        assert_eq!(state.event(event(true, true)), None);
        assert_eq!(state.event(event(false, false)), None);
        assert_eq!(state.event(event(true, false)), Some(Action::Start));
        assert_eq!(state.event(event(false, false)), Some(Action::Stop));
    }
    #[test]
    fn toggle_only_on_clean_release() {
        let mut state = HotkeyState::new(HotKey::RightCtrl, HotkeyMode::Toggle);
        assert_eq!(state.event(event(true, false)), None);
        assert_eq!(state.event(event(false, false)), Some(Action::Start));
        assert_eq!(state.event(event(true, true)), Some(Action::Cancel));
        assert_eq!(state.event(event(false, false)), None);
        assert_eq!(state.event(event(true, false)), None);
        assert_eq!(state.event(event(false, false)), Some(Action::Start));
        assert_eq!(state.event(event(true, false)), None);
        assert_eq!(state.event(event(false, false)), Some(Action::Stop));
    }
}
