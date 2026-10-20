import Foundation
import Testing
@testable import ChirpCore

private let speech = Level(peak: 0.5, rms: 0.2)
private let quiet = Level(peak: 0.01, rms: 0.005)
private let frame = 0.05

@Suite struct NotesSegmenterTests {
    /// Feeds `seconds` of `level` and returns the time of the first cut, if any.
    private func run(_ s: inout NotesSegmenter, _ level: Level, for seconds: Double) -> Double? {
        for _ in 0..<Int((seconds / frame).rounded()) where s.feed(level, duration: frame) { return s.elapsed }
        return nil
    }

    @Test func neverCutsBeforeTwentySecondsEvenWithPauses() {
        var s = NotesSegmenter()
        for _ in 0..<9 {
            #expect(run(&s, speech, for: 1) == nil)
            #expect(run(&s, quiet, for: 1) == nil)
        }
        #expect(s.elapsed < NotesSegmenter.minSegment)
    }

    @Test func cutsAtAPauseOfPointSixAfterTwentySeconds() {
        var s = NotesSegmenter()
        #expect(run(&s, speech, for: 25) == nil)
        #expect(run(&s, quiet, for: 0.5) == nil)
        let cut = run(&s, quiet, for: 0.5)
        #expect(cut != nil && abs(cut! - 25.6) < 0.01)
    }

    @Test func aShortPauseIsEnoughAfterSixtySeconds() {
        var s = NotesSegmenter()
        #expect(run(&s, speech, for: 30) == nil)
        #expect(run(&s, quiet, for: 0.35) == nil)   // 0.35 s does not cut at 30 s
        #expect(run(&s, speech, for: 30) == nil)
        let cut = run(&s, quiet, for: 1)
        #expect(cut != nil && abs(cut! - 60.65) < 0.01)
    }

    @Test func forcedCutAtExactlyNinetySecondsOfSpeech() {
        var s = NotesSegmenter()
        let cut = run(&s, speech, for: 100)
        #expect(cut != nil && abs(cut! - NotesSegmenter.maxSegment) < 0.001)
    }

    @Test func resetStartsANewSegment() {
        var s = NotesSegmenter()
        _ = run(&s, speech, for: 90)
        s.reset()
        #expect(s.elapsed == 0 && s.quiet == 0)
        #expect(run(&s, quiet, for: 10) == nil)
    }
}

@Suite struct NotesMarkdownTests {
    @Test func parsesTheSubset() {
        let md = "## Kickoff\n### Detail\n- Ship **Friday**\n  - nested\n- [ ] Maya sends the spec\n_(nothing yet)_\nplain words"
        #expect(NotesMarkdown.blocks(md) == [
            .heading(level: 2, text: "Kickoff"), .heading(level: 3, text: "Detail"),
            .bullet(indent: 0, text: "Ship **Friday**", task: false), .bullet(indent: 1, text: "nested", task: false),
            .bullet(indent: 0, text: "Maya sends the spec", task: true), .placeholder, .paragraph("plain words"),
        ])
    }

    @Test func unknownLinesAndH1BecomeParagraphs() {
        #expect(NotesMarkdown.blocks("# Title") == [.paragraph("# Title")])
        #expect(NotesMarkdown.blocks("#### deep") == [.paragraph("#### deep")])
        #expect(NotesMarkdown.blocks("| a | b |") == [.paragraph("| a | b |")])
        #expect(NotesMarkdown.blocks("<b>html</b>") == [.paragraph("<b>html</b>")])
        #expect(NotesMarkdown.blocks("- ") == [.paragraph("-")])
        #expect(NotesMarkdown.blocks("## ") == [.paragraph("##")])
    }

    @Test func emptyInputAndCRLF() {
        #expect(NotesMarkdown.blocks("").isEmpty)
        #expect(NotesMarkdown.blocks("\n\n  \n").isEmpty)
        #expect(NotesMarkdown.blocks("## A\r\n- b\r\n") == [.heading(level: 2, text: "A"), .bullet(indent: 0, text: "b", task: false)])
    }

    @Test func inlineStylingDropsLinksAndSurvivesBadInput() {
        let bold = NotesMarkdown.inline("Ship **Friday**")
        #expect(String(bold.characters) == "Ship Friday")
        let link = NotesMarkdown.inline("see [site](https://example.com)")
        #expect(link.runs.allSatisfy { $0.link == nil })
        #expect(String(NotesMarkdown.inline("**unclosed").characters).contains("unclosed"))
    }
}

