import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

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

    @Test func overflowFreezesTheStructuredPartAndRetriesTheRest() throws {
        // A pass covered 1550 chars (under freezeChars); a long segment pushes the window past maxWindowChars.
        var d = doc([String(repeating: "a", count: 1550)])
        let r = try #require(d.nextStructureRequest())
        d.apply(ok("- a"), for: r)
        #expect(d.frozen.isEmpty)
        d.append(NotesSegment(id: 1, offset: 30, raw: String(repeating: "b", count: 2100)))
        d.freezeOverflow()
        // Only the structured part freezes; the new text gets a pass instead of a fallback.
        #expect(d.frozen == [NotesBlock(markdown: "- a", segmentRange: 0...0)])
        #expect(d.nextStructureRequest()?.transcript == String(repeating: "b", count: 2100))
    }

    @Test func aRequestNeverExceedsTheWindowCap() {
        var d = doc([String(repeating: "a", count: 2000), String(repeating: "b", count: 2000)])
        #expect(d.windowChars() > NotesDocument.maxWindowChars)
        #expect(d.nextStructureRequest() == nil)
        d.freezeOverflow()
        #expect(d.frozen.count == 1 && d.frozen[0].isFallback && d.nextStructureRequest() == nil)
        d.append(NotesSegment(id: 2, offset: 60, raw: "c"))
        #expect(d.nextStructureRequest()?.transcript == "c")
    }

    @Test func startIsStampedOnlyWhileEmpty() {
        var d = NotesDocument(startedAt: Date(timeIntervalSince1970: 0))
        d.stampStart(Date(timeIntervalSince1970: 100))
        #expect(d.startedAt == Date(timeIntervalSince1970: 100))
        d.append(NotesSegment(id: 0, offset: 0, raw: "x"))
        d.stampStart(Date(timeIntervalSince1970: 200))
        #expect(d.startedAt == Date(timeIntervalSince1970: 100))
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
                == "# Notes — 1970-01-01 00:00\n\n## Transcript\n\n**[00:00:00]** hello\n")
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

@Suite struct NotesPreferencesTests {
    @Test func anOptInAppliesOnlyWhereItWasMade() {
        let name = "chirp-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = Preferences(defaults: defaults)
        let local = Health(correction: "available", correctionLeavesMachine: false)
        let remoteA = Health(correction: "available", correctionLeavesMachine: true, correctionHost: "a.example.com")
        let remoteB = Health(correction: "available", correctionLeavesMachine: true, correctionHost: "b.example.com")
        // On for this Mac never carries over to an endpoint on another host.
        prefs.setNotesStructure(true, health: local)
        #expect(prefs.notesStructureEnabled(health: local) && !prefs.notesStructureEnabled(health: remoteA))
        // Opting in for host A applies to A only; this Mac falls back to its default (on).
        prefs.setNotesStructure(true, health: remoteA)
        #expect(prefs.notesStructureEnabled(health: remoteA) && !prefs.notesStructureEnabled(health: remoteB))
        #expect(prefs.notesStructureEnabled(health: local))
        // Off for this Mac stays off here.
        prefs.setNotesStructure(false, health: local)
        #expect(!prefs.notesStructureEnabled(health: local) && !prefs.notesStructureEnabled(health: remoteA))
        // A flip while health is unknown is not recorded.
        prefs.setNotesStructure(true, health: nil)
        #expect(!prefs.notesStructureEnabled(health: local))
    }

    @Test func structureDefaultFollowsTheServerUntilTheUserChooses() {
        let name = "chirp-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = Preferences(defaults: defaults)
        let local = Health(correction: "available", correctionLeavesMachine: false)
        let remote = Health(correction: "available", correctionLeavesMachine: true, correctionHost: "llm.example.com")
        #expect(prefs.notesStructureEnabled(health: local))
        // Unknown health never enables structuring: nothing says where the text would go.
        #expect(!prefs.notesStructureEnabled(health: nil))
        prefs.notesStructure = true                                  // a choice saved before scoping: local only
        #expect(!prefs.notesStructureEnabled(health: nil))
        #expect(!prefs.notesStructureEnabled(health: remote))
        #expect(!prefs.notesStructureEnabled(health: Health(correction: "available", correctionLeavesMachine: true)))
        #expect(prefs.notesTab == "notes")
        prefs.notesTab = "split"
        #expect(Preferences(defaults: defaults).notesTab == "split")
    }

    @Test func segmentsUseTheDefaultStyleAndTheEditedDefaultPrompt() {
        let name = "chirp-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = Preferences(defaults: defaults)
        prefs.correction = true
        prefs.correctionProfile = "email"
        prefs.wordWaveform = true
        prefs.correctionPrompts = ["default": "Keep it tidy.", "email": "Formal."]
        let o = prefs.notesStartOptions(health: Health(correction: "available"))
        #expect(o == StartOptions(client: "mac", correction: true, correctionProfile: "default", correctionPrompt: "Keep it tidy.", wordTimings: false))
        #expect(!prefs.notesStartOptions(health: Health(correction: "off")).correction)
        #expect(!prefs.notesStartOptions(health: nil).correction)
    }
}

@MainActor
@Suite struct NotesModelTests {
    private func model(_ configure: (NotesModel) -> Void = { _ in }) -> NotesModel {
        let m = NotesModel()
        var d = NotesDocument(startedAt: Date(timeIntervalSince1970: 0))
        d.append(NotesSegment(id: 0, offset: 5, raw: "we ship friday"))
        if let r = d.nextStructureRequest() { d.apply(NotesStructureResponse(markdown: "- Ship Friday", structured: true), for: r) }
        m.document = d
        configure(m)
        return m
    }

