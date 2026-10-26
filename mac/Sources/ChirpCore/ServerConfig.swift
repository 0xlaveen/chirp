import Foundation

public enum SpeakersModelAction: String, Sendable { case download, remove }

/// A saved voice as the server lists it (#247): a name and how much speech it was saved from, never its voiceprint.
public struct SavedVoice: Decodable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// Seconds of the person's speech behind the voice.
    public var seconds: Double
    public var created: Date
    public var updated: Date
    /// False for a voice saved with another speaker model: listed ("name them again"), never recognised.
    public var compatible: Bool

    public init(id: String, name: String, seconds: Double, created: Date, updated: Date, compatible: Bool = true) {
        self.id = id
        self.name = name
        self.seconds = seconds
        self.created = created
        self.updated = updated
        self.compatible = compatible
    }

    /// A voice id: 16 lowercase hex characters.
    public static func isValidID(_ id: String) -> Bool {
        id.count == 16 && id.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// What the server accepts as a name: one line, no colon, a letter, at most 60 characters (the notes' speaker
    /// label rule, #212).
    public static let maxName = 60
    public static func isValidName(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        return !n.isEmpty && n.count <= maxName && !n.contains(":") && n.contains(where: \.isLetter)
            && !n.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format }
    }
}

/// `GET /v1/speakers/voices` and the answer to every library action but `identify`: the server-wide switch, the model
/// voices are compared with, and the voices. `voice` is the one `remember` saved or updated.
public struct SavedVoices: Decodable, Sendable, Equatable {
    public var enabled: Bool
    public var model: String
    public var voices: [SavedVoice]
    public var voice: SavedVoice?

    public init(enabled: Bool, model: String, voices: [SavedVoice], voice: SavedVoice? = nil) {
        self.enabled = enabled
        self.model = model
        self.voices = voices
        self.voice = voice
    }
}

/// Where `remember` takes a person's voice from.
public enum VoiceSource: Sendable, Equatable {
    /// The phone path: the note's speaker the server holds in memory (`final.speakers.generation` and the slot).
    case note(session: String, generation: String, speaker: Int)
    /// The Mac path: PCM16 little-endian, 16 kHz mono, at most `VoiceClip.maxBytes` (30 s) of the person's settled turns.
    case audio(Data)
}

/// One person's clip for `identify`.
public struct VoiceClip: Sendable, Equatable {
    /// 30 s of PCM16 at 16 kHz: the most a clip may hold.
    public static let maxBytes = 30 * 16_000 * 2
    public var person: Int
    public var pcm: Data

    public init(person: Int, pcm: Data) {
        self.person = person
        self.pcm = pcm
    }

    /// The last 30 s of 16 kHz float samples as the clip's PCM16.
    public static func pcm(_ samples: [Float]) -> Data {
        var out = Data(capacity: min(samples.count, maxBytes / 2) * 2)
        for sample in samples.suffix(maxBytes / 2) {
            var value = Int16(max(-1, min(1, sample)) * 32767).littleEndian
            withUnsafeBytes(of: &value) { out.append(contentsOf: $0) }
        }
        return out
    }
}

/// `identify`'s answer: a person of the request recognised as a saved voice.
public struct IdentifiedVoice: Decodable, Sendable, Equatable {
    public var person: Int
    public var voice: String
    public var name: String

    public init(person: Int, voice: String, name: String) {
        self.person = person
        self.voice = voice
        self.name = name
    }
}

/// `POST /v1/speakers/voices` actions other than `identify` (`ServerConfig.identifyVoices`).
public enum VoiceLibraryAction: Sendable, Equatable {
    /// Save a new voice, or with `voice` update that one (a seconds-weighted mean).
    case remember(name: String, from: VoiceSource, voice: String? = nil)
    /// Moves a voice the Mac saved before the shared library (#18) to the server, once: its 256-number voiceprint from
    /// a model the server accepts (`wespeaker_v2@df2625a`, which agrees with the server's; docs/bench.md).
    case importVoice(name: String, embedding: [Float], seconds: Double, model: String)
    /// Renames the saved voice only; notes keep their own names.
    case rename(voice: String, name: String)
    case forget(voice: String)
    case forgetAll
    case enable
    /// Turns "Remember voices" off server-wide (stops saving and recognising); `forget` also deletes every voice.
    case disable(forget: Bool)

