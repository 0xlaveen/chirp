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
    public init(client: String = "mac", correction: Bool = false, correctionProfile: String = CorrectionProfile.defaultID,
                correctionInstructions: String? = nil, correctionPrompt: String? = nil, wordTimings: Bool = false) {
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
            let text = CorrectionProfile.clampPrompt(prompt).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { message["correction_prompt"] = text }
        }
        if o.wordTimings { message["word_timings"] = true }
        return json(message)
    }
    public static let stop = json(["type": "stop"])
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

    public init(ok: Bool = true, engine: String? = nil, ready: Bool? = nil, debugRetention: Bool? = nil,
                correction: String? = nil, correctionLeavesMachine: Bool? = nil, correctionHost: String? = nil,
                correctionProfiles: [CorrectionProfile]? = nil, correctionKeepLoaded: Bool? = nil, correctionLoaded: Bool? = nil) {
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
    }

    public var correctionAvailable: Bool { correction == "available" }
}

/// Splits partial text into the stable prefix and the still-changing tail for the HUD.
public func splitPartial(text: String, stable: String) -> (stable: String, unstable: String) {
    guard !stable.isEmpty, text.hasPrefix(stable) else { return ("", text) }
    return (stable, String(text.dropFirst(stable.count)))
}
