import Foundation
import Testing
@testable import ChirpCore

@Suite struct ProtocolTests {
    @Test func decodesReady() throws {
        let m = try ServerMessage.decode(Data(#"{"type":"ready","session":"abc","engine":"parakeet","debug_retention":true}"#.utf8))
        #expect(m == .ready(session: "abc", engine: "parakeet", debugRetention: true))
    }

    @Test func decodesPartial() throws {
        let m = try ServerMessage.decode(Data(#"{"type":"partial","seq":3,"text":"hello wor","stable":"hello"}"#.utf8))
        #expect(m == .partial(seq: 3, text: "hello wor", stable: "hello"))
    }

    @Test func decodesFinalWithTimingsAndCorrection() throws {
        let json = #"{"type":"final","text":"Hello, world.","raw":"hello world","corrected":true,"correction_error":null,"timings_ms":{"audio":1200,"first_partial":180,"finalize":95,"correction":400}}"#
        guard case .final(let f) = try ServerMessage.decode(Data(json.utf8)) else { Issue.record("not final"); return }
        #expect(f.text == "Hello, world.")
        #expect(f.raw == "hello world")
        #expect(f.canUseRaw)
        #expect(f.timings?.firstPartial == 180)
        #expect(f.timings?.finalize == 95)
    }

    @Test func finalWithoutRawDefaultsToText() throws {
        guard case .final(let f) = try ServerMessage.decode(Data(#"{"type":"final","text":"hi"}"#.utf8)) else { Issue.record("not final"); return }
        #expect(f.raw == "hi")
        #expect(!f.corrected)
        #expect(!f.canUseRaw)
    }

    @Test func decodesErrorAndUnknown() throws {
        #expect(try ServerMessage.decode(Data(#"{"type":"error","code":"busy","message":"Busy"}"#.utf8)) == .error(code: "busy", message: "Busy"))
        #expect(try ServerMessage.decode(Data(#"{"type":"future_thing","x":1}"#.utf8)) == .unknown(type: "future_thing"))
    }

    @Test func startMessageMatchesSpec() throws {
        let s = ClientMessage.start(StartOptions(client: "mac", correction: true))
        let o = try #require(try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
        #expect(o["type"] as? String == "start")
        #expect(o["sample_rate"] as? Int == 16000)
        #expect(o["encoding"] as? String == "pcm_s16le")
        #expect(o["client"] as? String == "mac")
        #expect(o["correction"] as? Bool == true)
        #expect(ClientMessage.stop == #"{"type":"stop"}"#)
        #expect(ClientMessage.cancel == #"{"type":"cancel"}"#)
    }

    @Test func splitsPartialAtStablePrefix() {
        #expect(splitPartial(text: "hello wor", stable: "hello").unstable == " wor")
        #expect(splitPartial(text: "hello wor", stable: "hello").stable == "hello")
        // A stable string that is not a prefix of the text is ignored rather than trusted.
        #expect(splitPartial(text: "other", stable: "hello") == ("", "other"))
        #expect(splitPartial(text: "abc", stable: "") == ("", "abc"))
    }

    @Test func streamURLKeepsBasePathAndSwitchesScheme() {
        #expect(ServerConfig(baseURL: URL(string: "http://127.0.0.1:7821")!).streamURL.absoluteString == "ws://127.0.0.1:7821/v1/stream")
        #expect(ServerConfig(baseURL: URL(string: "https://mainframe.x.ts.net/chirp")!).streamURL.absoluteString == "wss://mainframe.x.ts.net/chirp/v1/stream")
        #expect(ServerConfig(baseURL: URL(string: "https://mainframe.x.ts.net/chirp/")!).healthURL.absoluteString == "https://mainframe.x.ts.net/chirp/v1/health")
    }

    @Test func readsTokenFromFileAndTrims() throws {
        let path = NSTemporaryDirectory() + "chirp-test-token-\(UUID().uuidString)"
        try "  secret-value\n".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(ServerConfig.readToken(path: path) == "secret-value")
        #expect(ServerConfig.readToken(path: path + ".missing") == nil)
        let r = ServerConfig(token: "t").authorized(URLRequest(url: URL(string: "http://x")!))
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer t")
    }
}
