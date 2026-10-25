//! Notes capture uses the same native PCM and frozen v1 stream as dictation.
//! Each completed segment is durable before a smart-notes request can start.
use crate::{
    audio, files,
    library::{Entry, Library, Note},
    protocol::{self, Control, Update},
    settings::{self, Settings},
};
use serde::Serialize;
use serde_json::{json, Value};
use std::{
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Mutex,
    },
    time::Duration,
};
use tauri::{Emitter, Manager};
use tokio::sync::{mpsc, oneshot, watch};

type Store = Arc<Mutex<Option<Library>>>;
pub struct NotesRuntime {
    pub active: Mutex<Option<Active>>,
    store: Store,
    flush: Mutex<Option<(u64, oneshot::Sender<bool>)>>,
    flush_sequence: AtomicU64,
}
pub struct Active {
    pub id: String,
    control: watch::Sender<Control>,
    done: watch::Receiver<bool>,
    pause: Arc<AtomicBool>,
}
impl Default for NotesRuntime {
    fn default() -> Self {
        Self {
            active: Mutex::new(None),
            store: Arc::new(Mutex::new(None)),
            flush: Mutex::new(None),
            flush_sequence: AtomicU64::new(0),
        }
    }
}
fn stored<T>(
    store: &Store,
    f: impl FnOnce(&mut Library) -> Result<T, String>,
) -> Result<T, String> {
    let mut slot = store.lock().map_err(|_| "Notes storage unavailable")?;
    if slot.is_none() {
        *slot = Some(Library::open(&files::notes_root()?)?);
    }
    f(slot.as_mut().ok_or("Notes storage unavailable")?)
}
async fn work<T: Send + 'static>(
    app: tauri::AppHandle,
    f: impl FnOnce(&mut Library) -> Result<T, String> + Send + 'static,
) -> Result<T, String> {
    let store = app.state::<NotesRuntime>().store.clone();
    tauri::async_runtime::spawn_blocking(move || stored(&store, f))
        .await
        .map_err(|_| "Notes storage unavailable")?
}
fn changed(app: &tauri::AppHandle, id: &str) {
    let _ = app.emit("notes-changed", id);
}
#[derive(Serialize)]
pub struct List {
    entries: Vec<Entry>,
    active: Option<String>,
    warnings: usize,
}
#[tauri::command]
pub async fn notes_list(app: tauri::AppHandle, query: String, trash: bool) -> Result<List, String> {
    let active = app
        .state::<NotesRuntime>()
        .active
        .lock()
        .map_err(|_| "Recording unavailable")?
        .as_ref()
        .map(|a| a.id.clone());
    work(app, move |lib| {
        Ok(List {
            entries: lib.list(&query, trash),
            active,
            warnings: lib.warnings,
        })
    })
    .await
}
#[tauri::command]
pub async fn notes_create(app: tauri::AppHandle) -> Result<Note, String> {
    work(app, |l| l.create()).await
}
#[tauri::command]
pub async fn notes_get(app: tauri::AppHandle, id: String) -> Result<Note, String> {
    work(app, move |l| l.get(&id)).await
}
#[tauri::command]
pub async fn notes_edit(
    app: tauri::AppHandle,
    id: String,
    version: u64,
    body: String,
    title: Option<String>,
) -> Result<Note, String> {
    let result = work(app.clone(), move |l| l.edit(&id, version, body, title)).await?;
    changed(&app, &result.id);
    Ok(result)
}
#[tauri::command]
pub async fn notes_trash(app: tauri::AppHandle, id: String, deleted: bool) -> Result<(), String> {
    let current = id.clone();
    work(app.clone(), move |l| l.trash(&id, deleted)).await?;
    changed(&app, &current);
    Ok(())
}
#[tauri::command]
pub async fn notes_discard_blank(app: tauri::AppHandle, id: String) -> Result<(), String> {
    work(app, move |l| l.discard_blank(&id)).await
}
#[tauri::command]
pub async fn notes_empty_trash(app: tauri::AppHandle) -> Result<(), String> {
    work(app.clone(), |l| l.empty_trash()).await?;
    changed(&app, "");
    Ok(())
}
#[tauri::command]
pub async fn notes_undo_organize(app: tauri::AppHandle, id: String) -> Result<Note, String> {
    let n = work(app.clone(), move |l| l.undo_organize(&id)).await?;
    changed(&app, &n.id);
    Ok(n)
}

