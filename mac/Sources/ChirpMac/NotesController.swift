import AppKit
import ChirpCore
import ChirpSpeakers
import ChirpUI

/// Live Notes in the app: `NotesSession` (ChirpUI) wired to the real microphone, server, sounds, permissions, ⌃⌥N and
/// VoiceOver. The session itself is tested with fakes; this file only picks the system parts.
typealias NotesController = NotesSession

@MainActor
extension NotesSession {
    static let hotkeyID: UInt32 = 4

    /// The server's structure timeout (30 s) plus a margin.
    static let structureTimeout: TimeInterval = 35
    /// A reorganize pass may take longer (up to 3500 chars in and out).
    static let reorganizeTimeout: TimeInterval = 50

    convenience init() {
        var deps = NotesSessionDependencies(
            settings: settings,
            engine: SystemCaptureEngine(pickedDevice: { InputDevice.pickedID(uid: settings.inputDeviceUID) }),
            makeSession: { StreamSession(config: settings.serverConfig(), options: $0) },
            structure: { request in try await Self.structure(request) },
            reorganize: { request in try await Self.reorganize(request) },
            speakerStore: SortformerModelStore(), journalStore: NotesJournalStore())
        deps.requestMicrophone = { await Permissions.requestMicrophone() }
        deps.openMicrophoneSettings = { Permissions.openSettings(.microphone) }
        deps.microphoneStatus = { Permissions.microphone.rawValue }
        deps.play = { Sounds.play($0) }
        deps.soundStartDelay = { Sounds.startDelay() }
        deps.beep = { NSSound.beep() }
        deps.announce = { text in
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        deps.reduceMotion = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        deps.registerHotkey = { onDown in HotKeyCenter.shared.register(id: Self.hotkeyID, combo: .controlOptionN, onDown: onDown) }
        deps.unregisterHotkey = { HotKeyCenter.shared.unregister(id: Self.hotkeyID) }
        self.init(deps)
    }

    /// One structuring call, logged with counts and the guard name only.
    private nonisolated static func structure(_ request: NotesStructureRequest) async throws -> NotesStructureResponse {
        try await timed({ try await settings.serverConfig().structureNotes(request, timeout: structureTimeout) }) { result, ms in
            chirpLog.info("notes structure chars=\(request.transcript.count, privacy: .public) result=\(result, privacy: .public) ms=\(ms, privacy: .public)")
        } result: { $0.structured ? "ok" : $0.failureLabel }
    }

    /// One reorganize call, logged with counts and the guard name only.
    private nonisolated static func reorganize(_ request: NotesReorganizeRequest) async throws -> NotesReorganizeResponse {
        try await timed({ try await settings.serverConfig().reorganizeNotes(request, timeout: reorganizeTimeout) }) { result, ms in
            chirpLog.info("notes reorganize chars=\(request.notes.count, privacy: .public) scope=\(request.range.length, privacy: .public) result=\(result, privacy: .public) ms=\(ms, privacy: .public)")
        } result: { $0.reorganized ? ($0.changed ? "changed" : "unchanged") : $0.failureLabel }
    }

    /// Runs `call`, then logs its outcome (`result` of the answer, or the error code) and duration.
    private nonisolated static func timed<R: Sendable>(_ call: () async throws -> R, log: (String, Int) -> Void,
                                                      result: (R) -> String) async throws -> R {
        let start = ContinuousClock.now
        func ms() -> Int {
            let e = (ContinuousClock.now - start).components
            return Int(Double(e.seconds) * 1000 + Double(e.attoseconds) / 1e15)
        }
        do {
            let r = try await call()
            log(result(r), ms())
            return r
        } catch let error as NotesStructureError {
            log(error.code, ms())
            throw error
        } catch {
            log((error as? URLError)?.code == .timedOut ? "timeout" : "http", ms())
            throw error
        }
    }

    /// The menu's view of Notes.
    var menuState: MenuBarController.NotesMenuState {
        MenuBarController.NotesMenuState(
            recording: isRecording, finishing: recorder.state == .stopping,
            elapsed: model.elapsedText, hasDocument: hasDocument,
            hotkeyRegistered: gate.hotkeyRegistered, debugRetention: isRecording && recorder.debugRetention)
    }
}
