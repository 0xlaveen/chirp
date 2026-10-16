import Foundation

/// Wire protocol v1 (docs/architecture.md §3). Version bumps only add fields, so decoding is lenient.

public struct Timings: Codable, Sendable, Equatable {
    public var audio: Double?
    public var firstPartial: Double?
    public var finalize: Double?
    public var correction: Double?
}

public struct FinalResult: Sendable, Equatable {
    public var text: String
    public var raw: String
    public var corrected: Bool
    public var correctionError: String?
    public var timings: Timings?

    public init(text: String, raw: String? = nil, corrected: Bool = false,
                correctionError: String? = nil, timings: Timings? = nil) {
        self.text = text
        self.raw = raw ?? text
        self.corrected = corrected
        self.correctionError = correctionError
        self.timings = timings
    }

    /// True when the server rewrote the transcript and the raw text differs (offers "Use raw").
    public var canUseRaw: Bool { corrected && raw != text }
}

public enum ServerMessage: Sendable, Equatable {
    case ready(session: String, engine: String?, debugRetention: Bool)
    case partial(seq: Int, text: String, stable: String)
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
        var corrected: Bool?
        var correctionError: String?
        var timingsMs: Timings?
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
            return .partial(seq: d.seq ?? 0, text: text, stable: d.stable ?? "")
        case "final":
            let text = d.text ?? ""
            return .final(FinalResult(text: text, raw: d.raw, corrected: d.corrected ?? false,
                                      correctionError: d.correctionError, timings: d.timingsMs))
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
    public init(client: String = "mac", correction: Bool = false) {
        self.client = client
        self.correction = correction
    }
}

public enum ClientMessage {
    public static func start(_ o: StartOptions) -> String {
        json(["type": "start", "sample_rate": 16000, "encoding": "pcm_s16le",
              "client": o.client, "correction": o.correction])
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

    public var correctionAvailable: Bool { correction == "available" }
}

/// Splits partial text into the stable prefix and the still-changing tail for the HUD.
public func splitPartial(text: String, stable: String) -> (stable: String, unstable: String) {
    guard !stable.isEmpty, text.hasPrefix(stable) else { return ("", text) }
    return (stable, String(text.dropFirst(stable.count)))
}