fn http_url(settings: &Settings, path: &str) -> Result<url::Url, String> {
    settings::stream_url(&settings.url)?;
    let mut url = url::Url::parse(&settings.url).map_err(|_| "Invalid server URL")?;
    url.set_path(&format!("{}/{}", url.path().trim_end_matches('/'), path));
    Ok(url)
}
pub async fn smart(
    settings: &Settings,
    token: &str,
    text: &str,
    organize: bool,
) -> Result<String, String> {
    let limit = if organize { 3500 } else { 6000 };
    if text.trim().is_empty() || text.chars().count() > limit {
        return Err(format!(
            "Use {} for up to {limit} characters at a time",
            if organize { "Organize" } else { "smart notes" }
        ));
    }
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(if organize { 125 } else { 55 }))
        .build()
        .map_err(|_| "Cannot start smart notes")?;
    let payload = if organize {
        json!({"notes":text,"outline":[],"final":true})
    } else {
        json!({"transcript":text,"outline":[]})
    };
    let response = client
        .post(http_url(
            settings,
            if organize {
                "v1/notes/reorganize"
            } else {
                "v1/notes/structure"
            },
        )?)
        .bearer_auth(token)
        .json(&payload)
        .send()
        .await
        .map_err(|_| "Smart notes unavailable; your transcript was kept")?;
    if !response.status().is_success() {
        return Err(if response.status().as_u16() == 409 {
            "Enable a cleanup model on your server to use smart notes"
        } else {
            "Smart notes unavailable; your transcript was kept"
        }
        .into());
    }
    if response.content_length().is_some_and(|n| n > 128 * 1024) {
        return Err("Smart notes response is too large".into());
    }
    // Bound streamed responses too, including chunked responses without Content-Length.
    let mut response = response;
    let mut bytes = vec![];
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| "Smart notes response interrupted")?
    {
        if bytes.len() + chunk.len() > 128 * 1024 {
            return Err("Smart notes response is too large".into());
        }
        bytes.extend_from_slice(&chunk);
    }
    let result: Value =
        serde_json::from_slice(&bytes).map_err(|_| "Invalid smart notes response")?;
    if result[if organize {
        "reorganized"
    } else {
        "structured"
    }] != true
    {
        return Err(
            "The server kept the original text; no safe smart-notes result was available".into(),
        );
    }
    result["markdown"]
        .as_str()
        .filter(|s| !s.trim().is_empty())
        .map(str::to_owned)
        .ok_or("Smart notes returned no text".into())
}
#[derive(Serialize)]
pub struct OrganizeProposal {
    id: String,
    version: u64,
    markdown: String,
}
#[tauri::command]
pub async fn notes_organize(app: tauri::AppHandle, id: String) -> Result<OrganizeProposal, String> {
    let settings = app
        .state::<crate::Runtime>()
        .settings
        .lock()
        .map_err(|_| "Settings unavailable")?
        .clone();
    let token = settings::token()?;
    let key = id.clone();
    let n = work(app.clone(), move |l| l.get(&key)).await?;
    if n.recording || n.paused {
        return Err("Stop recording before organizing the whole note".into());
    }
    let markdown = smart(&settings, &token, &n.body, true).await?;
    Ok(OrganizeProposal {
        id,
        version: n.body_version,
        markdown,
    })
}
#[tauri::command]
pub async fn notes_apply_organize(
    app: tauri::AppHandle,
    id: String,
    version: u64,
    markdown: String,
) -> Result<Note, String> {
    if markdown.len() > 128 * 1024 {
        return Err("Organized text is too large".into());
    }
    let result = work(app.clone(), move |l| l.organize(&id, version, markdown)).await?;
    changed(&app, &result.id);
    Ok(result)
}
#[tauri::command]
pub async fn notes_export(app: tauri::AppHandle, id: String) -> Result<bool, String> {
    use tauri_plugin_dialog::DialogExt;
    let note = work(app.clone(), move |l| l.get(&id)).await?;
    let file = app
        .dialog()
        .file()
        .add_filter("Markdown", &["md"])
        .set_file_name("note.md")
        .blocking_save_file();
    let Some(file) = file else {
        return Ok(false);
    };
    let path: PathBuf = file.into_path().map_err(|_| "Choose a local export file")?;
    tauri::async_runtime::spawn_blocking(move || files::atomic(&path, note.markdown().as_bytes()))
        .await
        .map_err(|_| "Export failed")??;
    Ok(true)
}

