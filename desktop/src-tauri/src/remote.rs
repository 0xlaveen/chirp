//! Authenticated HTTP reads of your computer's Chirp server. No prompts or tokens are logged.

use crate::settings::{self, Settings};
use serde_json::Value;
use std::time::Duration;

fn endpoint(settings: &Settings, path: &str) -> Result<url::Url, String> {
    settings::stream_url(&settings.url)?;
    let mut url = url::Url::parse(&settings.url).map_err(|_| "Invalid server URL")?;
    let base = url.path().trim_end_matches('/');
    url.set_path(&format!("{base}/{path}"));
    url.set_query(None);
    url.set_fragment(None);
    Ok(url)
}

async fn get_json(
    settings: &Settings,
    token: &str,
    path: &str,
    limit: usize,
) -> Result<Value, String> {
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(8))
        .build()
        .map_err(|_| "Could not reach your computer")?;
    let response = client
        .get(endpoint(settings, path)?)
        .bearer_auth(token)
        .send()
        .await
        .map_err(|_| "Could not reach your computer")?;
    if response.status().as_u16() == 404 {
        return Err("not-found".into());
    }
    if !response.status().is_success() {
        return Err("Your computer did not answer".into());
    }
    let mut response = response;
    let mut bytes = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| "Your computer did not answer")?
    {
        if bytes.len() + chunk.len() > limit {
            return Err("Your computer sent a response that is too large".into());
        }
        bytes.extend_from_slice(&chunk);
    }
    serde_json::from_slice(&bytes).map_err(|_| "Your computer sent an invalid response".into())
}

/// Authenticated health. `None` when the token was not accepted (the public body is only `{"ok":true}`).
pub async fn authenticated_health(
    settings: &Settings,
    token: &str,
) -> Result<Option<Value>, String> {
    let value = get_json(settings, token, "v1/health", 64 * 1024).await?;
    let accepted = value.get("engine").is_some() || value.get("ready").is_some();
    Ok(accepted.then_some(value))
}

pub async fn correction_profiles(settings: &Settings, token: &str) -> Result<Value, String> {
    get_json(settings, token, "v1/correction/profiles", 512 * 1024).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::{
        io::{AsyncReadExt, AsyncWriteExt},
        net::TcpListener,
    };

    async fn once(status: &str, body: &str) -> Settings {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let status = status.to_owned();
        let body = body.to_owned();
        tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = String::new();
            let mut buf = [0u8; 1024];
            while !request.contains("\r\n\r\n") {
                let n = socket.read(&mut buf).await.unwrap();
                assert!(n > 0, "request ended before headers");
                request.push_str(&String::from_utf8_lossy(&buf[..n]));
            }
            // Hyper writes header names in lowercase.
            let headers = request.to_ascii_lowercase();
            assert!(headers.contains("authorization: bearer synthetic-test-token"));
            assert!(!request.contains("SECRET"));
            let response = format!(
                "HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            socket.write_all(response.as_bytes()).await.unwrap();
        });
        Settings {
            url: format!("http://127.0.0.1:{port}/chirp"),
            ..Settings::default()
        }
    }

    #[tokio::test]
    async fn health_requires_an_authenticated_body() {
        let settings = once("200 OK", r#"{"ok":true,"engine":"test","ready":true}"#).await;
        let value = authenticated_health(&settings, "synthetic-test-token")
            .await
            .unwrap();
        assert_eq!(value.unwrap()["engine"], "test");

        let settings = once("200 OK", r#"{"ok":true}"#).await;
        assert!(authenticated_health(&settings, "synthetic-test-token")
            .await
            .unwrap()
            .is_none());
    }

    #[tokio::test]
    async fn profiles_are_read_and_redirects_are_not_followed() {
        let settings = once(
            "200 OK",
            r#"{"profiles":[{"id":"chat","name":"Chat","description":"Casual","prompt":"SECRET-PROMPT"}]}"#,
        )
        .await;
        let value = correction_profiles(&settings, "synthetic-test-token")
            .await
            .unwrap();
        assert_eq!(value["profiles"][0]["id"], "chat");

        let settings = once("302 Found", "").await;
        assert!(correction_profiles(&settings, "synthetic-test-token")
            .await
            .is_err());
    }

    #[test]
    fn endpoint_keeps_a_server_prefix() {
        let settings = Settings {
            url: "https://example.test/chirp/".into(),
            ..Settings::default()
        };
        assert_eq!(
            endpoint(&settings, "v1/health").unwrap().as_str(),
            "https://example.test/chirp/v1/health"
        );
    }
}
