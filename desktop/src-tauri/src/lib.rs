pub mod audio;
pub mod auto_enter;
pub mod files;
pub mod history;
pub mod hotkey;
mod hud;
pub mod library;
pub mod notes;
pub mod platform;
pub mod protocol;
pub mod remote;
pub mod settings;
pub mod spoken_commands;
pub mod styles;

use hotkey::{Action, HotkeyState};
use protocol::{Control, Update};
use serde::Serialize;
use std::sync::{
    atomic::{AtomicU64, Ordering},
    Mutex,
};
use tauri::{Emitter, Manager};
use tokio::sync::watch;

struct Runtime {
    settings: Mutex<settings::Settings>,
    last_final: Mutex<Option<protocol::Final>>,
    active: Mutex<Option<(u64, watch::Sender<Control>)>>,
    hotkey: Mutex<Option<platform::HotkeyHandle>>,
    hud: Mutex<hud::Hud>,
    sequence: AtomicU64,
    hotkey_sequence: AtomicU64,
    shortcut: Mutex<ShortcutStatus>,
}

#[derive(Clone, Serialize)]
struct ShortcutStatus {
    available: bool,
    requested: bool,
    detail: String,
}

#[derive(Serialize)]
struct Preferences {
    settings: settings::Settings,
    capabilities: platform::Capabilities,
    paired: bool,
    shortcut: ShortcutStatus,
}
#[derive(Serialize)]
struct ConnectionChip {
    state: &'static str,
    label: &'static str,
}

#[derive(Serialize)]
struct StyleList {
    source: &'static str,
    styles: Vec<styles::Style>,
}

fn chip(connected: bool) -> ConnectionChip {
    if connected {
        ConnectionChip {
            state: "connected",
            label: "Connected",
        }
    } else {
        ConnectionChip {
            state: "offline",
            label: "Computer offline",
        }
    }
}

#[tauri::command]
async fn connection_status(state: tauri::State<'_, Runtime>) -> Result<ConnectionChip, String> {
    let settings = state
        .settings
        .lock()
        .map_err(|_| "Settings unavailable")?
        .clone();
    let Ok(token) = settings::token() else {
        return Ok(chip(false));
    };
    match remote::authenticated_health(&settings, &token).await {
        Ok(Some(_)) => Ok(chip(true)),
        _ => Ok(chip(false)),
    }
}

#[tauri::command]
async fn cleanup_styles(state: tauri::State<'_, Runtime>) -> Result<StyleList, String> {
    let settings = state
        .settings
        .lock()
        .map_err(|_| "Settings unavailable")?
        .clone();
    let Ok(token) = settings::token() else {
        return Ok(StyleList {
            source: "builtin",
            styles: styles::builtins(),
        });
    };
    match remote::correction_profiles(&settings, &token).await {
        Ok(value) => match styles::parse_profiles(&value) {
            Ok(styles) => Ok(StyleList {
                source: "server",
                styles,
            }),
            Err(_) => Ok(StyleList {
                source: "builtin",
                styles: styles::builtins(),
            }),
        },
        Err(_) => Ok(StyleList {
            source: "builtin",
            styles: styles::builtins(),
        }),
    }
}

#[tauri::command]
fn preferences(state: tauri::State<Runtime>) -> Result<Preferences, String> {
    let settings = state
        .settings
        .lock()
        .map_err(|_| "Settings unavailable")?
        .clone();
    let shortcut = state
        .shortcut
        .lock()
        .map_err(|_| "Shortcut status unavailable")?
        .clone();
    Ok(Preferences {
        settings,
        capabilities: platform::native().capabilities(),
        paired: settings::token().is_ok(),
        shortcut,
    })
}