    var body: [String: Any] {
        switch self {
        case .remember(let name, let from, let voice):
            var body: [String: Any] = ["action": "remember", "name": name]
            switch from {
            case .note(let session, let generation, let speaker):
                body["from"] = ["session": session, "generation": generation, "speaker": speaker]
            case .audio(let pcm): body["audio"] = pcm.base64EncodedString()
            }
            if let voice { body["voice"] = voice }
            return body
        case .importVoice(let name, let embedding, let seconds, let model):
            var data = Data(capacity: embedding.count * 4)
            for value in embedding {
                var bits = value.bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
            }
            return ["action": "import", "name": name, "embedding": data.base64EncodedString(), "seconds": seconds, "model": model]
        case .rename(let voice, let name): return ["action": "rename", "voice": voice, "name": name]
        case .forget(let voice): return ["action": "forget", "voice": voice]
        case .forgetAll: return ["action": "forget_all"]
        case .enable: return ["action": "enable"]
        case .disable(let forget): return ["action": "disable", "forget": forget]
        }
    }
}

/// Why the library refused a request: the server's error code, or the HTTP status without one.
public enum VoiceLibraryError: Error, Equatable, Sendable {
    /// 404 `gone`: the server no longer holds that note's speakers. "Record a little more with them, then try again".
    case gone
    /// 409 `too_short`: under 20 s of this person's speech (the name stays in the note only).
    case tooShort
    /// 409 `disabled`: "Remember voices" is off on the server.
    case disabled
    /// 409 `full`: 50 saved voices.
    case full
    /// 404 `no_voice`: that voice was forgotten (perhaps on another device).
    case noVoice
    /// 409 `unavailable`: a clip needs the speaker model, which is not downloaded.
    case unavailable
    /// 413: a clip over 30 s.
    case clipTooLong
    /// 400 `bad_speakers`: a malformed request, including a name the server does not accept.
    case badRequest
    /// A server without saved voices (no route): "Update Chirp on your Mac to save voices".
    case unsupported
    case unauthorized
    /// Anything else: the HTTP status, or the server's own code (`voices_file`, `failed`).
    case server(Int, String?)

    static func from(status: Int, data: Data) -> VoiceLibraryError {
        let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["code"] as? String
        switch (status, code) {
        case (404, "gone"): return .gone
        case (404, "no_voice"): return .noVoice
        case (409, "too_short"): return .tooShort
        case (409, "disabled"): return .disabled
        case (409, "full"): return .full
        case (409, "unavailable"): return .unavailable
        case (413, _): return .clipTooLong
        case (400, _): return .badRequest
        case (401, _): return .unauthorized
        case (404, _), (405, _): return .unsupported
        default: return .server(status, code)
        }
    }
}

/// Where the server is and how to authenticate. The token lives in `~/.config/chirp/token`
/// (written by `chirp-server`); nothing else is persisted by the client.
public struct ServerConfig: Sendable, Equatable {
    public static let defaultURL = URL(string: "http://127.0.0.1:7821")!
    public static var defaultTokenPath: String { NSString(string: "~/.config/chirp/token").expandingTildeInPath }

    public var baseURL: URL
    public var token: String?

    public init(baseURL: URL = defaultURL, token: String? = nil) {
        self.baseURL = baseURL
        self.token = token
    }

