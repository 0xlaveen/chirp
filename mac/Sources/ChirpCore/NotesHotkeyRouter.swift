import Foundation

/// Where the dictation hotkey goes. Outside Notes it dictates. With the Notes window frontmost it drives Notes: the
/// first press records, a later press pauses, and the next resumes.
public enum NotesHotkeyRouter {
    public enum Route: Sendable, Equatable {
        case dictate
        /// Notes takes the press; `NotesAction` says what it does.
        case notes(NotesAction)
    }
    public enum NotesAction: Sendable, Equatable {
        case start, stop
        /// Pause while recording, resume while paused.
        case togglePause
        /// Notes is busy (finishing): the press does nothing, and does not start a dictation either.
        case ignore
    }

    /// Notes has Pause/Resume: the hotkey no longer stops (Stop is the button, ⌘⇧R and ⌃⌥N).
    public static let pauseAvailable = true

    public static func route(notesFrontmost: Bool, dictationActive: Bool, notes: NotesRecorderState,
                             pauseAvailable: Bool = pauseAvailable) -> Route {
        // A dictation already running keeps its own hotkey (stop it), whatever window is in front.
        guard notesFrontmost, !dictationActive else { return .dictate }
        switch notes {
        case .idle, .stopped, .error: return .notes(.start)
        case .recording, .paused: return .notes(pauseAvailable ? .togglePause : .stop)
        case .starting: return .notes(pauseAvailable ? .ignore : .stop)
        case .stopping: return .notes(.ignore)
        }
    }
}
