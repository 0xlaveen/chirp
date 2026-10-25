//! Frozen Chirp v1 client. No transcript, URL credentials or tokens enter logs.
use crate::{audio, settings::{stream_url, Settings}};
use futures_util::{SinkExt, StreamExt};
use serde::Serialize;
use serde_json::{json, Value};
use std::time::Duration;
use tokio::sync::{mpsc, watch};
use tokio_tungstenite::{connect_async, tungstenite::{client::IntoClientRequest, Message}};

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Control { Running, Stop, Cancel }

#[derive(Clone, Serialize)]
pub struct Update {
    pub state: String,
    pub text: String,
    pub detail: String,
    pub debug_retention: bool,
}
impl Update {
    pub fn new(state: &str, text: &str, detail: &str) -> Self {
        Self { state: state.into(), text: text.into(), detail: detail.into(), debug_retention: false }
    }
}

async fn receive<S>(socket: &mut S) -> Result<Value, String>
where S: futures_util::Stream<Item=Result<Message, tokio_tungstenite::tungstenite::Error>> + Unpin {
    loop {
        match socket.next().await {
            Some(Ok(Message::Text(text))) if text.len() < 1024 * 1024 => {
                let value: Value = serde_json::from_str(&text).map_err(|_| "Server sent an invalid response")?;
                if value["type"] == "error" {
                    return Err(match value["code"].as_str() {
                        Some("auth") => "Pairing was refused. Pair with your server again.",
                        Some("busy") => "The server is busy. Try again.",
                        Some("too_long") => "This dictation reached the server duration limit.",
                        _ => "The server could not transcribe this dictation.",
                    }.into());
                }
                return Ok(value);
            }
            Some(Ok(Message::Ping(_) | Message::Pong(_))) => continue,
            _ => return Err("Server connection closed".into()),
        }
    }
}

pub async fn dictate(
    settings: Settings,
    token: String,
    mut control: watch::Receiver<Control>,
    fixture: Option<mpsc::Receiver<Result<Vec<u8>, String>>>,
    emit: impl Fn(Update),
) -> Result<String, String> {
    let url = stream_url(&settings.url)?;
    let mut request = url.as_str().into_client_request().map_err(|_| "Invalid server URL")?;
    request.headers_mut().insert("Authorization", format!("Bearer {token}").parse().map_err(|_| "Invalid server token")?);
    emit(Update::new("connecting", "", "Connecting to your server…"));
    let connecting = async {
        let (mut socket, _) = connect_async(request).await.map_err(|_| "Could not connect to your server")?;
        socket.send(Message::Text(json!({"type":"start", "sample_rate":16000,
            "encoding":"pcm_s16le", "client":"desktop", "correction": settings.correction}).to_string().into()))
            .await.map_err(|_| "Could not start dictation")?;
        let ready = receive(&mut socket).await?;
        if ready["type"] != "ready" { return Err("Server did not accept dictation".into()); }
        Ok::<_, String>((socket, ready["debug_retention"].as_bool().unwrap_or(false)))
    };
    let (mut socket, debug) = tokio::select! {
        result = tokio::time::timeout(Duration::from_secs(30), connecting) => result.map_err(|_| "Server connection timed out")??,
        _ = control.changed() => return Err("cancelled".into()),
    };
    if *control.borrow() != Control::Running { return Err("cancelled".into()); }
    let mut audio = match fixture {
        Some(rx) => rx,
        None => {
            let (tx, rx) = mpsc::channel(64);
            audio::capture(tx, control.clone());
            rx
        }
    };
    let mut update = Update::new("listening", "", "Listening…"); update.debug_retention = debug; emit(update);
    let mut stopped = false;
    let mut total_bytes = 0usize;
    let mut deadline = tokio::time::Instant::now() + Duration::from_secs(120);
    loop {
        tokio::select! {
            biased;
            changed = control.changed() => {
                if changed.is_err() || *control.borrow() == Control::Cancel {
                    let _ = socket.close(None).await;
                    return Err("cancelled".into());
                }
                // Stop ends native capture; its queue drains before the stop frame.
            }
            packet = audio.recv(), if !stopped => {
                match packet {
                    Some(Ok(bytes)) => {
                        if bytes.len() % 2 != 0 { return Err("Invalid PCM frame".into()); }
                        total_bytes += bytes.len();
                        if total_bytes > 120 * 32000 { return Err("Dictation is limited to 120 seconds. Stop and start another dictation.".into()); }
                        socket.send(Message::Binary(bytes.into())).await.map_err(|_| "Audio connection was lost")?;
                    }
                    Some(Err(error)) => return Err(error),
                    None => {
                        socket.send(Message::Text(json!({"type":"stop"}).to_string().into())).await.map_err(|_| "Could not finish dictation")?;
                        stopped = true;
                        deadline = tokio::time::Instant::now() + Duration::from_secs(60);
                        let mut update = Update::new("processing", "", "Finishing…"); update.debug_retention = debug; emit(update);
                    }
                }
            }
            message = receive(&mut socket) => {
                let value = message?;
                match value["type"].as_str() {
                    Some("partial") | Some("correcting") => {
                        let mut update = Update::new(if stopped {"processing"} else {"listening"}, value["text"].as_str().unwrap_or(""), if stopped {"Finishing…"} else {"Listening…"});
                        update.debug_retention = debug; emit(update);
                    }
                    Some("final") if stopped => return value["text"].as_str().map(str::to_owned).ok_or("Server final has no text".into()),
                    _ => return Err("Unexpected server response".into()),
                }
            }
            _ = tokio::time::sleep_until(deadline) => return Err(if stopped {"Final transcription timed out"} else {"Dictation reached the 120 second limit"}.into()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::net::TcpListener;
    use tokio_tungstenite::accept_async;
    #[tokio::test]
    async fn actual_socket_streams_pcm_then_waits_for_final() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = tokio::spawn(async move {
            let (tcp, _) = listener.accept().await.unwrap();
            let mut ws = accept_async(tcp).await.unwrap();
            let start = receive(&mut ws).await.unwrap();
            assert_eq!(start["client"], "desktop"); assert_eq!(start["sample_rate"], 16000);
            ws.send(Message::Text(json!({"type":"ready"}).to_string().into())).await.unwrap();
            assert_eq!(ws.next().await.unwrap().unwrap().into_data().len(), 1600);
            assert_eq!(receive(&mut ws).await.unwrap()["type"], "stop");
            ws.send(Message::Text(json!({"type":"partial","text":"test"}).to_string().into())).await.unwrap();
            ws.send(Message::Text(json!({"type":"final","text":"Test sentence."}).to_string().into())).await.unwrap();
        });
        let settings = Settings { url: format!("http://127.0.0.1:{port}"), ..Settings::default() };
        let (tx, rx) = mpsc::channel(4); tx.send(Ok(vec![0;1600])).await.unwrap(); drop(tx);
        let (_control, receiver) = watch::channel(Control::Running);
        assert_eq!(dictate(settings, "synthetic-test-token".into(), receiver, Some(rx), |_| {}).await.unwrap(), "Test sentence.");
        server.await.unwrap();
    }
    #[tokio::test]
    async fn cancellation_during_connect_is_bounded() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let settings = Settings { url: format!("http://{}", listener.local_addr().unwrap()), ..Settings::default() };
        let (control, rx) = watch::channel(Control::Running);
        let run = tokio::spawn(dictate(settings, "test".into(), rx, None, |_| {}));
        control.send(Control::Cancel).unwrap();
        assert!(tokio::time::timeout(Duration::from_secs(1), run).await.unwrap().unwrap().is_err());
    }
}
