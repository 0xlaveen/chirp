import Foundation
import ChirpCore

public enum SessionDuration: String, Codable, Sendable, CaseIterable {
    case fiveMinutes, fifteenMinutes, oneHour, never
    public var seconds: TimeInterval? {
        switch self { case .fiveMinutes: 300; case .fifteenMinutes: 900; case .oneHour: 3600; case .never: nil }
    }
}
public struct IOSPreferences: Codable, Sendable, Equatable {
    public var correction = false
    public var styleID = "default"
    public var prompts: [String: String] = [:]
    public var sessionDuration: SessionDuration = .fiveMinutes
    public var privacyMode = false
    /// Consent is bound to the disclosed destination. Nil means no external consent.
    public var consentHost: String?
    /// Chirp Keyboard turns a dictation ending in "new line" / "new paragraph" into line breaks. Off unless set;
    /// optional so older preference files still decode.
    public var spokenCommands: Bool?
    public init() {}
    public func permitsCorrection(health: Health) -> Bool {
        guard correction, health.correctionAvailable else { return false }
        if health.correctionLeavesMachine == false { return true }
        guard health.correctionLeavesMachine == true, let host = health.correctionHost, !host.isEmpty else { return false }
        return consentHost == host
    }
}
/// Preferences only. No API accepts transcript text, bearer tokens or audio. Never writes UserDefaults.
public final class PreferenceStore: Sendable {
    private let files: ProtectedFiles
    public init(root: URL) throws { files = try ProtectedFiles(root: root.appendingPathComponent("preferences", isDirectory: true)) }
    public func load() throws -> IOSPreferences {
        try files.transaction { try files.load(IOSPreferences.self, "preferences.json", max: 65_536) ?? IOSPreferences() }
    }
    public func save(_ preferences: IOSPreferences) throws {
        var clean = preferences
        guard clean.styleID.utf8.count <= 128, clean.prompts.count <= 32 else { throw CoreError.oversized }
        clean.prompts = clean.prompts.mapValues { CorrectionProfile.clampPrompt($0) }
        try files.transaction { try files.save(clean, "preferences.json", max: 65_536) }
    }
}

public enum DiagnosticCode: String, Codable, Sendable, CaseIterable {
    case auth, busy, tooLong, badAudio, badRequest, engine, unreachable, timeout, permission, interrupted, storage, unknown
    case offline, notFound, secure
    public static func server(_ value: String) -> Self {
        switch value { case "auth": .auth; case "busy": .busy; case "too_long": .tooLong
        case "bad_audio": .badAudio; case "bad_request": .badRequest; case "engine": .engine; default: .unknown }
    }
}
public enum SessionPhase: String, Codable, Sendable, CaseIterable {
    case idle, armed, connecting, listening, correcting, finished, failed
}
/// Export schema intentionally has no arbitrary strings or dictionaries, and accepts no Error/exception messages.
public struct DiagnosticEvent: Codable, Sendable, Equatable {
    public var phase: SessionPhase
    public var code: DiagnosticCode?
    public var durationMilliseconds: Int
    public var count: Int
    public init(phase: SessionPhase, code: DiagnosticCode? = nil, durationMilliseconds: Int = 0, count: Int = 0) {
        self.phase = phase; self.code = code
        self.durationMilliseconds = min(max(0, durationMilliseconds), 86_400_000)
        self.count = min(max(0, count), 1_000_000)
    }
}
public enum DiagnosticExport {
    public static func data(events: [DiagnosticEvent]) throws -> Data { try JSONEncoder().encode(Array(events.suffix(200))) }
}
