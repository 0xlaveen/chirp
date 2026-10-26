import Foundation

/// Which devices used this Mac's server: the client side of `GET /v1/devices/activity` and
/// `PUT /v1/devices/activity/settings`. The server keeps only metadata (time, device, kind of request, length, result),
/// on this machine; it never holds what was said or written, and nothing here is logged. Only the owner token, read from
/// `~/.config/chirp/owner-token` on the server's own machine, opens it, so a remote server never shows activity.
/// Decoding tolerates kinds, outcomes and fields this Chirp does not know.

/// Who made a request.
public enum ActivitySource: Sendable, Equatable, Hashable {
    /// A phone paired with its own token. `name` is the server's current name for it, nil when it no longer knows it.
    case device(id: String, name: String?, revoked: Bool)
    /// The shared token used directly on the server's machine ("This Mac").
    case local
    /// The shared token through the proxy: phones paired without their own token.
    case shared
    case other(String)
}

/// What a request was for. Anything a newer server adds decodes as `.other`.
public enum ActivityKind: Sendable, Equatable, Hashable {
    case dictation, notesSegment, transcribe, notesStructure, notesReorganize, notesEdit, speakerModel
    case other(String)

    init(_ raw: String) {
        switch raw {
        case "dictation": self = .dictation
        case "notes_segment": self = .notesSegment
        case "transcribe": self = .transcribe
        case "notes_structure": self = .notesStructure
        case "notes_reorganize": self = .notesReorganize
        case "notes_edit": self = .notesEdit
        case "speaker_model": self = .speakerModel
        default: self = .other(raw)
        }
    }

    /// Dictation, Notes segment and Transcribe carry an audio length.
    public var hasAudio: Bool {
        switch self {
        case .dictation, .notesSegment, .transcribe: true
        default: false
        }
    }
}

/// How a request ended. Error codes the Chirp server returns to its client come through as `.other`.
public enum ActivityOutcome: Sendable, Equatable, Hashable {
    case ok, cancelled, rejected, timeout, busy, preempted, disconnected
    case other(String)

    init(_ raw: String) {
        switch raw {
        case "ok": self = .ok
        case "cancelled": self = .cancelled
        case "rejected": self = .rejected
        case "timeout": self = .timeout
        case "busy": self = .busy
        case "preempted": self = .preempted
        case "disconnected": self = .disconnected
        default: self = .other(raw)
        }
    }
}

/// A request that is running now (an utterance between `start` and its final).
public struct ActiveRequest: Sendable, Equatable {
    public var source: ActivitySource
    public var client: String?
    public var kind: ActivityKind
    public var profile: String?
    public var since: Date

    public init(source: ActivitySource, client: String? = nil, kind: ActivityKind, profile: String? = nil, since: Date) {
        self.source = source
        self.client = client
        self.kind = kind
        self.profile = profile
        self.since = since
    }
}

/// A finished request.
public struct ActivityEvent: Sendable, Equatable {
    public var at: Date
    public var source: ActivitySource
    public var client: String?
    public var kind: ActivityKind
    public var profile: String?
    /// Whether clean-up ran on it, when the server says.
    public var corrected: Bool?
    public var durationMS: Int
    public var audioMS: Int?
    public var outcome: ActivityOutcome

    public init(at: Date, source: ActivitySource, client: String? = nil, kind: ActivityKind, profile: String? = nil, corrected: Bool? = nil,
                durationMS: Int = 0, audioMS: Int? = nil, outcome: ActivityOutcome = .ok) {
        self.at = at
        self.source = source
        self.client = client
        self.kind = kind
        self.profile = profile
        self.corrected = corrected
        self.durationMS = durationMS
        self.audioMS = audioMS
        self.outcome = outcome
    }
}

/// Refused requests, counted only (no addresses or identities).
public struct Refusal: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        case unknownToken, noToken, revoked
        case other(String)
    }

    public var reason: Reason
    /// The revoked device, for `.revoked`.
    public var deviceID: String?
    public var deviceName: String?
    public var count: Int
    public var last: Date

    public init(reason: Reason, deviceID: String? = nil, deviceName: String? = nil, count: Int, last: Date) {
        self.reason = reason
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.count = count
        self.last = last
    }
}

