//! Native overlay lifetime. Timer tickets cannot dismiss a newer state.
use std::time::Duration;

pub const OUTCOME_DELAY: Duration = Duration::from_millis(1500);

pub trait Window {
    fn show(&self);
    fn hide(&self);
}

impl Window for tauri::WebviewWindow {
    fn show(&self) {
        let _ = tauri::WebviewWindow::show(self);
    }

    fn hide(&self) {
        let _ = tauri::WebviewWindow::hide(self);
    }
}

#[derive(Default)]
pub struct Hud {
    generation: u64,
}

impl Hud {
    pub fn update(&mut self, window: &impl Window, state: &str) -> Option<u64> {
        self.generation += 1;
        match state {
            "idle" => window.hide(),
            _ => window.show(),
        }
        (state == "done").then_some(self.generation)
    }

    pub fn dismiss_outcome(&self, window: &impl Window, ticket: u64) {
        if ticket == self.generation {
            window.hide();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    #[derive(Default)]
    struct TestWindow(Cell<bool>);
    impl Window for TestWindow {
        fn show(&self) {
            self.0.set(true);
        }
        fn hide(&self) {
            self.0.set(false);
        }
    }

    #[test]
    fn done_hides_the_window_after_the_outcome_delay() {
        for detail in ["Inserted", "Copied — paste into your app"] {
            let window = TestWindow::default();
            let mut hud = Hud::default();
            let update = crate::protocol::Update::new("done", "Synthetic example", detail);
            hud.update(&window, "listening");
            let ticket = hud.update(&window, &update.state).unwrap();
            assert!(window.0.get());
            assert_eq!(OUTCOME_DELAY, Duration::from_millis(1500));
            hud.dismiss_outcome(&window, ticket);
            assert!(!window.0.get());
        }
    }

    #[test]
    fn cancel_hides_immediately_and_errors_wait_for_dismissal_or_start() {
        let window = TestWindow::default();
        let mut hud = Hud::default();
        hud.update(&window, "listening");
        assert!(hud.update(&window, "idle").is_none());
        assert!(!window.0.get());
        assert!(hud.update(&window, "error").is_none());
        assert!(window.0.get());
        hud.update(&window, "idle");
        assert!(!window.0.get());
        hud.update(&window, "error");
        hud.update(&window, "connecting");
        assert!(window.0.get());
    }

    #[test]
    fn old_timer_cannot_hide_a_new_session_error_or_outcome() {
        for state in ["connecting", "listening", "processing", "error", "done"] {
            let window = TestWindow::default();
            let mut hud = Hud::default();
            let old = hud.update(&window, "done").unwrap();
            hud.update(&window, state);
            hud.dismiss_outcome(&window, old);
            assert!(window.0.get(), "old timer hid {state}");
        }
    }
}
