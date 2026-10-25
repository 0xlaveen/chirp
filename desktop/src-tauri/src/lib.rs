pub mod audio;
pub mod hotkey;
pub mod platform;
pub mod protocol;
pub mod settings;

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
    active: Mutex<Option<(u64, watch::Sender<Control>)>>,
    hotkey: Mutex<Option<platform::HotkeyHandle>>,
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
    if state
        .active
        .lock()
        .map_err(|_| "Session unavailable")?
        .is_some()
    {
        return Err("Stop dictation before changing settings".into());
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
    let _ = app.emit("dictation", update);
}

fn start(app: &tauri::AppHandle) -> Result<(), String> {
    let state = app.state::<Runtime>();
    let mut active = state.active.lock().map_err(|_| "Session unavailable")?;
    if active.is_some() {
        return Ok(());
    }
    let settings = state
        .settings
        .lock()
        .map_err(|_| "Settings unavailable")?
        .clone();
    let token = settings::token()?;
    let id = state.sequence.fetch_add(1, Ordering::SeqCst) + 1;
    let (control, rx) = watch::channel(Control::Running);
    *active = Some((id, control.clone()));
    if let Some(hud) = app.get_webview_window("hud") {
        let _ = hud.show();
    }
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        let result =
            protocol::dictate(settings, token, rx, None, |update| emit(&app, update)).await;
        let state = app.state::<Runtime>();
        let cancelled = {
            let Ok(active) = state.active.lock() else {
                return;
            };
            if !matches!(active.as_ref(), Some((current, _)) if *current == id) {
                return;
            }
            let cancelled = *control.borrow() == Control::Cancel;
            cancelled
        };
        if cancelled || matches!(&result, Err(error) if error == "cancelled") {
            if let Ok(mut active) = state.active.lock() {
                active.take();
            }
            emit(&app, Update::new("idle", "", "Cancelled"));
            if let Some(hud) = app.get_webview_window("hud") {
                let _ = hud.hide();
            }
            return;
        }
        match result {
            Ok(text) => {
                // Insertion happens off the runtime thread. No transcript enters an argv or log.
                let inserted = tauri::async_runtime::spawn_blocking(move || {
                    let outcome = if *control.borrow() == Control::Cancel {
                        Err("cancelled".into())
                    } else {
                        platform::native().insert_text(&text)
                    };
                    (text, outcome)
                })
                .await;
                match inserted {
                    Ok((text, Ok(outcome))) => emit(
                        &app,
                        Update::new(
                            "done",
                            &text,
                            match outcome {
                                platform::InsertionOutcome::Typed => "Inserted",
                                platform::InsertionOutcome::Clipboard => {
                                    "Copied — paste into your app"
                                }
                            },
                        ),
                    ),
                    Ok((text, Err(detail))) => emit(&app, Update::new("error", &text, &detail)),
                    Err(_) => emit(
                        &app,
                        Update::new("error", "", "Could not insert the result"),
                    ),
                }
            }
            Err(detail) => emit(&app, Update::new("error", "", &detail)),
        }
        if let Ok(mut active) = state.active.lock() {
            active.take();
        };
    });
    Ok(())
}

fn signal(app: &tauri::AppHandle, value: Control) {
    if value == Control::Cancel {
        if let Some(hud) = app.get_webview_window("hud") {
            let _ = hud.hide();
        }
        emit(app, Update::new("idle", "", "Cancelled"));
    }
    if let Ok(active) = app.state::<Runtime>().active.lock() {
        if let Some((_, tx)) = active.as_ref() {
            let _ = tx.send(value);
        }
    }
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
        .manage(Runtime {
            settings: Mutex::new(settings::Settings::read()),
            active: Mutex::new(None),
            hotkey: Mutex::new(None),
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
            dictate_start,
            dictate_stop,
            dictate_cancel
        ])
        .setup(|app| {
            use tauri::{
                menu::{Menu, MenuItem},
                tray::TrayIconBuilder,
            };
            let open = MenuItem::with_id(app, "open", "Open Chirp", true, None::<&str>)?;
            let stop = MenuItem::with_id(app, "stop", "Stop dictation", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&open, &stop, &quit])?;
            let mut tray = TrayIconBuilder::new()
                .menu(&menu)
                .tooltip("Chirp")
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "open" => {
                        if let Some(window) = app.get_webview_window("main") {
                            let _ = window.show();
                            let _ = window.set_focus();
                        }
                    }
                    "stop" => signal(app, Control::Stop),
                    "quit" => {
                        signal(app, Control::Cancel);
                        app.exit(0);
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
