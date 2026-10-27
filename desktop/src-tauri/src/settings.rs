use crate::{
    auto_enter::AutoEnter,
    hotkey::{HotKey, HotkeyMode},
    platform, styles,
};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use url::Url;

// Deliberately no Debug: credentials must never appear in diagnostics.
#[derive(Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    pub url: String,
    pub hotkey: HotKey,
    pub mode: HotkeyMode,
    pub correction: bool,
    /// A `correction_profiles` id. `default` until the user picks another style.
    pub correction_style: String,
    /// `off`, `action` (On Send, Go or Done) or `always`.
    pub auto_enter: String,
    pub spoken_commands: bool,
    pub history_enabled: bool,
    pub history_days: u32,
    pub portal_enabled: bool,
    pub portal_shortcut: String,
}
impl Default for Settings {
    fn default() -> Self {
        Self {
            url: "http://127.0.0.1:7821".into(),
            hotkey: platform::native().default_hotkey(),
            mode: HotkeyMode::Hold,
            correction: false,
            correction_style: "default".into(),
            auto_enter: AutoEnter::Off.as_str().into(),
            spoken_commands: false,
            history_enabled: true,
            history_days: 7,
            portal_enabled: false,
            portal_shortcut: "CTRL+ALT+space".into(),
        }
    }
}

pub fn stream_url(value: &str) -> Result<Url, String> {
    let mut url = Url::parse(value).map_err(|_| "Enter an HTTP or HTTPS server URL")?;
    if !matches!(url.scheme(), "http" | "https")
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err("Use an HTTP(S) server URL without credentials, query or fragment".into());
    }
    let scheme = if url.scheme() == "https" { "wss" } else { "ws" };
    url.set_scheme(scheme).map_err(|_| "Invalid server URL")?;
    url.set_path(&format!("{}/v1/stream", url.path().trim_end_matches('/')));
    Ok(url)
}

pub fn validate_portal_trigger(value: &str) -> Result<(), String> {
    if value.is_empty()
        || value.len() > 80
        || !value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"+_-".contains(&b))
    {
        return Err("Use an XDG shortcut such as CTRL+ALT+space".into());
    }
    Ok(())
}

pub fn pairing(value: &str) -> Result<(String, String), String> {
    let url = Url::parse(value.trim()).map_err(|_| "Invalid pairing link")?;
    if url.scheme() != "chirp" || url.host_str() != Some("pair") {
        return Err("Paste the chirp://pair link from your server".into());
    }
    let pairs: Vec<_> = url.query_pairs().collect();
    let find = |key| {
        pairs
            .iter()
            .filter(|(k, _)| k == key)
            .map(|(_, v)| v.to_string())
            .collect::<Vec<_>>()
    };
    let server = find("url");
    let token = find("token");
    if server.len() != 1 || token.len() != 1 || token[0].trim().is_empty() {
        return Err("Pairing link needs exactly one server URL and token".into());
    }
    stream_url(&server[0])?;
    Ok((server[0].clone(), token[0].clone()))
}

fn path() -> Result<PathBuf, String> {
    let root = if cfg!(target_os = "windows") {
        std::env::var_os("APPDATA").map(PathBuf::from)
    } else if cfg!(target_os = "macos") {
        std::env::var_os("HOME").map(|p| PathBuf::from(p).join("Library/Application Support"))
    } else {
        std::env::var_os("XDG_CONFIG_HOME")
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(|p| PathBuf::from(p).join(".config")))
    }
    .ok_or("Cannot locate the user configuration directory")?;
    Ok(root.join("chirp-desktop").join("settings.json"))
}
impl Settings {
    pub fn auto_enter_mode(&self) -> AutoEnter {
        AutoEnter::parse(&self.auto_enter).unwrap_or(AutoEnter::Off)
    }