@Suite struct NotesDocumentTests {
    private func doc(_ texts: [String]) -> NotesDocument {
        var d = NotesDocument(startedAt: Date(timeIntervalSince1970: 0))
        for (i, t) in texts.enumerated() { d.append(NotesSegment(id: i, offset: Double(i) * 30, raw: t)) }
        return d
    }
    private func ok(_ md: String) -> NotesStructureResponse { NotesStructureResponse(markdown: md, structured: true) }
    private let fail = NotesStructureResponse.failed("timeout")
    private let utc = TimeZone(identifier: "UTC")!

    @Test func nextRequestIsNilWithoutNewText() throws {
        var d = doc([])
        #expect(d.nextStructureRequest() == nil)
        d.append(.gap(id: 0, offset: 0, reason: "busy"))
        #expect(d.nextStructureRequest() == nil)
        d.append(NotesSegment(id: 1, offset: 30, raw: "we ship friday"))
        d.append(NotesSegment(id: 2, offset: 60, raw: "maya sends the spec"))
        let r = try #require(d.nextStructureRequest())
        #expect(r.transcript == "we ship friday\nmaya sends the spec" && r.windowEnd == 2 && !r.final)
        d.apply(ok("- Ship Friday"), for: r)
        #expect(d.openBlock == "- Ship Friday")
        #expect(d.nextStructureRequest() == nil)
        d.append(NotesSegment(id: 3, offset: 90, raw: "more"))
        #expect(d.nextStructureRequest(final: true)?.transcript == "we ship friday\nmaya sends the spec\nmore")
        #expect(d.nextStructureRequest(final: true)?.final == true)
    }

    @Test func outlineIsCappedByCountAndLength() throws {
        var d = doc([])
        for i in 0..<30 {
            d.append(NotesSegment(id: i, offset: 0, raw: String(repeating: "x", count: NotesDocument.freezeChars)))
            let r = try #require(d.nextStructureRequest())
            d.apply(ok("## Topic \(i) " + String(repeating: "y", count: 150) + "\n- point"), for: r)
        }
        #expect(d.frozen.count == 30)
        let outline = d.outline
        #expect(outline.count <= NotesDocument.maxOutlineItems)
        #expect(outline.allSatisfy { $0.count <= NotesDocument.maxOutlineItemChars })
        #expect(outline.reduce(0) { $0 + $1.count } <= NotesDocument.maxOutlineChars)
        #expect(outline.last?.hasPrefix("Topic 29") == true)
    }

    @Test func freezesAtFreezeChars() throws {
        var d = doc([String(repeating: "a", count: 1000)])
        var r = try #require(d.nextStructureRequest())
        d.apply(ok("## A\n- one"), for: r)
        #expect(d.frozen.isEmpty && d.openBlock != nil)
        d.append(NotesSegment(id: 1, offset: 30, raw: String(repeating: "b", count: 1500)))
        r = try #require(d.nextStructureRequest())
        d.apply(ok("## A\n- one\n- two"), for: r)
        #expect(d.frozen == [NotesBlock(markdown: "## A\n- one\n- two", segmentRange: 0...1)])
        #expect(d.openBlock == nil && d.windowStart == 2 && d.headings == ["A"])
        #expect(d.nextStructureRequest() == nil)
    }

    @Test func fallbackFreezeAfterTwoFailures() throws {
        var d = doc([String(repeating: "a", count: 2500)])
        var r = try #require(d.nextStructureRequest())
        d.apply(fail, for: r)
        #expect(d.frozen.isEmpty && d.consecutiveFailures == 1)
        r = try #require(d.nextStructureRequest())
        d.apply(fail, for: r)
        #expect(d.frozen.count == 1 && d.frozen[0].isFallback)
        #expect(d.frozen[0].markdown.hasPrefix(NotesDocument.fallbackHeader))
        #expect(d.windowStart == 1 && d.nextStructureRequest() == nil)
    }