#[tauri::command]
fn save_preferences(
    app: tauri::AppHandle,
    settings: settings::Settings,
    token: Option<String>,
    pairing_link: Option<String>,
) -> Result<(), String> {
    let state = app.state::<Runtime>();
    let dictation_guard = state.active.lock().map_err(|_| "Session unavailable")?;
    if dictation_guard.is_some() {
        return Err("Stop dictation before changing settings".into());
    }
    let notes_state = app.state::<notes::NotesRuntime>();
    let notes_guard = notes_state
        .active
        .lock()
        .map_err(|_| "Recording unavailable")?;
    if notes_guard.is_some() {
        return Err("Stop the note before changing settings".into());
    }
    let mut settings = settings;
    settings::stream_url(&settings.url)?;
    settings::validate_portal_trigger(&settings.portal_shortcut)?;
    let mut token = token;
    if let Some(link) = pairing_link.filter(|s| !s.trim().is_empty()) {
        let (url, secret) = settings::pairing(&link)?;
        settings.url = url;
        token = Some(secret);
    }
    if let Some(token) = token.filter(|t| !t.is_empty()) {
        settings::save_token(&token)?;
    }
    {
        let mut current = state.settings.lock().map_err(|_| "Settings unavailable")?;
        settings.save()?;
        state.hotkey_sequence.fetch_add(1, Ordering::SeqCst);
        *current = settings;
    }
    register_hotkey(&app);
    Ok(())
}

fn emit(app: &tauri::AppHandle, update: Update) {
    if let Some(window) = app.get_webview_window("hud") {
        let ticket = app
            .state::<Runtime>()
            .hud
            .lock()
            .ok()
            .and_then(|mut hud| hud.update(&window, &update.state));
        if let Some(ticket) = ticket {
            let app = app.clone();
            tauri::async_runtime::spawn(async move {
                tokio::time::sleep(hud::OUTCOME_DELAY).await;
                if let Ok(hud) = app.state::<Runtime>().hud.lock() {
                    hud.dismiss_outcome(&window, ticket);
                };
            });
        }
    }
    let _ = app.emit("dictation", update);
}

fn start(app: &tauri::AppHandle) -> Result<(), String> {
    let state = app.state::<Runtime>();
    let mut active = state.active.lock().map_err(|_| "Session unavailable")?;
    if active.is_some() {
        return Ok(());
    }
    if app
        .state::<notes::NotesRuntime>()
        .active
        .lock()
        .map_err(|_| "Recording unavailable")?
        .is_some()
    {
        return Err("Stop the note before dictating into another app".into());
    }
    let settings = state
        .settings
        .lock()
        .map_err(|_| "Settings unavailable")?
        .clone();
    let token = settings::token()?;
    *state.last_final.lock().map_err(|_| "Result unavailable")? = None;
    let id = state.sequence.fetch_add(1, Ordering::SeqCst) + 1;
    let (control, rx) = watch::channel(Control::Running);
    *active = Some((id, control.clone()));
    emit(app, Update::new("connecting", "", "Connecting…"));
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        let result = protocol::dictate_final(settings.clone(), token, rx, None, |update| {
            if let Ok(active) = app.state::<Runtime>().active.lock() {
                if matches!(active.as_ref(), Some((current, _)) if *current == id)
                    && *control.borrow() != Control::Cancel
                {
                    emit(&app, update);
                }
            };
        })
        .await;
        let state = app.state::<Runtime>();
        let cancelled = *control.borrow() == Control::Cancel;
        if cancelled || matches!(&result, Err(error) if error == "cancelled") {
            if let Ok(mut active) = state.active.lock() {
                if matches!(active.as_ref(), Some((current, _)) if *current == id) {
                    active.take();
                    emit(&app, Update::new("idle", "", "Cancelled"));
                }
            }
            return;
        }
        let outcome = match result {
            Ok(mut final_result) => {
                final_result.text =
                    spoken_commands::apply(&final_result.text, settings.spoken_commands);
                let text = final_result.text.clone();
                let mode = settings.auto_enter_mode();
                let inserted = tauri::async_runtime::spawn_blocking(
                    move || -> Result<(platform::InsertionOutcome, bool), String> {
                        if *control.borrow() == Control::Cancel {
                            return Err("cancelled".into());
                        }
                        let outcome = platform::native().insert_text(&text)?;
                        if *control.borrow() == Control::Cancel {
                            return Err("cancelled".into());
                        }
                        let pressed = auto_enter::should_press(
                            mode,
                            outcome == platform::InsertionOutcome::Typed,
                            &text,
                        ) && platform::native().press_enter().unwrap_or(false);
                        Ok((outcome, pressed))
                    },
                )
                .await;
                let mut update = match inserted {
                    Ok(Ok((outcome, pressed))) => Update::new(
                        "done",
                        &final_result.text,
                        match (outcome, pressed) {
                            (platform::InsertionOutcome::Typed, true) => "Inserted · ↵ sent",
                            (platform::InsertionOutcome::Typed, false) => "Inserted",
                            (platform::InsertionOutcome::Clipboard, _) => {
                                "Copied — paste into your app"
                            }
                        },
                    ),
                    Ok(Err(detail)) => Update::new("error", &final_result.text, &detail),
                    Err(_) => {
                        Update::new("error", &final_result.text, "Could not insert the result")
                    }
                };
                // Hold the same start/cancel lock through publishing and history recording.
                // A late cancelled result must never become a saved dictation.
                if let Ok(mut active) = state.active.lock() {
                    if matches!(active.as_ref(), Some((current, tx)) if *current == id && *tx.borrow() != Control::Cancel)
                    {
                        update.raw_available = final_result.raw.is_some();
                        if let Ok(mut last) = state.last_final.lock() {
                            *last = Some(final_result.clone());
                        }
                        if let Err(detail) =
                            history::record(final_result.text, final_result.raw, &settings)
                        {
                            let _ = app.emit("history-error", detail);
                        }
                        active.take();
                        emit(&app, update);
                        let _ = app.emit("history-changed", ());
                        return;
                    }
                }
                update
            }
            Err(detail) => Update::new("error", "", &detail),
        };
        if let Ok(mut active) = state.active.lock() {
            if matches!(active.as_ref(), Some((current, _)) if *current == id) {
                let cancelled = active
                    .as_ref()
                    .is_some_and(|(_, tx)| *tx.borrow() == Control::Cancel);
                active.take();
                emit(
                    &app,
                    if cancelled {
                        Update::new("idle", "", "Cancelled")
                    } else {
                        outcome
                    },
                );
            }
        };
    });
    Ok(())
}

