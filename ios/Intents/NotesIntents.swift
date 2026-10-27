import AppIntents
import Foundation

private enum NotesIntentError: LocalizedError {
    case openChirp
    var errorDescription: String? { "Open Chirp to start Live Notes, then try again." }
}

private func unavailableNotesMessage() throws -> String { throw NotesIntentError.openChirp }

/// Live Activity buttons and Shortcuts actions for Live Notes. Like the dictation intents they run in the app process
/// (LiveActivityIntent); the widget extension only links the types.
struct StartChirpNotesIntent: AudioRecordingIntent, LiveActivityIntent {
    #if CHIRP_APP
    static let action: NotesAction = .start
    #endif
    static var title: LocalizedStringResource { "Record note with Chirp" }
    static var description: IntentDescription { IntentDescription("Opens Chirp and records long-form notes until you stop.") }
    static var openAppWhenRun: Bool { true }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        #if CHIRP_APP
        guard let notes = LiveNotesController.instance else { throw NotesIntentError.openChirp }
        let message = await notes.perform(Self.action)
        #else
        let message = try unavailableNotesMessage()
        #endif
        return .result(dialog: "\(message)")
    }
}

struct PauseChirpNotesIntent: AudioRecordingIntent, LiveActivityIntent {
    #if CHIRP_APP
    static let action: NotesAction = .togglePause
    #endif
    static var title: LocalizedStringResource { "Pause or resume note with Chirp" }
    static var description: IntentDescription { IntentDescription("Pauses Live Notes (the microphone turns off), or resumes a paused session.") }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        #if CHIRP_APP
        guard let notes = LiveNotesController.instance else { throw NotesIntentError.openChirp }
        let message = await notes.perform(Self.action)
        #else
        let message = try unavailableNotesMessage()
        #endif
        return .result(dialog: "\(message)")
    }
}

struct StopChirpNotesIntent: AudioRecordingIntent, LiveActivityIntent {
    #if CHIRP_APP
    static let action: NotesAction = .stop
    #endif
    static var title: LocalizedStringResource { "Stop note with Chirp" }
    static var description: IntentDescription { IntentDescription("Stops recording the note. Your notes stay in Chirp.") }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        #if CHIRP_APP
        guard let notes = LiveNotesController.instance else { throw NotesIntentError.openChirp }
        let message = await notes.perform(Self.action)
        #else
        let message = try unavailableNotesMessage()
        #endif
        return .result(dialog: "\(message)")
    }
}