    public static func readToken(path: String = defaultTokenPath) -> String? {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    public static func load(urlString: String?, tokenPath: String = defaultTokenPath) -> ServerConfig {
        let url = urlString.flatMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) } ?? defaultURL
        return ServerConfig(baseURL: url, token: readToken(path: tokenPath))
    }

    /// `ws(s)://…/v1/stream`, keeping any base path such as `/chirp`.
    public var streamURL: URL {
        var c = URLComponents(url: baseURL.appendingPathComponent("v1/stream"), resolvingAgainstBaseURL: false)!
        c.scheme = (baseURL.scheme == "https" || baseURL.scheme == "wss") ? "wss" : "ws"
        return c.url!
    }

    public var healthURL: URL { baseURL.appendingPathComponent("v1/health") }

    /// `POST …/v1/notes/structure`, keeping any base path such as `/chirp`.
    public var notesStructureURL: URL { baseURL.appendingPathComponent("v1/notes/structure") }

    /// `POST …/v1/notes/reorganize`, keeping any base path such as `/chirp`.
    public var notesReorganizeURL: URL { baseURL.appendingPathComponent("v1/notes/reorganize") }
    /// `POST …/v1/notes/edit`.
    public var notesEditURL: URL { baseURL.appendingPathComponent("v1/notes/edit") }

    /// `POST …/v1/speakers/model`.
    public var speakersModelURL: URL { baseURL.appendingPathComponent("v1/speakers/model") }
    /// `GET/POST …/v1/speakers/voices` (saved voices, #247).
    public var speakersVoicesURL: URL { baseURL.appendingPathComponent("v1/speakers/voices") }

    public func authorized(_ request: URLRequest) -> URLRequest {
        var r = request
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return r
    }

    public var host: String { baseURL.host ?? baseURL.absoluteString }
    public var isLoopback: Bool { ["127.0.0.1", "localhost", "::1"].contains(baseURL.host ?? "") }

    public func fetchHealth(session: URLSession = .shared) async throws -> Health {
        var req = authorized(URLRequest(url: healthURL))
        req.timeoutInterval = 3
        let (data, response) = try await session.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Health.self, from: data)
    }

    /// One structuring pass. `timeout` is the server's structure timeout plus a margin; a client timeout throws the
    /// `URLError` and the caller treats it as `error: "timeout"`. Non-200 answers throw `NotesStructureError`.
    public func structureNotes(_ r: NotesStructureRequest, session: URLSession = .shared,
                               timeout: TimeInterval = 35) async throws -> NotesStructureResponse {
        try await postNotes(r, to: notesStructureURL, session: session, timeout: timeout)
    }

    /// One reorganize pass, with the same error mapping as `structureNotes` (a 404 means only reorganize is missing).
    public func reorganizeNotes(_ r: NotesReorganizeRequest, session: URLSession = .shared,
                                timeout: TimeInterval = 50) async throws -> NotesReorganizeResponse {
        try await postNotes(r, to: notesReorganizeURL, session: session, timeout: timeout)
    }

    /// One voice edit, with the same error mapping (a 404 means only editing is missing).
    public func editNotes(_ r: NotesEditRequest, session: URLSession = .shared,
                          timeout: TimeInterval = 50) async throws -> NotesEditResponse {
        try await postNotes(r, to: notesEditURL, session: session, timeout: timeout)
    }

    /// `POST /v1/speakers/model`: `download` (only after the user agreed to the one download) or `remove`. Returns the
    /// model's state after it (`downloading` answers 202; 409 means a remove while downloading, which still reports it).
    public func speakersModel(_ action: SpeakersModelAction, session: URLSession = .shared) async throws -> SpeakersModel {
        var req = authorized(URLRequest(url: speakersModelURL))
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{\"action\":\"\(action.rawValue)\"}".utf8)
        let (data, response) = try await session.data(for: req)
        guard let status = (response as? HTTPURLResponse)?.statusCode, [200, 202, 409].contains(status), data.count <= 4096
        else { throw URLError(.badServerResponse) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SpeakersModel.self, from: data)
    }

    /// `GET /v1/speakers/voices`: the server's saved voices (names and seconds, never a voiceprint) and its switch.
    public func savedVoices(session: URLSession = .shared) async throws -> SavedVoices {
        var req = authorized(URLRequest(url: speakersVoicesURL))
        req.timeoutInterval = 10
        return try await voicesRequest(req, session: session)
    }

    /// One `POST /v1/speakers/voices` action; the library after it. Refusals throw `VoiceLibraryError`.
    public func savedVoices(_ action: VoiceLibraryAction, session: URLSession = .shared) async throws -> SavedVoices {
        try await voicesRequest(voicesPost(action.body, timeout: 30), session: session)
    }

    /// `identify`: which of these people (one clip each, up to 8) are saved voices, one person per voice. People with
    /// under about 10 s of speech are never matched. An empty answer without asking when `people` is empty.
    public func identifyVoices(_ people: [VoiceClip], session: URLSession = .shared) async throws -> [IdentifiedVoice] {
        guard !people.isEmpty else { return [] }
        struct Answer: Decodable { var matches: [IdentifiedVoice] }
        let body: [String: Any] = ["action": "identify",
                                   "people": people.map { ["person": $0.person, "audio": $0.pcm.base64EncodedString()] }]
        let answer: Answer = try await voicesRequest(voicesPost(body, timeout: 60), session: session)
        return answer.matches
    }

    private func voicesPost(_ body: [String: Any], timeout: TimeInterval) throws -> URLRequest {
        var req = authorized(URLRequest(url: speakersVoicesURL))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return req
    }

    private func voicesRequest<Response: Decodable>(_ req: URLRequest, session: URLSession) async throws -> Response {
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw VoiceLibraryError.from(status: status, data: data) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Response.self, from: data)
    }

    private func postNotes<Request: Encodable, Response: Decodable>(_ r: Request, to url: URL, session: URLSession,
                                                                    timeout: TimeInterval) async throws -> Response {
        var req = authorized(URLRequest(url: url))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(r)
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw NotesStructureError.from(status: status) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Response.self, from: data)
    }
}