#[tauri::command]
fn dictation_copy(app: tauri::AppHandle) -> Result<(), String> {
    let state = app.state::<Runtime>();
    let last = state.last_final.lock().map_err(|_| "Result unavailable")?;
    let result = last
        .as_ref()
        .ok_or("There is no completed dictation to copy")?;
    platform::native().copy_text(&result.text)
}

#[tauri::command]
fn dictation_use_raw(app: tauri::AppHandle) -> Result<(), String> {
    let state = app.state::<Runtime>();
    let active = state.active.lock().map_err(|_| "Session unavailable")?;
    if active.is_some() {
        return Err("Stop dictation before using the original".into());
    }
    let mut last = state.last_final.lock().map_err(|_| "Result unavailable")?;
    let result = last.as_mut().ok_or("There is no completed dictation")?;
    let raw = result
        .raw
        .as_ref()
        .ok_or("The original is already in use")?;
    // Another app's selection cannot be verified on every desktop. Copy instead of deleting text.
    platform::native().copy_text(raw)?;
    result.text = raw.clone();
    result.raw = None;
    emit(
        &app,
        Update::new(
            "done",
            &result.text,
            "Original copied — select the previous result in your app and paste",
        ),
    );
    Ok(())
}

fn signal(app: &tauri::AppHandle, value: Control) {
    if let Ok(active) = app.state::<Runtime>().active.lock() {
        if let Some((_, tx)) = active.as_ref() {
            let _ = tx.send(value);
        }
        if value == Control::Cancel {
            if let Ok(mut last) = app.state::<Runtime>().last_final.lock() {
                *last = None;
            }
            emit(app, Update::new("idle", "", "Cancelled"));
        }
    };
}