    pub fn read() -> Self {
        path()
            .ok()
            .and_then(|p| std::fs::read(p).ok())
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default()
    }
    pub fn save(&self) -> Result<(), String> {
        stream_url(&self.url)?;
        if ![1, 7, 30].contains(&self.history_days) {
            return Err("Choose 24 hours, 7 days or 30 days for history".into());
        }
        if AutoEnter::parse(&self.auto_enter).is_none() {
            return Err("Choose Off, On Send, Go or Done, or Always".into());
        }
        if !styles::is_valid_id(&self.correction_style) {
            return Err("Choose a clean-up style".into());
        }
        validate_portal_trigger(&self.portal_shortcut)?;
        let path = path()?;
        std::fs::create_dir_all(path.parent().ok_or("Invalid settings directory")?)
            .map_err(|_| "Could not create settings directory")?;
        // This file only contains preferences. Credentials live in the OS credential store.
        let bytes = serde_json::to_vec_pretty(self).map_err(|_| "Could not encode settings")?;
        std::fs::write(path, bytes).map_err(|_| "Could not save settings".into())
    }
}
fn entry() -> Result<keyring::Entry, String> {
    keyring::Entry::new("dev.chirp.desktop", "server-token")
        .map_err(|_| "System credential store is unavailable".into())
}
pub fn token() -> Result<String, String> {
    entry()?
        .get_password()
        .map_err(|_| "Pair with your server first; unlock your system keyring if needed".into())
}
pub fn save_token(token: &str) -> Result<(), String> {
    if token.is_empty() || token.len() > 4096 || token.contains(['\r', '\n']) {
        return Err("Invalid server token".into());
    }
    entry()?
        .set_password(token)
        .map_err(|_| "Could not save token; unlock your system keyring and try again".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn preserves_server_prefix_and_rejects_credential_urls() {
        assert_eq!(
            stream_url("https://example.test/chirp/").unwrap().as_str(),
            "wss://example.test/chirp/v1/stream"
        );
        for url in [
            "file:///tmp/a",
            "https://user:secret@example.test",
            "https://example.test?token=secret",
            "https://example.test/#token",
        ] {
            assert!(stream_url(url).is_err());
        }
    }
    #[test]
    fn pairing_is_unambiguous_and_preferences_have_no_token() {
        let (url, token) =
            pairing("chirp://pair?url=http%3A%2F%2Flocalhost%3A7899&token=test-secret").unwrap();
        assert_eq!(url, "http://localhost:7899");
        assert_eq!(token, "test-secret");
        assert!(pairing("chirp://pair?url=http://localhost&token=a&token=b").is_err());
        assert!(!serde_json::to_string(&Settings::default())
            .unwrap()
            .contains("token"));
    }
}

#[cfg(test)]
mod portal_tests {
    use super::*;
    #[test]
    fn old_preferences_keep_native_defaults_and_do_not_open_a_portal_dialog() {
        let settings: Settings = serde_json::from_str(r#"{"url":"http://localhost:7899","hotkey":"RightAlt","mode":"Hold","correction":false}"#).unwrap();
        assert!(!settings.portal_enabled);
        assert!(settings.history_enabled);
        assert_eq!(settings.history_days, 7);
        assert!(!settings.spoken_commands);
        assert_eq!(settings.correction_style, "default");
        assert_eq!(settings.auto_enter, "off");
        assert_eq!(settings.portal_shortcut, "CTRL+ALT+space");
        assert_eq!(settings.hotkey, HotKey::RightAlt);
    }
    #[test]
    fn shortcut_hint_accepts_xdg_keys_but_rejects_control_or_unbounded_input() {
        assert!(validate_portal_trigger("CTRL+ALT+space").is_ok());
        assert!(validate_portal_trigger("Control_R").is_ok());
        for value in ["", "CTRL+\nspace", "CTRL+ALT+<script>"] {
            assert!(validate_portal_trigger(value).is_err());
        }
        assert!(validate_portal_trigger(&"A".repeat(81)).is_err());
    }
}
