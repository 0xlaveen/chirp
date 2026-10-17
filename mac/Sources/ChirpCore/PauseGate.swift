import Foundation

/// The menu's main switch: while Chirp is paused its global hotkey is not registered, so nothing starts a dictation.
/// Every registration goes through the gate (the app start, the shortcut recorder, a changed shortcut), so none of
/// them can bring the hotkey back while paused. The pause lasts until Chirp is resumed or quits.
@MainActor
public final class PauseGate {
    public private(set) var isPaused = false
    /// The last registration succeeded and is still in place. False while paused, while the recorder holds the
    /// shortcut, and when another app owns it.
    public private(set) var hotkeyRegistered = false

    private let register: () -> Bool
    private let unregister: () -> Void
    private let onChange: () -> Void

    public init(register: @escaping () -> Bool, unregister: @escaping () -> Void, onChange: @escaping () -> Void = {}) {
        self.register = register
        self.unregister = unregister
        self.onChange = onChange
    }

    /// (Re)registers the hotkey unless paused. Returns whether it is registered afterwards.
    @discardableResult
    public func registerHotkey() -> Bool {
        guard !isPaused else { return false }
        hotkeyRegistered = register()
        onChange()
        return hotkeyRegistered
    }

    /// Releases the hotkey for the shortcut recorder; `registerHotkey()` takes it back (unless paused meanwhile).
    public func suspendHotkey() {
        unregister()
        hotkeyRegistered = false
        onChange()
    }

    public func pause() {
        guard !isPaused else { return }
        isPaused = true
        unregister()
        hotkeyRegistered = false
        onChange()
    }

    /// Registers the hotkey again. Returns whether it is registered (false when another app owns the shortcut).
    @discardableResult
    public func resume() -> Bool {
        guard isPaused else { return hotkeyRegistered }
        isPaused = false
        return registerHotkey()
    }

    /// The menu's switch: on means running.
    public func setRunning(_ running: Bool) {
        if running { resume() } else { pause() }
    }
}