    @Test func statusFollowsTheRecorder() {
        #expect(model { $0.state = .starting }.statusText == NotesStatus.connecting)
        #expect(model { $0.state = .recording }.statusText == NotesStatus.listening)
        #expect(model { $0.state = .recording; $0.structuring = .running }.statusText == NotesStatus.updating)
        #expect(model { $0.state = .stopping }.statusText == NotesStatus.finishing)
        #expect(model { $0.state = .stopped }.statusText == NotesStatus.stopped)
        let failed = model { $0.state = .error("Notes stopped: Server is busy") }
        #expect(failed.statusText == "Notes stopped: Server is busy" && failed.isError)
    }

    @Test func controlsFollowTheStateTable() {
        let empty = NotesModel()
        #expect(empty.canToggle && !empty.canExport && !empty.canNew)
        let recording = model { $0.state = .recording }
        #expect(recording.isRecording && recording.canExport && !recording.canNew)
        let stopping = model { $0.state = .stopping }
        #expect(!stopping.canToggle && !stopping.canExport && !stopping.canNew)
        let stopped = model { $0.state = .stopped }
        #expect(stopped.canToggle && stopped.canExport && stopped.canNew)
    }

    @Test func aStartErrorNeverHidesARunningRecorder() {
        #expect(NotesModel.displayState(recorder: .idle, startError: "No microphone input device") == .error("No microphone input device"))
        #expect(NotesModel.displayState(recorder: .stopped, startError: "x") == .error("x"))
        for running in [NotesRecorderState.starting, .recording, .stopping] {
            #expect(NotesModel.displayState(recorder: running, startError: "x") == running)
            #expect(!NotesModel.acceptsStartError(running))
        }
        #expect(NotesModel.displayState(recorder: .stopping, startError: nil) == .stopping)
        #expect(model { $0.structuring = .off(.waiting) }.explanation?.hasPrefix("Waiting for the server") == true)
        #expect(!model { $0.structuring = .off(.waiting) }.structuringAvailable)
    }

    @Test func elapsedReadsAsMinutesThenHours() {
        #expect(model { $0.elapsed = 65 }.elapsedText == "01:05")
        #expect(model { $0.elapsed = 3725 }.elapsedText == "1:02:05")
    }

    @Test func copyIsTheNotesOrTheTranscriptByTab() {
        let notes = model()
        #expect(notes.copyText.contains("- Ship Friday") && !notes.copyText.contains("## Transcript"))
        let transcript = model { $0.tab = .transcript }
        #expect(transcript.copyText.contains("## Transcript") && !transcript.copyText.contains("- Ship Friday"))
        let off = model { $0.structuring = .off(.correctionOff) }
        #expect(off.copyText.contains("## Transcript") && !off.copyText.contains("- Ship Friday"))
        #expect(model().saveText.contains("- Ship Friday") && model().saveText.contains("## Transcript"))
        #expect(!model { $0.structuring = .off(.unsupported) }.saveText.contains("- Ship Friday"))
    }

    @Test func explanationsAndRetryNote() {
        #expect(model().explanation == nil && model().retryNote == nil)
        #expect(model { $0.structuring = .off(.disabled) }.explanation?.hasPrefix("Structuring is off") == true)
        let local = model { $0.structuring = .off(.correctionOff); $0.canManageModels = true }
        #expect(local.explanation?.contains("Models on this Mac") == true && local.offersModels)
        let remote = model { $0.structuring = .off(.correctionOff) }
        #expect(remote.explanation != nil && !remote.offersModels)
        #expect(model { $0.structuring = .off(.unsupported) }.explanation?.contains("newer Chirp server") == true)
        #expect(model { $0.structuring = .failed("timeout") }.retryNote == "Couldn’t update notes (timeout) — will retry")
    }

    @Test func tailShowsUnstructuredTextThenThePartial() {
        let m = model()
        m.document.append(NotesSegment(id: 1, offset: 30, raw: "budget talk"))
        m.document.livePartial = "and then"
        #expect(m.liveTail == "budget talk and then")
        m.structuring = .off(.disabled)
        #expect(m.liveTail == "and then")
    }
}

/// Opt-in check against a real server: `CHIRP_LIVE_NOTES_URL=http://127.0.0.1:7899 CHIRP_LIVE_NOTES_TOKEN_FILE=…
/// ./scripts/test.sh --filter NotesLiveServer`. Skipped otherwise, so CI and the normal run never need a server.
@Suite struct NotesLiveServerTests {
    static let url = ProcessInfo.processInfo.environment["CHIRP_LIVE_NOTES_URL"]

    @Test(.enabled(if: url != nil)) func structuresASampleThroughTheRealEndpoint() async throws {
        let env = ProcessInfo.processInfo.environment
        let config = ServerConfig.load(urlString: Self.url, tokenPath: env["CHIRP_LIVE_NOTES_TOKEN_FILE"] ?? ServerConfig.defaultTokenPath)
        let health = try await config.fetchHealth()
        #expect(health.notesStructure == true)
        let transcript = """
            Okay so the kickoff for the Lantern project. We decided to keep the vendor contract.
            Maya will send the draft spec by Friday. We will not add new headcount this quarter.
            """
        let r = try await config.structureNotes(NotesStructureRequest(transcript: transcript, outline: ["Intro"], final: true))
        if health.correction == "off" {
            Issue.record("server has correction off; expected 409 before this point")
            return
        }
        #expect(r.structured, "structured:false error=\(r.error ?? "nil")")
        let blocks = NotesMarkdown.blocks(r.markdown ?? "")
        #expect(blocks.contains { if case .bullet = $0 { true } else { false } })
        // Prints the timings only, never the notes, like the app's logs.
        print("live notes: structured=\(r.structured) blocks=\(blocks.count) timings=\(r.timingsMs ?? [:])")
    }
}
