import AppIntents
import Foundation

private enum IntentSetupError: LocalizedError {
    case openChirp
    var errorDescription: String? { "Open Chirp to finish pairing, microphone permission and session setup, then try again." }
}

private func unavailableIntentMessage() throws -> String { throw IntentSetupError.openChirp }

#if CHIRP_APP
// Extensions cannot conform; only the app process ever performs these intents.
extension StartChirpIntent: ForegroundContinuableIntent {}
extension ToggleChirpDictationIntent: ForegroundContinuableIntent {}

/// Opens Chirp only when no session runs yet; an armed session starts and stops without leaving the editor.
@MainActor private func continueInForegroundIfNeeded(_ intent: some ForegroundContinuableIntent) async throws {
    guard SessionCoordinator.shared.needsForegroundToStart else { return }
    let dialog: IntentDialog = "Open Chirp to start a session."
    if #available(iOS 26.0, *) { try await intent.continueInForeground(dialog, alwaysConfirm: false) }
    else { try await intent.requestToContinueInForeground(dialog) }
}
#endif

// Both memberships are intentional. LiveActivityIntent selects the containing
// app process. The extension build has no coordinator, audio or network code.
struct StartChirpIntent: AudioRecordingIntent, LiveActivityIntent {
    static var title: LocalizedStringResource { "Start Chirp dictation" }
    static var description: IntentDescription {
        IntentDescription("Starts dictation in a running Chirp session, or opens Chirp to set one up. The microphone stays active until you end the session.")
    }
    @available(iOS 26.0, *) static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        #if CHIRP_APP
        try await continueInForegroundIfNeeded(self)
        let message = try await SessionCoordinator.shared.perform(action: .start)
        #else
        let message = try unavailableIntentMessage()
        #endif
        return .result(dialog: "\(message)")
    }
}

struct StopChirpIntent: AudioRecordingIntent, LiveActivityIntent {
    static var title: LocalizedStringResource { "Stop Chirp dictation" }
    static var description: IntentDescription {
        IntentDescription("Finishes companion dictation and explicitly copies its fresh final. The session microphone remains active; End session turns it off.")
    }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        #if CHIRP_APP
        let message = try await SessionCoordinator.shared.perform(action: .stop)
        #else
        let message = try unavailableIntentMessage()
        #endif
        return .result(dialog: "\(message)")
    }
}

/// Runs in the background so a hardware-keyboard shortcut can drive dictation from any app: starts in an
/// armed session, or stops and copies the final for ⌘V. With no session it opens Chirp to set one up.
struct ToggleChirpDictationIntent: AudioRecordingIntent, LiveActivityIntent {
    static var title: LocalizedStringResource { "Toggle Chirp dictation" }
    static var description: IntentDescription {
        IntentDescription("Starts dictation while a Chirp session is running, or stops it and copies the text so you can paste it. Assign it a keyboard shortcut to dictate from any app.")
    }
    @available(iOS 26.0, *) static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        #if CHIRP_APP
        try await continueInForegroundIfNeeded(self)
        let message = try await SessionCoordinator.shared.perform(action: .toggle)
        #else
        let message = try unavailableIntentMessage()
        #endif
        return .result(dialog: "\(message)")
    }
}

struct CancelChirpIntent: AudioRecordingIntent, LiveActivityIntent {
    static var title: LocalizedStringResource { "Cancel Chirp dictation" }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        #if CHIRP_APP
        let message = try await SessionCoordinator.shared.perform(action: .cancel)
        #else
        let message = try unavailableIntentMessage()
        #endif
        return .result(dialog: "\(message)")
    }
}

struct EndChirpSessionIntent: AudioRecordingIntent, LiveActivityIntent {
    static var title: LocalizedStringResource { "End Chirp session" }
    static var description: IntentDescription { IntentDescription("Stops microphone capture and ends the session.") }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        #if CHIRP_APP
        let message = try await SessionCoordinator.shared.perform(action: .end)
        #else
        let message = try unavailableIntentMessage()
        #endif
        return .result(dialog: "\(message)")
    }
}

struct ChirpShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartChirpIntent(), phrases: ["Start dictation with \(.applicationName)"],
                    shortTitle: "Start dictation", systemImageName: "mic")
        AppShortcut(intent: ToggleChirpDictationIntent(), phrases: ["Toggle dictation with \(.applicationName)"],
                    shortTitle: "Toggle dictation", systemImageName: "mic.circle")
        AppShortcut(intent: StopChirpIntent(), phrases: ["Stop dictation with \(.applicationName)"],
                    shortTitle: "Stop dictation", systemImageName: "stop.fill")
        AppShortcut(intent: CancelChirpIntent(), phrases: ["Cancel dictation with \(.applicationName)"],
                    shortTitle: "Cancel dictation", systemImageName: "xmark")
        AppShortcut(intent: EndChirpSessionIntent(), phrases: ["End session with \(.applicationName)"],
                    shortTitle: "End session", systemImageName: "mic.slash")
    }
}
