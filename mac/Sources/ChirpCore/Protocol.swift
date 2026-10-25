import Foundation

/// Wire protocol v1 (docs/architecture.md §3). Version bumps only add fields, so decoding is lenient.

public struct Timings: Codable, Sendable, Equatable {
    public var audio: Double?
    public var firstPartial: Double?
    public var finalize: Double?
    public var correction: Double?
}

/// One word of the raw transcript with its audio span, seconds from the utterance's first sample. Only sent when
/// `start.word_timings` was asked for; `stable` means later partials leave the word alone (the final may still revise it).
public struct WordTiming: Codable, Sendable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double
    public var stable: Bool

    public init(text: String, start: Double, end: Double, stable: Bool = false) {
        self.text = text
        self.start = start
        self.end = end
        self.stable = stable
    }

    private enum CodingKeys: String, CodingKey { case text, start, end, stable }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
        end = try c.decodeIfPresent(Double.self, forKey: .end) ?? start
        stable = try c.decodeIfPresent(Bool.self, forKey: .stable) ?? false
    }
}

public struct FinalResult: Sendable, Equatable {
    public var text: String
    public var raw: String
    public var corrected: Bool
    public var correctionError: String?
    public var timings: Timings?
    /// The raw transcript's word timings, when asked for and the engine has them.
    public var words: [WordTiming]?

    public init(text: String, raw: String? = nil, corrected: Bool = false,
                correctionError: String? = nil, timings: Timings? = nil, words: [WordTiming]? = nil) {
        self.text = text
        self.raw = raw ?? text
        self.corrected = corrected
        self.correctionError = correctionError
        self.timings = timings
        self.words = words
    }

    /// True when the server rewrote the transcript and the raw text differs (offers "Use raw").
    public var canUseRaw: Bool { corrected && raw != text }
}

public enum ServerMessage: Sendable, Equatable {
    case ready(session: String, engine: String?, debugRetention: Bool)
    /// `words` is nil unless word timings were asked for and the server's engine has them.
    case partial(seq: Int, text: String, stable: String, words: [WordTiming]? = nil)
    /// Clean-up is about to run on `raw` with style `profile`; the `final` follows. Old servers never send it.
    case correcting(seq: Int, raw: String, profile: String, words: [WordTiming]? = nil)
    case final(FinalResult)
    case error(code: String, message: String)
    case unknown(type: String)

    private struct DTO: Decodable {
        var type: String
        var session: String?
        var engine: String?
        var debugRetention: Bool?
        var seq: Int?
        var text: String?
        var stable: String?
        var raw: String?
        var profile: String?
        var corrected: Bool?
        var correctionError: String?
        var timingsMs: Timings?
        var words: [WordTiming]?
        var code: String?
        var message: String?
    }

    public static func decode(_ data: Data) throws -> ServerMessage {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let d = try decoder.decode(DTO.self, from: data)
        switch d.type {
        case "ready":
            return .ready(session: d.session ?? "", engine: d.engine, debugRetention: d.debugRetention ?? false)
        case "partial":
            let text = d.text ?? ""
            return .partial(seq: d.seq ?? 0, text: text, stable: d.stable ?? "", words: d.words)
        case "correcting":
            return .correcting(seq: d.seq ?? 0, raw: d.raw ?? "", profile: d.profile ?? CorrectionProfile.defaultID, words: d.words)
        case "final":
            let text = d.text ?? ""
            return .final(FinalResult(text: text, raw: d.raw, corrected: d.corrected ?? false,
                                      correctionError: d.correctionError, timings: d.timingsMs, words: d.words))
        case "error":
            return .error(code: d.code ?? "engine", message: d.message ?? "Server error")
        default:
            return .unknown(type: d.type)
        }
    }
}