public struct DeviceActivity: Sendable, Equatable {
    /// When the server last started.
    public var started: Date
    /// "Keep device activity": false means nothing is recorded or stored.
    public var keep: Bool
    public var maxEvents: Int
    public var maxAgeDays: Int
    public var active: [ActiveRequest]
    /// Newest first, as the server sends them.
    public var events: [ActivityEvent]
    public var refused: [Refusal]

    public init(started: Date, keep: Bool = true, maxEvents: Int = 5000, maxAgeDays: Int = 30, active: [ActiveRequest] = [],
                events: [ActivityEvent] = [], refused: [Refusal] = []) {
        self.started = started
        self.keep = keep
        self.maxEvents = maxEvents
        self.maxAgeDays = maxAgeDays
        self.active = active
        self.events = events
        self.refused = refused
    }

    public var isEmpty: Bool { active.isEmpty && events.isEmpty && refused.isEmpty }
}

/// Why activity is not shown. Never worth more than a line.
public enum ActivityError: Error, Sendable, Equatable {
    /// 401 or 403, or no owner token on this Mac: the activity parts stay hidden.
    case hidden
    /// 404: a server that predates device activity.
    case outdated
    /// Any other failure (no answer, another status, an unexpected body).
    case failed
}

/// What Settings → Devices needs from the server's activity. The real one is `DeviceActivityClient`; tests inject a fake.
public protocol DeviceActivityFetching: Sendable {
    func fetch() async throws(ActivityError) -> DeviceActivity
    /// "Keep device activity": off stops recording and deletes what is stored.
    func setKeep(_ keep: Bool) async throws(ActivityError)
}

extension ServerConfig {
    /// The owner token, beside the shared one. It opens only the activity endpoints.
    public static var defaultOwnerTokenPath: String { NSString(string: "~/.config/chirp/owner-token").expandingTildeInPath }
    public var deviceActivityURL: URL { baseURL.appendingPathComponent("v1/devices/activity") }
    public var deviceActivitySettingsURL: URL { baseURL.appendingPathComponent("v1/devices/activity/settings") }
}

public struct DeviceActivityClient: DeviceActivityFetching, @unchecked Sendable {
    public var baseURL: URL
    public var ownerTokenPath: String
    private let session: URLSession

    public init(baseURL: URL = ServerConfig.defaultURL, ownerTokenPath: String = ServerConfig.defaultOwnerTokenPath, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.ownerTokenPath = ownerTokenPath
        self.session = session
    }

    public func fetch() async throws(ActivityError) -> DeviceActivity {
        let data = try await send(URLRequest(url: ServerConfig(baseURL: baseURL).deviceActivityURL), timeout: 3)
        guard let activity = try? Self.decode(data) else { throw .failed }
        return activity
    }

