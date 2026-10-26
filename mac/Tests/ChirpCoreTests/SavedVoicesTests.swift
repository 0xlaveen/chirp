import Foundation
import Testing
@testable import ChirpCore

/// Saved voices on the server (#247): `final.speakers.matches`, the health fields, and the `/v1/speakers/voices` client
/// the Mac and iOS share. The server's own suite is `server/tests/test_voices.py`.
@Suite struct SavedVoicesWireTests {
    private func speakers(_ json: String) throws -> ServerSpeakers? {
        let message = #"{"type":"final","text":"Hi.","raw":"hi","corrected":true,"speakers":\#(json)}"#
        guard case .final(let f) = try ServerMessage.decode(Data(message.utf8)) else { throw CocoaError(.coderInvalidValue) }
        return f.speakers
    }

    private let turns = #""generation":"g1","turns":[{"speaker":1,"start":0,"text":"Hi."}]"#

    @Test func matchesNameTheNotesPeople() throws {
        let s = try #require(try speakers(#"{\#(turns),"matches":[{"speaker":1,"voice":"0123456789abcdef","name":"Maya"}]}"#))
        #expect(s.matches == [ServerVoiceMatch(speaker: 1, voice: "0123456789abcdef", name: "Maya")])
        #expect(s.turns.map(\.speaker) == [1])
        #expect(try speakers(#"{\#(turns),"matches":[]}"#)?.matches == [])
    }

    @Test func withoutVoicesTheMessageIsAsBefore() throws {
        let s = try #require(try speakers("{\(turns)}"))
        #expect(s.matches == nil && s == ServerSpeakers(generation: "g1", turns: [ServerTurn(speaker: 1, start: 0, text: "Hi.")]))
    }

    @Test func malformedMatchesAreDroppedAndTheTurnsStay() throws {
        for bad in [#""no""#, #"[{"speaker":99,"voice":"0123456789abcdef","name":"Maya"}]"#,
                    #"[{"speaker":1,"voice":"short","name":"Maya"}]"#, #"[{"speaker":1,"voice":"0123456789abcdef","name":"A: B"}]"#,
                    #"[{"speaker":1,"voice":"0123456789abcdef","name":""}]"#, #"[{"speaker":1,"voice":"0123456789ABCDEF","name":"Maya"}]"#,
                    #"[{"speaker":1,"voice":"0123456789abcdef","name":"Maya"},{"speaker":1,"voice":"fedcba9876543210","name":"Kim"}]"#,
                    #"[{"speaker":1,"voice":"0123456789abcdef","name":"Maya"},{"speaker":2,"voice":"0123456789abcdef","name":"Maya"}]"#] {
            let s = try #require(try speakers(#"{\#(turns),"matches":\#(bad)}"#), "\(bad)")
            #expect(s.matches == nil && s.turns.count == 1, "\(bad)")
        }
    }