public struct StartOptions: Sendable, Equatable {
    public var client: String
    public var correction: Bool
    /// The clean-up style (a `correction_profiles` id).
    public var correctionProfile: String
    /// Only sent for the `custom` profile, clamped to `CorrectionProfile.maxInstructionLength`. Never logged.
    public var correctionInstructions: String?
    /// The user's edited prompt for the style, clamped to `CorrectionProfile.maxPromptLength`; nil when the style was
    /// not edited, so the server's default (and its updates) apply. Never logged.
    public var correctionPrompt: String?
    /// Ask for per-word timings on partials and finals (the HUD's word waveform). Off leaves the start message as it was.
    public var wordTimings: Bool
    /// What Learn from my edits learned for this app (`start.learned`, version 1); nil or empty sends nothing. Never logged.
    public var learned: LearnedPayload?
    public init(client: String = "mac", correction: Bool = false, correctionProfile: String = CorrectionProfile.defaultID,
                correctionInstructions: String? = nil, correctionPrompt: String? = nil, wordTimings: Bool = false,
                learned: LearnedPayload? = nil) {
        self.learned = learned
        self.client = client
        self.correction = correction
        self.correctionProfile = correctionProfile
        self.correctionInstructions = correctionInstructions
        self.correctionPrompt = correctionPrompt
        self.wordTimings = wordTimings
    }
}

public enum ClientMessage {
    public static func start(_ o: StartOptions) -> String {
        var message: [String: Any] = ["type": "start", "sample_rate": 16000, "encoding": "pcm_s16le",
                                      "client": o.client, "correction": o.correction,
                                      "correction_profile": o.correctionProfile]
        if o.correctionProfile == CorrectionProfile.customID, let text = CorrectionProfile.clamp(o.correctionInstructions ?? ""),
           !text.isEmpty {
            message["correction_instructions"] = text
        }
        if let prompt = o.correctionPrompt {
            // Presence (including empty) overrides the style on the wire. UI policy may omit blank edits.
            message["correction_prompt"] = CorrectionProfile.clampPrompt(prompt)
        }
        if o.wordTimings { message["word_timings"] = true }
        if let learned = o.learned, !learned.isEmpty { message["learned"] = learned.wire }
        return json(message)
    }
    public static let stop = json(["type": "stop"])
    /// `stop` with Live Notes clean-up context (the end of the previous segment's final); nil sends the plain `stop`.
    /// Only for a server whose health has `notes_context`. Never logged.
    public static func stop(context: String?) -> String {
        guard let context, !context.isEmpty else { return stop }
        return json(["type": "stop", "context": context])
    }
    public static let cancel = json(["type": "cancel"])

    private static func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

/// `GET /v1/health` (authenticated variant).
public struct Health: Decodable, Sendable, Equatable {
    public var ok: Bool
    public var engine: String?
    public var ready: Bool?
    public var debugRetention: Bool?
    public var correction: String?
    public var correctionLeavesMachine: Bool?
    public var correctionHost: String?
    /// The clean-up styles the server offers; nil from a server that predates them.
    public var correctionProfiles: [CorrectionProfile]?
    /// Authenticated health only; nil from a server that predates "keep clean-up model loaded".
    public var correctionKeepLoaded: Bool?
    public var correctionLoaded: Bool?
    /// `POST /v1/notes/structure` exists (authenticated health only); nil from a server that predates Live Notes.
    public var notesStructure: Bool?
    /// `POST /v1/notes/reorganize` exists (authenticated health only); nil from a server that predates it.
    public var notesReorganize: Bool?
    /// The hidden `live_notes` style exists (authenticated health only); nil from an older server, which gets `default`.
    public var notesCorrection: Bool?
    /// `stop.context` is taken: the end of the previous Live Notes segment, for casing and punctuation at the join.
    public var notesContext: Bool?
    /// `POST /v1/notes/edit` exists (a spoken edit instruction); nil from a server that predates it.
    public var notesEdit: Bool?
    /// Build, API level and capabilities (authenticated health only); nil from a server that predates them.
    public var version: String?
    public var commit: String?
    public var api: Int?
    public var capabilities: [String]?
    /// Unix seconds the server process started, and the folder it runs from (home shown as ~).
    public var startedAt: Double?
    public var source: String?