    public func setKeep(_ keep: Bool) async throws(ActivityError) {
        var request = URLRequest(url: ServerConfig(baseURL: baseURL).deviceActivitySettingsURL)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data((keep ? #"{"keep":true}"# : #"{"keep":false}"#).utf8)
        _ = try await send(request, timeout: 5)
    }

    /// Sends with the owner token; maps 401/403 (and a missing token) to hidden, 404 to outdated and anything else to failed.
    private func send(_ request: URLRequest, timeout: TimeInterval) async throws(ActivityError) -> Data {
        guard let token = ServerConfig.readToken(path: ownerTokenPath) else { throw .hidden }
        var request = request
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeout
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { throw .failed }
        guard let http = response as? HTTPURLResponse else { throw .failed }
        switch http.statusCode {
        case 200: return data
        case 401, 403: throw .hidden
        case 404: throw .outdated
        default: throw .failed
        }
    }

    // MARK: decoding

    /// The server's UTC stamps, `2026-10-26T10:14:40Z`.
    static func date(_ stamp: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: stamp)
    }

    public static func decode(_ data: Data) throws -> DeviceActivity {
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        guard let started = date(wire.started) else { throw ActivityError.failed }
        // One event or refusal this client cannot read is skipped, never the whole list.
        return DeviceActivity(
            started: started,
            keep: wire.keep ?? true,
            maxEvents: wire.retention?.max_events ?? 5000,
            maxAgeDays: wire.retention?.max_age_days ?? 30,
            active: (wire.active ?? []).compactMap { $0.value?.model },
            events: (wire.events ?? []).compactMap { $0.value?.model },
            refused: (wire.refused ?? []).compactMap { $0.value?.model })
    }

    /// Decodes an element or yields nil, so one bad row does not fail the array.
    private struct Lossy<T: Decodable>: Decodable {
        var value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    private struct WireSource: Decodable {
        var kind: String
        var id: String?
        var name: String?
        var revoked: Bool?

        var model: ActivitySource {
            switch kind {
            case "device":
                guard let id else { return .other("device") }
                return .device(id: id, name: name, revoked: revoked ?? false)
            case "local": return .local
            case "shared": return .shared
            default: return .other(kind)
            }
        }
    }

    private struct WireActive: Decodable {
        var source: WireSource
        var client: String?
        var kind: String
        var profile: String?
        var since: String

        var model: ActiveRequest? {
            date(since).map { ActiveRequest(source: source.model, client: client, kind: ActivityKind(kind), profile: profile, since: $0) }
        }
    }

    private struct WireEvent: Decodable {
        var at: String
        var source: WireSource
        var client: String?
        var kind: String
        var profile: String?
        var corrected: Bool?
        var duration_ms: Int
        var audio_ms: Int?
        var outcome: String

        var model: ActivityEvent? {
            date(at).map {
                ActivityEvent(at: $0, source: source.model, client: client, kind: ActivityKind(kind), profile: profile, corrected: corrected,
                              durationMS: duration_ms, audioMS: audio_ms, outcome: ActivityOutcome(outcome))
            }
        }
    }

    private struct WireRefusal: Decodable {
        struct Device: Decodable { var id: String; var name: String? }
        var reason: String
        var device: Device?
        var count: Int
        var last: String

        var model: Refusal? {
            guard let last = date(last) else { return nil }
            let reason: Refusal.Reason
            switch self.reason {
            case "unknown_token": reason = .unknownToken
            case "no_token": reason = .noToken
            case "revoked": reason = .revoked
            default: reason = .other(self.reason)
            }
            return Refusal(reason: reason, deviceID: device?.id, deviceName: device?.name, count: count, last: last)
        }
    }

    private struct Wire: Decodable {
        struct Retention: Decodable { var max_events: Int?; var max_age_days: Int? }
        var started: String
        var keep: Bool?
        var retention: Retention?
        var active: [Lossy<WireActive>]?
        var events: [Lossy<WireEvent>]?
        var refused: [Lossy<WireRefusal>]?
    }
}

/// How often Settings → Devices asks for activity while it, or the Activity sheet, is on screen.
public enum ActivityPolling {
    public static let interval: TimeInterval = 5
}

/// Starts a repeating action and returns the way to stop it. The real one is a `Timer`; tests drive a fake clock.
public typealias RepeatingSchedule = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> @MainActor () -> Void

/// Refreshes activity every few seconds, only while the Devices tab or the Activity sheet is visible.
@MainActor
public final class ActivityPoller {
    private let schedule: RepeatingSchedule
    private let refresh: @MainActor () -> Void
    private var cancel: (@MainActor () -> Void)?

    public var tabVisible = false { didSet { update() } }
    public var sheetVisible = false { didSet { update() } }
    public var isRunning: Bool { cancel != nil }

    public init(schedule: @escaping RepeatingSchedule, refresh: @escaping @MainActor () -> Void) {
        self.schedule = schedule
        self.refresh = refresh
    }

    private func update() {
        let wanted = tabVisible || sheetVisible
        if wanted, cancel == nil {
            cancel = schedule(ActivityPolling.interval) { [weak self] in self?.refresh() }
        } else if !wanted, let stop = cancel {
            stop()
            cancel = nil
        }
    }

    /// The real schedule: a main-run-loop `Timer`.
    public static let timer: RepeatingSchedule = { interval, tick in
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in MainActor.assumeIsolated { tick() } }
        return { timer.invalidate() }
    }
}