/// A single stream consumes at most segment_bytes. Stop drains the source, including its final frame.
/// Audio continues into a bounded native queue while a previous stream waits for its final result.
pub async fn segments(
    mut settings: Settings,
    token: String,
    mut control: watch::Receiver<Control>,
    mut source: mpsc::Receiver<Result<Vec<u8>, String>>,
    segment_bytes: usize,
    mut on_segment: impl FnMut(String, u64) -> Result<(), String>,
    emit: impl Fn(Update) + Clone + Send + 'static,
) -> Result<(), String> {
    settings.correction = false;
    loop {
        if *control.borrow() == Control::Cancel {
            return Err("cancelled".into());
        }
        let first = tokio::select! {biased;changed=control.changed()=>{if changed.is_err()||*control.borrow()==Control::Cancel{return Err("cancelled".into());}continue;},packet=source.recv()=>packet};
        let Some(first) = first else {
            return Ok(());
        };
        let first = first?;
        if first.is_empty() {
            continue;
        }
        let (tx, rx) = mpsc::channel(64);
        let mut cancel = control.clone();
        let bridge = tokio::spawn(async move {
            let mut bytes = 0;
            let mut eof = false;
            let mut packet = Some(first);
            loop {
                if *cancel.borrow() == Control::Cancel {
                    return (source, bytes, true);
                }
                let value = match packet.take() {
                    Some(value) => Some(Ok(value)),
                    None => tokio::select! {
                        biased; _=cancel.changed()=>{if *cancel.borrow()==Control::Cancel{return (source,bytes,true);}continue;},v=source.recv()=>v,
                    },
                };
                match value {
                    Some(Ok(value)) => {
                        bytes += value.len();
                        if tx.send(Ok(value)).await.is_err() {
                            break;
                        }
                        if bytes >= segment_bytes {
                            break;
                        }
                    }
                    Some(Err(e)) => {
                        let _ = tx.send(Err(e)).await;
                        eof = true;
                        break;
                    }
                    None => {
                        eof = true;
                        break;
                    }
                }
            }
            (source, bytes, eof)
        });
        let (signal, receiver) = watch::channel(Control::Running);
        let mut final_control = control.clone();
        let run = protocol::dictate(
            settings.clone(),
            token.clone(),
            receiver,
            Some(rx),
            emit.clone(),
        );
        tokio::pin!(run);
        let result = loop {
            tokio::select! {result=&mut run=>break result,changed=final_control.changed()=>{
                if changed.is_err()||*final_control.borrow()==Control::Cancel {let _=signal.send(Control::Cancel);}
            }}
        };
        if let Err(error) = result {
            bridge.abort();
            return Err(error);
        }
        let text = result?;
        let (returned, bytes, eof) = bridge.await.map_err(|_| "Audio segment failed")?;
        source = returned;
        if *control.borrow() == Control::Cancel {
            return Err("cancelled".into());
        }
        on_segment(text, bytes as u64 * 1000 / 32000)?;
        if eof {
            return Ok(());
        }
    }
}