    public init(ok: Bool = true, engine: String? = nil, ready: Bool? = nil, debugRetention: Bool? = nil,
                correction: String? = nil, correctionLeavesMachine: Bool? = nil, correctionHost: String? = nil,
                correctionProfiles: [CorrectionProfile]? = nil, correctionKeepLoaded: Bool? = nil, correctionLoaded: Bool? = nil,
                notesStructure: Bool? = nil, notesCorrection: Bool? = nil, notesReorganize: Bool? = nil, notesContext: Bool? = nil,
                notesEdit: Bool? = nil, version: String? = nil, commit: String? = nil, api: Int? = nil, capabilities: [String]? = nil,
                startedAt: Double? = nil, source: String? = nil) {
        self.ok = ok
        self.engine = engine
        self.ready = ready
        self.debugRetention = debugRetention
        self.correction = correction
        self.correctionLeavesMachine = correctionLeavesMachine
        self.correctionHost = correctionHost
        self.correctionProfiles = correctionProfiles
        self.correctionKeepLoaded = correctionKeepLoaded
        self.correctionLoaded = correctionLoaded
        self.notesStructure = notesStructure
        self.notesCorrection = notesCorrection
        self.notesReorganize = notesReorganize
        self.notesContext = notesContext
        self.notesEdit = notesEdit
        self.version = version
        self.commit = commit
        self.api = api
        self.capabilities = capabilities
        self.startedAt = startedAt
        self.source = source
    }

    public var correctionAvailable: Bool { correction == "available" }
}

/// `POST /v1/notes/structure`: the open window's transcript plus the settled headings for continuity. Only
/// `transcript`, `outline` and `final` go on the wire; `windowEnd` (the last segment index the window covered),
/// `version` and `windowGeneration` stay on the client so a late response can be matched to the window and tail it
/// was asked for. Never logged.
public struct NotesStructureRequest: Encodable, Sendable, Equatable {
    public var transcript: String
    public var outline: [String]
    public var final: Bool
    public var windowEnd: Int
    public var version: Int
    public var windowGeneration: Int
    /// The `NotesDocument.id` the request was made from.
    public var documentID: UUID?

    public init(transcript: String, outline: [String] = [], final: Bool = false, windowEnd: Int = 0, version: Int = 0,
                windowGeneration: Int = 0, documentID: UUID? = nil) {
        self.transcript = transcript
        self.outline = outline
        self.final = final
        self.windowEnd = windowEnd
        self.version = version
        self.windowGeneration = windowGeneration
        self.documentID = documentID
    }

    private enum CodingKeys: String, CodingKey { case transcript, outline, final }
}

/// The structuring answer. `structured:false` fails closed: `markdown` is nil and `error` says why
/// (`timeout`, `http` or `rejected`); the client keeps its previous block.
public struct NotesStructureResponse: Decodable, Sendable, Equatable {
    public var markdown: String?
    public var structured: Bool
    public var error: String?
    /// Which guard rejected the output (`novel_name`, `negation`, `dropped_number`…); nil from older servers.
    public var reason: String?
    public var timingsMs: [String: Double]?

    public init(markdown: String?, structured: Bool, error: String? = nil, reason: String? = nil, timingsMs: [String: Double]? = nil) {
        self.markdown = markdown
        self.structured = structured
        self.error = error
        self.reason = reason
        self.timingsMs = timingsMs
    }

    /// `rejected: novel_name`, or the bare code: what a retry note and a log line show.
    public var failureLabel: String { NotesFailure.label(error: error, reason: reason) }

    /// A failed pass, as the client records a timeout or transport error of its own.
    public static func failed(_ code: String) -> NotesStructureResponse { NotesStructureResponse(markdown: nil, structured: false, error: code) }

    private enum CodingKeys: String, CodingKey { case markdown, structured, error, reason, timingsMs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        markdown = try c.decodeIfPresent(String.self, forKey: .markdown)
        structured = try c.decodeIfPresent(Bool.self, forKey: .structured) ?? false
        error = try c.decodeIfPresent(String.self, forKey: .error)
        reason = try? c.decodeIfPresent(String.self, forKey: .reason)
        timingsMs = try? c.decodeIfPresent([String: Double].self, forKey: .timingsMs)
        if markdown == nil { structured = false }
    }
}

/// `POST /v1/notes/reorganize`: the trailing sections of the notes (user and AI Markdown) plus the headings above
/// them for context. Only `notes`, `outline` and `final` go on the wire; `version` and `range` (the scope, UTF-16, in
/// the text the request was made from) stay on the client so a result is applied only to the text it was made for.
/// Never logged.
public struct NotesReorganizeRequest: Encodable, Sendable, Equatable {
    public var notes: String
    public var outline: [String]
    public var final: Bool
    public var version: Int
    public var range: NSRange
    /// The `NotesDocument.id` the request was made from.
    public var documentID: UUID?
    /// Organize's merge pass: further sections (after `range`) sent along with it; the answer replaces `range` and
    /// these go. Client-only, like `range`.
    public var merged: [NSRange] = []

