import AppKit
import ChirpCore

/// The "Open Notes" global shortcut (⌃⌥⇧N by default): the Notes window comes forward, nothing records. It follows the
/// menu's main switch like the other hotkeys, and the Settings recorder releases it while it listens.
@MainActor
final class OpenNotesHotkey {
    static let id: UInt32 = 5
    var open: () -> Void = {}
    var onChange: (() -> Void)?

    private(set) lazy var gate = PauseGate(
        register: { [weak self] in
            HotKeyCenter.shared.register(id: Self.id, combo: settings.openNotesHotkey, onDown: { [weak self] in self?.open() })
        },
        unregister: { HotKeyCenter.shared.unregister(id: Self.id) },
        onChange: { [weak self] in self?.onChange?() })

    @discardableResult
    func register() -> Bool { gate.registerHotkey() }
    func suspend() { gate.suspendHotkey() }
    func setRunning(_ running: Bool) { gate.setRunning(running) }
    /// The shortcut in the menu, or nil while it is not registered.
    var title: String? { gate.hotkeyRegistered ? settings.openNotesHotkey.title : nil }
}

extension NotesController {
    /// The dictation hotkey while Notes may be in front: Notes takes it when its window is frontmost (see
    /// `NotesHotkeyRouter`). Returns whether it did, so the dictation machine never sees the press.
    func takeDictationHotkey(notesFrontmost: Bool, dictationActive: Bool) -> Bool {
        guard case .notes(let action) = NotesHotkeyRouter.route(notesFrontmost: notesFrontmost, dictationActive: dictationActive,
                                                                notes: recorder.state) else { return false }
        switch action {
        case .start: toggle(fromHotkey: false)
        case .stop: Task { await stop() }
        case .togglePause: togglePauseFromHotkey()
        case .ignore: break
        }
        return true
    }

    /// While recording the hotkey pauses, while paused it resumes.
    func togglePauseFromHotkey() { Task { await togglePause() } }
}
