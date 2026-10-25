//! Test-only portal probe. Run on a private session bus, never the user's desktop bus.
#[cfg(target_os = "linux")]
fn main() {
    use chirp_desktop::{hotkey::HotKey, platform::wayland};
    use std::{io::Write, sync::mpsc, time::Duration};
    let (status_tx, status_rx) = mpsc::channel();
    let (tx, rx) = mpsc::channel();
    let hook = wayland::start(
        HotKey::RightCtrl,
        tx,
        "CTRL+ALT+space".into(),
        Box::new(move |result| {
            let _ = status_tx.send(result);
        }),
    )
    .unwrap();
    let result = status_rx.recv_timeout(Duration::from_secs(10)).unwrap();
    if std::env::args().any(|arg| arg == "--unavailable") {
        assert!(result.is_err());
        assert!(rx.try_recv().is_err());
        println!("unavailable");
        return;
    }
    assert!(result.unwrap().contains("Ctrl+Alt+Space"));
    assert!(wayland::is_active());
    println!("ready");
    std::io::stdout().flush().unwrap();
    assert!(rx.recv_timeout(Duration::from_secs(5)).unwrap().down);
    assert!(!rx.recv_timeout(Duration::from_secs(5)).unwrap().down);
    drop(hook);
    // Dropping the handle closes the remote Session; the fixture verifies Close.
    println!("events");
    std::io::stdout().flush().unwrap();
    let deadline = std::time::Instant::now() + Duration::from_secs(3);
    while wayland::is_active() && std::time::Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(!wayland::is_active(), "portal session did not close");
}
#[cfg(not(target_os = "linux"))]
fn main() {}
