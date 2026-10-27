//! Clean-up styles from `GET /v1/correction/profiles`. Prompts stay on the server.

use serde::Serialize;
use serde_json::Value;

/// Hidden Live Notes style. Never offered in the picker and never sent for dictation.
const LIVE_NOTES: &str = "live_notes";

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Style {
    pub id: String,
    pub name: String,
    pub description: String,
    pub rewrites: bool,
}

/// Styles a current Chirp server offers when it cannot be asked. `live_notes` is omitted.
pub fn builtins() -> Vec<Style> {
    [
        (
            "default",
            "Default",
            "Conservative transcript cleanup.",
            false,
        ),
        (
            "chat",
            "Chat",
            "Casual messages; no period on short messages.",
            false,
        ),
        (
            "email",
            "Email",
            "Polished sentences with light formality, without added content.",
            false,
        ),
        (
            "code",
            "Code",
            "Literal technical dictation; preserve identifiers, symbols and casing.",
            false,
        ),
        (
            "notes",
            "Notes",
            "Short sentences or bullets for spoken lists.",
            true,
        ),
        (
            "custom",
            "Custom",
            "Cleanup shaped by your instructions, within transcript safety rules.",
            true,
        ),
    ]
    .into_iter()
    .map(|(id, name, description, rewrites)| Style {
        id: id.into(),
        name: name.into(),
        description: description.into(),
        rewrites,
    })
    .collect()
}

/// Server profile ids: a lowercase letter, then up to 63 letters, digits, `_` or `-`.
pub fn is_valid_id(id: &str) -> bool {
    let mut chars = id.chars();
    match chars.next() {
        Some(first) if first.is_ascii_lowercase() => {}
        _ => return false,
    }
    id != LIVE_NOTES
        && id.len() <= 64
        && id
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-')
}

/// The id to send as `correction_profile`. Unknown or hidden ids become `default`.
pub fn wire_id(value: &str) -> String {
    let id = value.trim();
    if is_valid_id(id) {
        id.to_owned()
    } else {
        "default".into()
    }
}

/// Parse the styles API. Prompt text is dropped. `live_notes` is removed. Custom stays last.
pub fn parse_profiles(value: &Value) -> Result<Vec<Style>, String> {
    let list = value["profiles"]
        .as_array()
        .ok_or("Your computer sent no clean-up styles")?;
    let mut styles = Vec::new();
    for item in list {
        let Some(id) = item["id"]
            .as_str()
            .map(str::trim)
            .filter(|id| is_valid_id(id))
        else {
            continue;
        };
        if styles.iter().any(|style: &Style| style.id == id) {
            continue;
        }
        let name = item["name"]
            .as_str()
            .map(str::trim)
            .filter(|name| !name.is_empty())
            .unwrap_or(id);
        let description = item["description"].as_str().unwrap_or("").trim();
        styles.push(Style {
            id: id.to_owned(),
            name: clamp(name, 80),
            description: clamp(description, 300),
            rewrites: item["rewrites"].as_bool().unwrap_or(false),
        });
    }
    if styles.is_empty() {
        return Err("Your computer sent no clean-up styles".into());
    }
    let custom = styles.iter().position(|style| style.id == "custom");
    if let Some(index) = custom {
        let style = styles.remove(index);
        styles.push(style);
    }
    Ok(styles)
}

fn clamp(value: &str, max_chars: usize) -> String {
    value.chars().take(max_chars).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn hidden_and_invalid_ids_never_leave_the_client() {
        assert!(is_valid_id("default"));
        assert!(is_valid_id("chat"));
        assert!(!is_valid_id("live_notes"));
        assert!(!is_valid_id("Default"));
        assert!(!is_valid_id(""));
        assert!(!is_valid_id("has space"));
        assert_eq!(wire_id(" email "), "email");
        assert_eq!(wire_id("live_notes"), "default");
        assert_eq!(wire_id("../etc"), "default");
    }

    #[test]
    fn profiles_drop_prompts_and_the_hidden_notes_style() {
        let secret = "SECRET-PROMPT-TEXT";
        let parsed = parse_profiles(&json!({"profiles": [
            {"id":"custom","name":"Custom","description":"Yours","rewrites":true,"prompt":secret},
            {"id":"live_notes","name":"Live","description":"hidden","prompt":secret},
            {"id":"email","name":"Email","description":"Polished.","prompt":secret},
            {"id":"Email","name":"Bad"},
            {"id":"email","name":"Duplicate"},
        ]}))
        .unwrap();
        assert_eq!(
            parsed
                .iter()
                .map(|style| style.id.as_str())
                .collect::<Vec<_>>(),
            ["email", "custom"]
        );
        assert!(parsed[1].rewrites);
        let encoded = serde_json::to_string(&parsed).unwrap();
        assert!(!encoded.contains(secret));
        assert!(!encoded.contains("prompt"));
    }

    #[test]
    fn builtins_match_the_server_list_without_live_notes() {
        let ids: Vec<_> = builtins().into_iter().map(|style| style.id).collect();
        assert_eq!(ids, ["default", "chat", "email", "code", "notes", "custom"]);
    }
}