    public init(notes: String, outline: [String] = [], final: Bool = false, version: Int = 0, range: NSRange = NSRange(),
                documentID: UUID? = nil) {
        self.notes = notes
        self.outline = outline
        self.final = final
        self.version = version
        self.range = range
        self.documentID = documentID
    }

    private enum CodingKeys: String, CodingKey { case notes, outline, final }
}

/// The reorganize answer. `reorganized:false` fails closed (`markdown` nil, `error` says why); `changed:false` means
/// the notes were already tidy and nothing is applied. `error: "preempted"` means a queued segment clean-up took the
/// model first: the pass did not run, which is not a failure.
public struct NotesReorganizeResponse: Decodable, Sendable, Equatable {
    public var markdown: String?
    public var reorganized: Bool
    public var changed: Bool
    public var error: String?
    /// Which guard rejected the output; nil from older servers.
    public var reason: String?
    public var timingsMs: [String: Double]?

    public init(markdown: String?, reorganized: Bool, changed: Bool = true, error: String? = nil, reason: String? = nil,
                timingsMs: [String: Double]? = nil) {
        self.markdown = markdown
        self.reorganized = reorganized
        self.changed = changed
        self.error = error
        self.reason = reason
        self.timingsMs = timingsMs
    }

    public var failureLabel: String { NotesFailure.label(error: error, reason: reason) }

    /// The server gave the model to a segment clean-up before this pass finished.
    public var preempted: Bool { !reorganized && error == "preempted" }

    /// A failed pass, as the client records a timeout or transport error of its own.
    public static func failed(_ code: String) -> NotesReorganizeResponse {
        NotesReorganizeResponse(markdown: nil, reorganized: false, changed: false, error: code)
    }

    private enum CodingKeys: String, CodingKey { case markdown, reorganized, changed, error, reason, timingsMs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        markdown = try c.decodeIfPresent(String.self, forKey: .markdown)
        reorganized = try c.decodeIfPresent(Bool.self, forKey: .reorganized) ?? false
        changed = try c.decodeIfPresent(Bool.self, forKey: .changed) ?? false
        error = try c.decodeIfPresent(String.self, forKey: .error)
        reason = try? c.decodeIfPresent(String.self, forKey: .reason)
        timingsMs = try? c.decodeIfPresent([String: Double].self, forKey: .timingsMs)
        if markdown == nil { reorganized = false; changed = false }
    }
}

/// How a failed notes pass is shown and logged.
public enum NotesFailure {
    /// A guard name as the server sends it (`novel_name`), or nil for anything else: it is shown and logged, so
    /// it must never be free text.
    public static func guardName(_ reason: String?) -> String? {
        guard let reason, (1...40).contains(reason.count),
              reason.allSatisfy({ $0 == "_" || ($0.isASCII && ($0.isLowercase || $0.isNumber)) }) else { return nil }
        return reason
    }

    /// `rejected: novel_name`, or just the code (`timeout`) without a usable reason.
    public static func label(error: String?, reason: String?) -> String {
        let code = error ?? "http"
        return guardName(reason).map { "\(code): \($0)" } ?? code
    }
}

/// Why `structureNotes` or `reorganizeNotes` got no answer to use.
public enum NotesStructureError: Error, Equatable, Sendable {
    /// 409 `notes_off`: correction is off on the server.
    case off
    /// The server has no structuring endpoint (404: it predates Live Notes).
    case unsupported(Int)
    /// 503 `busy`: another structuring pass is running on the server.
    case busy
    /// 401: the token was rejected.
    case auth
    /// Any other non-200 status.
    case http(Int)

    public static func from(status: Int) -> NotesStructureError {
        switch status {
        case 401: .auth
        case 404, 405: .unsupported(status)
        case 409: .off
        case 503: .busy
        default: .http(status)
        }
    }

    /// The short code shown in "Couldn't update notes (…)".
    public var code: String {
        switch self {
        case .off: "off"
        case .unsupported: "unsupported"
        case .busy: "busy"
        case .auth: "auth"
        case .http: "http"
        }
    }
}

/// Splits partial text into the stable prefix and the still-changing tail for the HUD.
public func splitPartial(text: String, stable: String) -> (stable: String, unstable: String) {
    guard !stable.isEmpty, text.hasPrefix(stable) else { return ("", text) }
    return (stable, String(text.dropFirst(stable.count)))
}