#[tauri::command]
fn dictate_start(app: tauri::AppHandle) -> Result<(), String> {
    start(&app)?;
    // Return focus to the user's previous app; the HUD never requests focus.
    if let Some(main) = app.get_webview_window("main") {
        let _ = main.hide();
    }
    Ok(())
}
#[tauri::command]
fn dictate_stop(app: tauri::AppHandle) {
    signal(&app, Control::Stop);
}
#[tauri::command]
fn dictate_cancel(app: tauri::AppHandle) {
    signal(&app, Control::Cancel);
}

fn shortcut_status(
    app: &tauri::AppHandle,
    registration: u64,
    wayland: bool,
    status: ShortcutStatus,
) {
    let state = app.state::<Runtime>();
    if state.hotkey_sequence.load(Ordering::SeqCst) != registration {
        return;
    }
    if wayland && !status.available && !status.requested {
        if let Ok(mut settings) = state.settings.lock() {
            if state.hotkey_sequence.load(Ordering::SeqCst) != registration {
                return;
            }
            if settings.portal_enabled {
                settings.portal_enabled = false;
                let _ = settings.save();
            }
        }
    }
    if let Ok(mut current) = state.shortcut.lock() {
        if state.hotkey_sequence.load(Ordering::SeqCst) != registration {
            return;
        }
        *current = status.clone();
        let _ = app.emit("shortcut-status", status);
    };
}

