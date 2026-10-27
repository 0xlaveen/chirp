//! Press Enter after a typed insertion. Desktop cannot see a field's Send, Go or Done key.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AutoEnter {
    Off,
    /// Single-line typed insertions only: the desktop stand-in for a Send, Go or Done key.
    Action,
    Always,
}

impl AutoEnter {
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "off" => Some(Self::Off),
            "action" => Some(Self::Action),
            "always" => Some(Self::Always),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Off => "off",
            Self::Action => "action",
            Self::Always => "always",
        }
    }
}

/// Whether Enter should follow this insertion.
///
/// `typed` is a real keystroke or paste into the focused app. A clipboard-only
/// result has not landed, so Enter would go to the wrong place. Blank text,
/// including whitespace, never sends. Action mode skips text that already
/// contains a line break: desktop cannot see the field's key, and a break means
/// the text was inserted as more than a one-line Send, Go or Done field.
pub fn should_press(mode: AutoEnter, typed: bool, text: &str) -> bool {
    if !typed || mode == AutoEnter::Off || text.trim().is_empty() {
        return false;
    }
    match mode {
        AutoEnter::Off => false,
        AutoEnter::Action => !text.contains(['\n', '\r']),
        AutoEnter::Always => true,
    }
}

/// Enter in these windows runs a command. Class names come from X11 `WM_CLASS`
/// or a Windows window class, compared case-insensitively.
pub fn submits_on_enter(class_name: &str) -> bool {
    let class = class_name.to_ascii_lowercase();
    [
        "consolewindowclass",
        "cascadia_hosting_window_class",
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
    .any(|name| class.contains(name))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unknown_modes_are_rejected_and_known_modes_round_trip() {
        assert_eq!(AutoEnter::parse("bogus"), None);
        assert_eq!(AutoEnter::parse(""), None);
        for mode in [AutoEnter::Off, AutoEnter::Action, AutoEnter::Always] {
            assert_eq!(AutoEnter::parse(mode.as_str()), Some(mode));
        }
    }

    #[test]
    fn enter_follows_only_text_that_landed() {
        assert!(!should_press(AutoEnter::Always, true, "   "));
        assert!(!should_press(AutoEnter::Always, true, ""));
        assert!(!should_press(AutoEnter::Always, false, "hello"));
        assert!(!should_press(AutoEnter::Off, true, "hello"));
        assert!(!should_press(AutoEnter::Action, true, "line one\nline two"));
        assert!(!should_press(
            AutoEnter::Action,
            true,
            "line one\r\nline two"
        ));
        assert!(should_press(AutoEnter::Action, true, "send this"));
        assert!(should_press(AutoEnter::Always, true, "line one\nline two"));
        assert!(should_press(AutoEnter::Always, true, "send this"));
    }

    #[test]
    fn terminals_are_left_alone() {
        assert!(submits_on_enter("gnome-terminal"));
        assert!(submits_on_enter("ConsoleWindowClass"));
        assert!(submits_on_enter("CASCADIA_HOSTING_WINDOW_CLASS"));
        assert!(submits_on_enter("org.wezfurlong.wezterm"));
        assert!(!submits_on_enter("firefox"));
        assert!(!submits_on_enter(""));
    }
}