    @Test func healthAdvertisesTheLibrary() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let h = try decoder.decode(Health.self, from: Data(#"""
        {"ok":true,"speaker_voices":true,"capabilities":["notes_speakers","speaker_voices"],
         "speakers_voices":{"enabled":true,"count":2,"model":"wespeaker-voxceleb-resnet34-LM@f0c48c29"}}
        """#.utf8))
        #expect(h.supportsSpeakerVoices)
        #expect(h.speakersVoices == SpeakersVoices(enabled: true, count: 2, model: "wespeaker-voxceleb-resnet34-LM@f0c48c29"))
        let old = try decoder.decode(Health.self, from: Data(#"{"ok":true,"notes_speakers":true,"capabilities":["notes_speakers"]}"#.utf8))
        #expect(!old.supportsSpeakerVoices && old.speakersVoices == nil)
        let broken = try decoder.decode(Health.self, from: Data(#"{"ok":true,"speakers_voices":{"enabled":false,"count":0,"error":"unreadable"}}"#.utf8))
        #expect(broken.speakersVoices?.error == "unreadable")
    }

    @Test func namesFollowTheServersRule() {
        #expect(SavedVoice.isValidName("Maya") && SavedVoice.isValidName("  Maya van Dijk ") && SavedVoice.isValidName("Zoë"))
        for bad in ["", "   ", "Maya: hi", String(repeating: "x", count: 61), "Ma\nya", "12345", "Ma\u{200B}ya"] {
            #expect(!SavedVoice.isValidName(bad), "\(bad)")
        }
        #expect(SavedVoice.isValidID("0123456789abcdef") && !SavedVoice.isValidID("0123456789abcde") && !SavedVoice.isValidID("0123456789abcdeg"))
    }

    @Test func clipsKeepTheLastThirtySecondsAsPCM16() {
        #expect(VoiceClip.pcm([0, 1, -1, 2]) == Data([0, 0, 0xFF, 0x7F, 0x01, 0x80, 0xFF, 0x7F]))
        let long = [Float](repeating: 0, count: 40 * 16_000) + [0.5]
        let pcm = VoiceClip.pcm(long)
        #expect(pcm.count == VoiceClip.maxBytes && pcm.suffix(2) == Data([0xFF, 0x3F]))
    }
}

/// A fake `/v1/speakers/voices`: URLProtocol answers each request from a closure and records what was sent.
private final class VoicesFake: URLProtocol, @unchecked Sendable {
    struct Seen { var method: String; var path: String; var auth: String?; var body: [String: Any]? }
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String))?
    nonisolated(unsafe) static var seen: [Seen] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            body = data
        }
        VoicesFake.seen.append(Seen(method: request.httpMethod ?? "GET", path: request.url?.path ?? "",
                                    auth: request.value(forHTTPHeaderField: "Authorization"),
                                    body: body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }))
        let (status, json) = VoicesFake.handler?(request) ?? (500, "{}")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func session(_ handler: @escaping (URLRequest) -> (Int, String)) -> URLSession {
        VoicesFake.handler = handler
        VoicesFake.seen = []
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [VoicesFake.self]
        return URLSession(configuration: c)
    }
}

@Suite(.serialized) struct SavedVoicesClientTests {
    private let config = ServerConfig(baseURL: URL(string: "http://mac.example:7821/chirp")!, token: "synthetic-token")
    private let library = #"""
    {"enabled":true,"model":"wespeaker-voxceleb-resnet34-LM@f0c48c29","voices":[
     {"id":"0123456789abcdef","name":"Maya","seconds":46.0,"created":"2026-10-12T09:00:00Z","updated":"2026-10-20T10:30:00Z","compatible":true},
     {"id":"fedcba9876543210","name":"Kim","seconds":31.5,"created":"2026-10-03T08:00:00Z","updated":"2026-10-03T08:00:00Z","compatible":false}]}
    """#

    @Test func listsTheLibraryWithTheToken() async throws {
        let session = VoicesFake.session { _ in (200, library) }
        let voices = try await config.savedVoices(session: session)
        #expect(voices.enabled && voices.model == "wespeaker-voxceleb-resnet34-LM@f0c48c29")
        #expect(voices.voices.map(\.name) == ["Maya", "Kim"] && voices.voices.map(\.compatible) == [true, false])
        #expect(voices.voices[0].updated == Date(timeIntervalSince1970: 1_792_492_200) && voices.voices[1].seconds == 31.5)
        let seen = try #require(VoicesFake.seen.first)
        #expect(seen.method == "GET" && seen.path == "/chirp/v1/speakers/voices" && seen.auth == "Bearer synthetic-token")
    }

    @Test func actionsSendTheWireFormat() async throws {
        let session = VoicesFake.session { _ in (200, library) }
        let note = VoiceSource.note(session: "note-0123456789abcdef", generation: "9f2c", speaker: 1)
        _ = try await config.savedVoices(.remember(name: "Maya", from: note), session: session)
        _ = try await config.savedVoices(.remember(name: "Maya", from: .audio(Data([1, 0, 2, 0])), voice: "0123456789abcdef"), session: session)
        _ = try await config.savedVoices(.rename(voice: "0123456789abcdef", name: "Maya B"), session: session)
        _ = try await config.savedVoices(.forget(voice: "0123456789abcdef"), session: session)
        _ = try await config.savedVoices(.forgetAll, session: session)
        _ = try await config.savedVoices(.enable, session: session)
        _ = try await config.savedVoices(.disable(forget: true), session: session)
        _ = try await config.savedVoices(.importVoice(name: "Maya", embedding: [1, -0.5], seconds: 31, model: "wespeaker_v2@df2625a"),
                                         session: session)
        let bodies = VoicesFake.seen.map { $0.body ?? [:] }
        #expect(VoicesFake.seen.allSatisfy { $0.method == "POST" && $0.path == "/chirp/v1/speakers/voices" })
        #expect(bodies[0]["action"] as? String == "remember" && bodies[0]["name"] as? String == "Maya" && bodies[0]["voice"] == nil)
        #expect(bodies[0]["from"] as? [String: AnyHashable] == ["session": "note-0123456789abcdef", "generation": "9f2c", "speaker": 1])
        #expect(bodies[1]["audio"] as? String == "AQACAA==" && bodies[1]["voice"] as? String == "0123456789abcdef" && bodies[1]["from"] == nil)
        #expect(bodies[2] as? [String: String] == ["action": "rename", "voice": "0123456789abcdef", "name": "Maya B"])
        #expect(bodies[3] as? [String: String] == ["action": "forget", "voice": "0123456789abcdef"])
        #expect(bodies[4] as? [String: String] == ["action": "forget_all"])
        #expect(bodies[5] as? [String: String] == ["action": "enable"])
        #expect(bodies[6]["action"] as? String == "disable" && bodies[6]["forget"] as? Bool == true)
        // Float32 little-endian: 1.0 is 00 00 80 3F, -0.5 is 00 00 00 BF.
        #expect(bodies[7]["action"] as? String == "import" && bodies[7]["embedding"] as? String == "AACAPwAAAL8="
                && bodies[7]["seconds"] as? Double == 31 && bodies[7]["model"] as? String == "wespeaker_v2@df2625a")
    }

    @Test func rememberReturnsTheSavedVoice() async throws {
        let saved = #"{"id":"0123456789abcdef","name":"Maya","seconds":21.0,"created":"2026-10-26T12:00:00Z","updated":"2026-10-26T12:00:00Z","compatible":true}"#
        let session = VoicesFake.session { _ in (200, #"{"enabled":true,"model":"m","voices":[\#(saved)],"voice":\#(saved)}"#) }
        let after = try await config.savedVoices(.remember(name: "Maya", from: .audio(Data(count: 4))), session: session)
        #expect(after.voice?.id == "0123456789abcdef" && after.voices.count == 1)
    }

    @Test func identifySendsOneClipPerPerson() async throws {
        let session = VoicesFake.session { _ in (200, #"{"matches":[{"person":3,"voice":"0123456789abcdef","name":"Maya"}]}"#) }
        let found = try await config.identifyVoices([VoiceClip(person: 3, pcm: Data([1, 0])), VoiceClip(person: 5, pcm: Data([2, 0]))], session: session)
        #expect(found == [IdentifiedVoice(person: 3, voice: "0123456789abcdef", name: "Maya")])
        let body = try #require(VoicesFake.seen.first?.body)
        #expect(body["action"] as? String == "identify")
        #expect(body["people"] as? [[String: AnyHashable]] == [["person": 3, "audio": "AQA="], ["person": 5, "audio": "AgA="]])
        // Nobody to identify: no request at all.
        VoicesFake.seen = []
        #expect(try await config.identifyVoices([], session: session).isEmpty && VoicesFake.seen.isEmpty)
    }

    @Test func refusalsAreTyped() async throws {
        let cases: [(Int, String, VoiceLibraryError)] = [
            (404, #"{"type":"error","code":"gone","message":"m"}"#, .gone),
            (404, #"{"type":"error","code":"no_voice","message":"m"}"#, .noVoice),
            (409, #"{"type":"error","code":"too_short","message":"m"}"#, .tooShort),
            (409, #"{"type":"error","code":"disabled","message":"m"}"#, .disabled),
            (409, #"{"type":"error","code":"full","message":"m"}"#, .full),
            (409, #"{"type":"error","code":"unavailable","message":"m"}"#, .unavailable),
            (413, #"{"type":"error","code":"clip_too_long","message":"m"}"#, .clipTooLong),
            (400, #"{"type":"error","code":"bad_speakers","message":"m"}"#, .badRequest),
            (401, #"{"type":"error","code":"auth","message":"m"}"#, .unauthorized),
            // An older server has no such route.
            (404, "Not Found", .unsupported),
            (405, "Method Not Allowed", .unsupported),
            (500, #"{"type":"error","code":"voices_file","message":"m"}"#, .server(500, "voices_file")),
        ]
        for (status, body, expected) in cases {
            let session = VoicesFake.session { _ in (status, body) }
            await #expect(throws: expected) { _ = try await config.savedVoices(.forgetAll, session: session) }
        }
    }
}