fn register_hotkey(app: &tauri::AppHandle) {
    let state = app.state::<Runtime>();
    let Ok(settings) = state.settings.lock().map(|s| s.clone()) else {
        return;
    };
    let registration = state.hotkey_sequence.fetch_add(1, Ordering::SeqCst) + 1;
    let Ok(mut handle) = state.hotkey.lock() else {
        return;
    };
    handle.take();
    let native = platform::native();
    let wayland = native.capabilities().session == "wayland";
    if wayland && !settings.portal_enabled {
        shortcut_status(app, registration, true, ShortcutStatus { available: false, requested: false,
            detail: "Use Record, or enable a desktop shortcut below. Wayland uses the binding approved by your desktop.".into() });
        return;
    }
    if wayland {
        shortcut_status(
            app,
            registration,
            true,
            ShortcutStatus {
                available: false,
                requested: true,
                detail: "Choose your shortcut in the desktop dialog…".into(),
            },
        );
    }
    let report_app = app.clone();
    let report: platform::HotkeyReport = Box::new(move |result| {
        let available = result.is_ok();
        let detail = result.unwrap_or_else(|error| error);
        shortcut_status(
            &report_app,
            registration,
            wayland,
            ShortcutStatus {
                available,
                requested: available,
                detail,
            },
        );
    });
    let (tx, rx) = std::sync::mpsc::channel();
    match native.start_hotkey_with_status(
        settings.hotkey,
        tx,
        settings.portal_shortcut.clone(),
        report,
    ) {
        Ok(hook) => {
            *handle = Some(hook);
            let app = app.clone();
            std::thread::spawn(move || {
                let mut hotkey = HotkeyState::new(settings.hotkey, settings.mode);
                for event in rx {
                    if app
                        .state::<Runtime>()
                        .hotkey_sequence
                        .load(Ordering::SeqCst)
                        != registration
                    {
                        break;
                    }
                    let recording = app
                        .state::<Runtime>()
                        .active
                        .lock()
                        .map(|active| active.is_some())
                        .unwrap_or(false);
                    hotkey.set_recording(recording);
                    match hotkey.event(event) {
                        Some(Action::Start) => {
                            if let Err(detail) = start(&app) {
                                emit(&app, Update::new("error", "", &detail));
                            }
                        }
                        Some(Action::Stop) => signal(&app, Control::Stop),
                        Some(Action::Cancel) => signal(&app, Control::Cancel),
                        None => {}
                    }
                }
            });
        }
        Err(detail) => shortcut_status(
            app,
            registration,
            wayland,
            ShortcutStatus {
                available: false,
                requested: false,
                detail,
            },
        ),
    }
}

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .manage(notes::NotesRuntime::default())
        .manage(Runtime {
            settings: Mutex::new(settings::Settings::read()),
            last_final: Mutex::new(None),
            active: Mutex::new(None),
            hotkey: Mutex::new(None),
            hud: Mutex::new(hud::Hud::default()),
            sequence: AtomicU64::new(0),
            hotkey_sequence: AtomicU64::new(0),
            shortcut: Mutex::new(ShortcutStatus {
                available: false,
                requested: false,
                detail: "Shortcut not registered yet".into(),
            }),
        })
        .invoke_handler(tauri::generate_handler![
            preferences,
            save_preferences,
            connection_status,
            cleanup_styles,
            dictate_start,
            dictate_stop,
            dictate_cancel,
            dictation_copy,
            dictation_use_raw,
            history::history_list,
            history::history_copy,
            history::history_delete,
            history::history_clear,
            notes::notes_list,
            notes::notes_create,
            notes::notes_get,
            notes::notes_edit,
            notes::notes_trash,
            notes::notes_empty_trash,
            notes::notes_discard_blank,
            notes::notes_record,
            notes::notes_stop,
            notes::notes_organize,
            notes::notes_undo_organize,
            notes::notes_export,
            notes::notes_apply_organize, notes::notes_flush_complete
        ])
        .setup(|app| {
            use tauri::{
                menu::{Menu, MenuItem},
                tray::TrayIconBuilder,
            };
            let open = MenuItem::with_id(app, "open", "Open Chirp", true, None::<&str>)?;
            let notes = MenuItem::with_id(app, "notes", "Notes library…", true, None::<&str>)?;
            let stop = MenuItem::with_id(app, "stop", "Stop recording", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&open, &notes, &stop, &quit])?;
            let mut tray = TrayIconBuilder::new()
                .menu(&menu)
                .tooltip("Chirp")
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "open" | "notes" => {
                        if event.id.as_ref() == "notes" {
                            let _ = app.emit("open-notes", ());
                        }
                        if let Some(window) = app.get_webview_window("main") {
                            let _ = window.show();
                            let _ = window.set_focus();
                        }
                    }
                    "stop" => {
                        signal(app, Control::Stop);
                        let app = app.clone();
                        tauri::async_runtime::spawn(async move {
                            let _ = notes::notes_stop(app, false, None).await;
                        });
                    }
                    "quit" => {
                        signal(app, Control::Cancel);
                        let app = app.clone();
                        tauri::async_runtime::spawn(async move {
                            let saved=notes::flush_before_quit(&app).await;
                            if let Err(detail)=saved {
                                if let Some(window)=app.get_webview_window("main"){let _=window.show();let _=window.set_focus();}
                                let _=app.emit("notes-status",serde_json::json!({"id":"","detail":detail}));
                                return;
                            }
                            let stopped = tokio::time::timeout(
                                std::time::Duration::from_secs(90),
                                notes::notes_stop(app.clone(), false, None),
                            ).await;
                            if !matches!(stopped,Ok(Ok(()))){let _=app.emit("notes-status",serde_json::json!({"id":"","detail":"Notes is still finishing. Try Quit again when recording stops."}));return;}
                            app.exit(0);
                        });
                    }
                    _ => {}
                });
            if let Some(icon) = app.default_window_icon() {
                tray = tray.icon(icon.clone());
            }
            tray.build(app)?;
            if let Some(hud) = app.get_webview_window("hud") {
                let _ = hud.set_focusable(false);
                if let Ok(Some(monitor)) = hud.primary_monitor() {
                    let area = monitor.size();
                    let scale = monitor.scale_factor();
                    let _ = hud.set_position(tauri::PhysicalPosition::new(
                        ((area.width as f64 - 440.0 * scale) / 2.0) as i32,
                        (area.height as f64 - 210.0 * scale) as i32,
                    ));
                }
            }
            register_hotkey(app.handle());
            Ok(())
        })
        .on_window_event(|window, event| {
            if window.label() == "main" {
                if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                    api.prevent_close();
                    let _ = window.hide();
                }
            }
        })
        .run(tauri::generate_context!())
        .expect("Chirp desktop could not start");
}
