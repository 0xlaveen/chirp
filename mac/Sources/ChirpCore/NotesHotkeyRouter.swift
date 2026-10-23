import Foundation

/// Where the dictation hotkey goes. Outside Notes it dictates. With the Notes window frontmost it drives Notes: the
/// first press records, a later press pauses or resumes (Pause is not built yet, #65: until then it stops).
public enum NotesHotkeyRouter {
    public enum Route: Sendable, Equatable {
        case dictate
        /// Notes takes the press; `NotesAction` says what it does.
        case notes(NotesAction)
    }
    public enum NotesAction: Sendable, Equatable {
        case start, stop
        /// Seam for #65: pause while recording, resume while paused.
        case togglePause
        /// Notes is busy (finishing): the press does nothing, and does not start a dictation either.
        case ignore
    }

    /// Flip to true when Notes has Pause/Resume and `NotesController.togglePauseFromHotkey()` works.
    public static let pauseAvailable = false

    public static func route(notesFrontmost: Bool, dictationActive: Bool, notes: NotesRecorderState,
                             pauseAvailable: Bool = pauseAvailable) -> Route {
        // A dictation already running keeps its own hotkey (stop it), whatever window is in front.
        guard notesFrontmost, !dictationActive else { return .dictate }
        switch notes {
        case .idle, .stopped, .error: return .notes(.start)
        case .starting, .recording: return .notes(pauseAvailable ? .togglePause : .stop)
        case .stopping: return .notes(.ignore)
        }
    }
}