    @Test func fallbackAtMaxWindowCharsKeepsTheStructuredPart() throws {
        var d = doc([String(repeating: "a", count: 1000)])
        let r = try #require(d.nextStructureRequest())
        d.apply(ok("- a"), for: r)
        d.append(NotesSegment(id: 1, offset: 30, raw: String(repeating: "b", count: 2500)))
        d.append(NotesSegment(id: 2, offset: 60, raw: String(repeating: "c", count: 2000)))
        d.freezeOverflow()
        #expect(d.frozen.map(\.isFallback) == [false, true])
        #expect(d.frozen[0].segmentRange == 0...0 && d.frozen[1].segmentRange == 1...2)
        // A window can never be sent over the limit.
        #expect(d.nextStructureRequest() == nil)
    }

    @Test func staleResponsesAreIgnored() throws {
        var d = doc([String(repeating: "a", count: 2500)])
        let old = try #require(d.nextStructureRequest())
        d.apply(ok("- a"), for: old)            // frozen: the window moved on
        d.append(NotesSegment(id: 1, offset: 30, raw: "b"))
        d.apply(ok("- stale"), for: old)
        #expect(d.openBlock == nil && d.frozen.count == 1)
    }

    @Test func freezeAllAtStop() throws {
        var d = doc(["one"])
        let r = try #require(d.nextStructureRequest())
        d.apply(ok("- one"), for: r)
        d.append(NotesSegment(id: 1, offset: 30, raw: "two"))
        d.freezeAll()
        #expect(d.frozen.map(\.isFallback) == [false, true] && d.openBlock == nil && d.windowStart == 2)
        var off = doc(["one"])
        off.freezeAll(structuring: false)
        #expect(off.frozen.isEmpty)
    }