#[tauri::command]
pub fn notes_record(app: tauri::AppHandle, id: String, structure: bool) -> Result<(), String> {
    let runtime = app.state::<crate::Runtime>();
    // All starts use this lock order: dictation, then Notes.
    let dictation = runtime.active.lock().map_err(|_| "Session unavailable")?;
    if dictation.is_some() {
        return Err("Stop dictation before recording a note".into());
    }
    let state = app.state::<NotesRuntime>();
    let mut active = state.active.lock().map_err(|_| "Recording unavailable")?;
    if active.is_some() {
        return Err("Stop the current recording before continuing here".into());
    }
    let settings = runtime
        .settings
        .lock()
        .map_err(|_| "Settings unavailable")?
        .clone();
    let token = settings::token()?;
    stored(&state.store, |lib| {
        lib.set_recording(&id, true, false, true, "").map(|_| ())
    })?;
    let (control, rx) = watch::channel(Control::Running);
    let (done, completed) = watch::channel(false);
    let pause = Arc::new(AtomicBool::new(false));
    *active = Some(Active {
        id: id.clone(),
        control: control.clone(),
        done: completed,
        pause: pause.clone(),
    });
    let store = state.store.clone();
    changed(&app, &id);
    let task_app = app.clone();
    tauri::async_runtime::spawn(async move {
        let app = task_app;
        let (tx, audio) = mpsc::channel(2400);
        audio::capture(tx, rx.clone());
        // Serial processing preserves segment order; each job has an immutable note id.
        let (jobs, mut pending) = mpsc::channel::<(String, String)>(8);
        let job_store = store.clone();
        let job_id = id.clone();
        let job_app = app.clone();
        let job_settings = settings.clone();
        let job_token = token.clone();
        tauri::async_runtime::spawn(async move {
            let mut enabled = structure;
            while let Some((sid, text)) = pending.recv().await {
                let response = if enabled {
                    smart(&job_settings, &job_token, &text, false).await
                } else {
                    Err(String::new())
                };
                let (markdown, structured) = match response {
                    Ok(s) => (s, true),
                    Err(error) => {
                        if enabled && !error.is_empty() {
                            let _ =
                                job_app.emit("notes-status", json!({"id":job_id,"detail":error}));
                        }
                        enabled = false;
                        (text, false)
                    }
                };
                if stored(&job_store, |lib| {
                    lib.append_notes(&job_id, &sid, &markdown, structured)
                })
                .is_err()
                {
                    let _=job_app.emit("notes-status",json!({"id":job_id,"detail":"Could not save smart notes; the transcript was kept. Check local storage."}));
                }
                changed(&job_app, &job_id);
            }
        });
        let update_app = app.clone();
        let update_id = id.clone();
        let result=segments(settings,token,rx,audio,45*32000,|text,duration|{
            let (_,sid)=stored(&store,|lib|lib.segment(&id,text.clone(),duration))?;
            changed(&app,&id);
            jobs.try_send((sid,text)).map_err(|_|"Smart notes could not keep up. Recording stopped; completed transcript was kept.".into())
        },move|update|{let _=update_app.emit("notes-live",json!({"id":update_id,"update":update}));}).await;
        let _ = control.send(Control::Cancel); // also retires native capture on every error path.
        let detail = match result {
            Ok(()) => "".to_string(),
            Err(e) => e,
        };
        let paused = pause.load(Ordering::SeqCst) && detail.is_empty();
        let saved = stored(&store, |lib| {
            lib.set_recording(&id, false, paused, false, &detail)
        });
        if saved.is_err() {
            let _=app.emit("notes-status",json!({"id":id,"detail":"Could not save the stopped state. Check local storage; completed segments remain in the library."}));
        }
        let state = app.state::<NotesRuntime>();
        if let Ok(mut active) = state.active.lock() {
            active.take();
        }
        let _ = done.send(true);
        changed(&app, &id);
    });
    Ok(())
}
#[tauri::command]
pub async fn notes_stop(
    app: tauri::AppHandle,
    pause: bool,
    id: Option<String>,
) -> Result<(), String> {
    let done = {
        let state = app.state::<NotesRuntime>();
        let guard = state.active.lock().map_err(|_| "Recording unavailable")?;
        if let Some(active) = guard.as_ref() {
            if id.as_ref().is_some_and(|id| id != &active.id) {
                return Err("Use the recording control to stop the active note".into());
            }
            active.pause.store(pause, Ordering::SeqCst);
            let _ = active.control.send(Control::Stop);
            Some(active.done.clone())
        } else {
            None
        }
    };
    if let Some(mut done) = done {
        while !*done.borrow() {
            if done.changed().await.is_err() {
                break;
            }
        }
    }
    if !pause {
        let state = app.state::<NotesRuntime>();
        if state
            .store
            .lock()
            .map_err(|_| "Notes storage unavailable")?
            .is_none()
        {
            return Ok(());
        }
        stored(&state.store, |lib| {
            let ids: Vec<_> = lib
                .list("", false)
                .into_iter()
                .filter(|e| e.paused && id.as_ref().is_none_or(|id| id == &e.id))
                .map(|e| e.id)
                .collect();
            for id in ids {
                lib.set_recording(&id, false, false, false, "")?;
            }
            Ok(())
        })?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures_util::{SinkExt, StreamExt};
    use tokio::net::TcpListener;
    use tokio_tungstenite::{accept_async, tungstenite::Message};
    #[tokio::test]
    async fn stopped_source_drains_across_segments_and_finals() {
        let server = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = server.local_addr().unwrap();
        let peer = tokio::spawn(async move {
            let mut sizes = vec![];
            for i in 0..3 {
                let (tcp, _) = server.accept().await.unwrap();
                let mut ws = accept_async(tcp).await.unwrap();
                let start = ws.next().await.unwrap().unwrap();
                let start: Value = serde_json::from_str(start.to_text().unwrap()).unwrap();
                assert_eq!(start["correction"], false);
                ws.send(Message::Text(json!({"type":"ready"}).to_string().into()))
                    .await
                    .unwrap();
                let mut size = 0;
                loop {
                    match ws.next().await.unwrap().unwrap() {
                        Message::Binary(v) => size += v.len(),
                        Message::Text(_) => break,
                        _ => (),
                    }
                }
                sizes.push(size);
                ws.send(Message::Text(
                    json!({"type":"final","text":format!("Synthetic segment {i}")})
                        .to_string()
                        .into(),
                ))
                .await
                .unwrap();
            }
            sizes
        });
        let (tx, source) = mpsc::channel(10);
        for _ in 0..5 {
            tx.send(Ok(vec![0; 1600])).await.unwrap();
        }
        drop(tx);
        let (_control, rx) = watch::channel(Control::Stop);
        let mut received = vec![];
        segments(
            Settings {
                url: format!("http://{address}"),
                ..Settings::default()
            },
            "synthetic-token".into(),
            rx,
            source,
            3200,
            |text, ms| {
                received.push((text, ms));
                Ok(())
            },
            |_| {},
        )
        .await
        .unwrap();
        assert_eq!(peer.await.unwrap(), vec![3200, 3200, 1600]);
        assert_eq!(received.iter().map(|(_, ms)| ms).sum::<u64>(), 250);
        assert_eq!(received.len(), 3);
    }
    #[tokio::test]
    async fn stream_failure_cancels_the_bridge_without_leaking_a_blocked_sender() {
        let server = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = server.local_addr().unwrap();
        let peer = tokio::spawn(async move {
            let (tcp, _) = server.accept().await.unwrap();
            let mut ws = accept_async(tcp).await.unwrap();
            ws.next().await;
            ws.close(None).await.unwrap();
        });
        let (tx, source) = mpsc::channel(2);
        tx.send(Ok(vec![0; 1600])).await.unwrap();
        let (_control, rx) = watch::channel(Control::Running);
        let result = tokio::time::timeout(
            Duration::from_secs(2),
            segments(
                Settings {
                    url: format!("http://{address}"),
                    ..Settings::default()
                },
                "synthetic-token".into(),
                rx,
                source,
                32000,
                |_, _| panic!("No final should be saved"),
                |_| {},
            ),
        )
        .await;
        assert!(result.unwrap().is_err());
        peer.await.unwrap();
        tokio::time::timeout(Duration::from_secs(1), tx.closed())
            .await
            .unwrap();
    }
    #[test]
    fn notes_urls_retain_the_server_prefix_and_refuse_credentials() {
        let mut s = Settings {
            url: "https://example.test/chirp/".into(),
            ..Settings::default()
        };
        assert_eq!(
            http_url(&s, "v1/notes/structure").unwrap().as_str(),
            "https://example.test/chirp/v1/notes/structure"
        );
        s.url = "https://user:secret@example.test".into();
        assert!(http_url(&s, "v1/notes/structure").is_err());
    }
}

#[tauri::command]
pub fn notes_flush_complete(state: tauri::State<NotesRuntime>, request: u64, ok: bool) {
    if let Ok(mut pending) = state.flush.lock() {
        if pending.as_ref().is_some_and(|(id, _)| *id == request) {
            if let Some((_, tx)) = pending.take() {
                let _ = tx.send(ok);
            }
        }
    };
}
pub async fn flush_before_quit(app: &tauri::AppHandle) -> Result<(), String> {
    let state = app.state::<NotesRuntime>();
    if state
        .store
        .lock()
        .map_err(|_| "Notes storage unavailable")?
        .is_none()
    {
        return Ok(());
    }
    let request = state.flush_sequence.fetch_add(1, Ordering::SeqCst) + 1;
    let (tx, rx) = oneshot::channel();
    *state.flush.lock().map_err(|_| "Notes editor unavailable")? = Some((request, tx));
    app.emit("notes-save-for-quit", request)
        .map_err(|_| "Notes editor unavailable")?;
    let saved = tokio::time::timeout(Duration::from_secs(5), rx).await;
    if let Ok(mut pending) = state.flush.lock() {
        if pending.as_ref().is_some_and(|(id, _)| *id == request) {
            pending.take();
        }
    }
    if matches!(saved, Ok(Ok(true))) {
        Ok(())
    } else {
        Err(
            "Notes could not save before quitting. Copy any unsaved text and check local storage."
                .into(),
        )
    }
}
