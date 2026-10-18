import AppIntents
import Foundation

private enum IntentSetupError: LocalizedError {
    case openChirp
    var errorDescription: String? { "Open Chirp to finish pairing, microphone permission and session setup, then try again." }
}

private func unavailableIntentMessage() throws -> String { throw IntentSetupError.openChirp }

// Both memberships are intentional. LiveActivityIntent selects the containing
// app process. The extension build has no coordinator, audio or network code.
struct StartChirpIntent: AudioRecordingIntent, LiveActivityIntent {
    static var title: LocalizedStringResource { "Start Chirp dictation" }
    static var description: IntentDescription {
        IntentDescription("Opens Chirp to set up or start dictation. The microphone stays active until you end the session.")
    }
    static var openAppWhenRun: Bool { true }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        #if CHIRP_APP
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
        AppShortcut(intent: StopChirpIntent(), phrases: ["Stop dictation with \(.applicationName)"],
                    shortTitle: "Stop dictation", systemImageName: "stop.fill")
        AppShortcut(intent: CancelChirpIntent(), phrases: ["Cancel dictation with \(.applicationName)"],
                    shortTitle: "Cancel dictation", systemImageName: "xmark")
        AppShortcut(intent: EndChirpSessionIntent(), phrases: ["End session with \(.applicationName)"],
                    shortTitle: "End session", systemImageName: "mic.slash")
    }
}
