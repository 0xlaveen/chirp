//! Opt-in trailing commands shared with the phones and Mac. Never applied to raw text.
pub fn apply(text: &str, enabled: bool) -> String {
    if enabled {
        let lower = text.to_ascii_lowercase();
        for (phrase, breaks) in [("new paragraph", "\n\n"), ("new line", "\n")] {
            if let Some(start) = lower.rfind(phrase) {
                let before = &text[..start];
                let after = &text[start + phrase.len()..];
                if (before.is_empty() || before.ends_with(char::is_whitespace))
                    && after
                        .chars()
                        .all(|c| c.is_whitespace() || ".,!?…".contains(c))
                {
                    return format!("{}{breaks}", before.trim_end());
                }
            }
        }
    }
    text.into()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_opt_in_whole_or_trailing_commands_are_converted() {
        for (text, expected) in [
            ("New line!", "\n"),
            ("Hello NEW PARAGRAPH… ", "Hello\n\n"),
            ("First. new line", "First.\n"),
            ("Say new line please", "Say new line please"),
            ("a new paragraph in a book", "a new paragraph in a book"),
            ("renew line", "renew line"),
            ("新しい文 new line", "新しい文\n"),
            ("new line new paragraph", "new line\n\n"),
            ("new line:", "new line:"),
        ] {
            assert_eq!(apply(text, true), expected);
            assert_eq!(apply(text, false), text);
        }
    }
}