    @Test func exportWithAndWithoutTranscript() throws {
        var d = doc(["we kick off", "budget talk"])
        let r = try #require(d.nextStructureRequest())
        d.apply(ok("## Kickoff\n- Launch **March 3**\n_(nothing yet)_"), for: r)
        d.freezeAll()
        #expect(d.exportMarkdown(includeTranscript: false, timeZone: utc) == "# Notes — 1970-01-01 00:00\n\n## Kickoff\n- Launch **March 3**\n")
        #expect(d.exportMarkdown(timeZone: utc) == """
            # Notes — 1970-01-01 00:00

            ## Kickoff
            - Launch **March 3**

            ---

            ## Transcript
            **[00:00:00]** we kick off
            **[00:00:30]** budget talk

            """)
        #expect(d.suggestedFileName(timeZone: utc) == "Chirp Notes 1970-01-01 0000.md")
    }

    @Test func transcriptOnlyWhenStructuringIsOff() {
        let d = doc(["hello"])
        #expect(d.exportMarkdown(includeTranscript: false, structuring: false, timeZone: utc)
                == "# Notes — 1970-01-01 00:00\n\n## Transcript\n**[00:00:00]** hello\n")
    }

    @Test func timestampsGapsAndKeptOriginal() {
        #expect(NotesDocument.timestamp(0) == "00:00:00")
        #expect(NotesDocument.timestamp(3725.9) == "01:02:05")
        var d = NotesDocument()
        d.append(NotesSegment(id: 0, offset: 12, raw: "um hello", text: "Hello.", corrected: true))
        d.append(.gap(id: 1, offset: 100, reason: "Server is busy"))
        d.append(NotesSegment(id: 2, offset: 190, raw: "raw words", keptOriginal: true))
        #expect(d.transcriptLines() == ["**[00:00:12]** Hello.", "**[00:01:40]** ⚠︎ audio not transcribed (Server is busy)",
                                        "**[00:03:10]** raw words _(kept original)_"])
        #expect(d.transcriptLines(raw: true).first == "**[00:00:12]** um hello")
    }

    @Test func dirtyTransitions() {
        var d = NotesDocument()
        #expect(!d.isDirty && d.isEmpty)
        d.append(.gap(id: 0, offset: 0, reason: "x"))
        #expect(!d.isDirty)
        d.append(NotesSegment(id: 1, offset: 0, raw: "text"))
        #expect(d.isDirty)
        _ = d.exportMarkdown()                    // what Copy does: the dirty flag stays
        #expect(d.isDirty)
        d.markSaved()
        #expect(!d.isDirty)
    }
}

/// Answers every request to the stubbed host with the scripted status and body.
final class NotesURLStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var lastBody: Data?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            Self.lastBody = data
        } else {
            Self.lastBody = request.httpBody
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static var session: URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [NotesURLStub.self]
        return URLSession(configuration: c)
    }
}

@Suite(.serialized) struct NotesProtocolTests {
    @Test func requestHasExactlyTheWireKeys() throws {
        let r = NotesStructureRequest(transcript: "hi", outline: ["A"], final: true, windowEnd: 7)
        let o = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as? [String: Any])
        #expect(Set(o.keys) == ["transcript", "outline", "final"])
        #expect(o["transcript"] as? String == "hi" && o["final"] as? Bool == true)
    }

    @Test func responsesDecode() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let good = try decoder.decode(NotesStructureResponse.self, from: Data(###"{"markdown":"## A\n- b","structured":true,"error":null,"timings_ms":{"structure":1234.5}}"###.utf8))
        #expect(good.structured && good.markdown == "## A\n- b" && good.timingsMs?.values.first == 1234.5)
        let bad = try decoder.decode(NotesStructureResponse.self, from: Data(#"{"markdown":null,"structured":false,"error":"rejected","timings_ms":{}}"#.utf8))
        #expect(!bad.structured && bad.markdown == nil && bad.error == "rejected")
        let lenient = try decoder.decode(NotesStructureResponse.self, from: Data(#"{"structured":true,"future":1}"#.utf8))
        #expect(!lenient.structured)
    }

    @Test func healthDecodesNotesStructure() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        #expect(try decoder.decode(Health.self, from: Data(#"{"ok":true,"notes_structure":true}"#.utf8)).notesStructure == true)
        #expect(try decoder.decode(Health.self, from: Data(#"{"ok":true}"#.utf8)).notesStructure == nil)
    }

    @Test func urlKeepsTheBasePath() {
        #expect(ServerConfig(baseURL: URL(string: "https://mainframe.x.ts.net/chirp")!).notesStructureURL.absoluteString
                == "https://mainframe.x.ts.net/chirp/v1/notes/structure")
        #expect(ServerConfig().notesStructureURL.absoluteString == "http://127.0.0.1:7821/v1/notes/structure")
    }

    @Test func structureNotesPostsAndDecodes() async throws {
        NotesURLStub.status = 200
        NotesURLStub.body = Data(#"{"markdown":"- a","structured":true,"error":null,"timings_ms":{"structure":5}}"#.utf8)
        let config = ServerConfig(token: "tok")
        let r = try await config.structureNotes(NotesStructureRequest(transcript: "a", windowEnd: 3), session: NotesURLStub.session)
        #expect(r.markdown == "- a")
        #expect(NotesURLStub.lastRequest?.httpMethod == "POST")
        #expect(NotesURLStub.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        let body = try #require(NotesURLStub.lastBody)
        let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(sent.keys) == ["transcript", "outline", "final"])
    }

    @Test(arguments: [(401, NotesStructureError.auth), (404, .unsupported(404)), (409, .off), (503, .busy), (500, .http(500))])
    func structureNotesMapsErrors(status: Int, expected: NotesStructureError) async {
        NotesURLStub.status = status
        NotesURLStub.body = Data(#"{"type":"error","code":"x","message":"y"}"#.utf8)
        do {
            _ = try await ServerConfig().structureNotes(NotesStructureRequest(transcript: "a"), session: NotesURLStub.session)
            Issue.record("expected an error")
        } catch let e as NotesStructureError {
            #expect(e == expected)
        } catch {
            Issue.record("wrong error \(error)")
        }
    }
}
