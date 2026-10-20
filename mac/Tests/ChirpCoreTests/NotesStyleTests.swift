import Foundation
import Testing
@testable import ChirpCore

@Suite struct NotesStyleRunTests {
    private func runs(_ text: String) -> [NotesStyleRun] { NotesMarkdown.styleRuns(Substring(text)) }
    private func r(_ location: Int, _ length: Int, _ style: NotesStyleRun.Style) -> NotesStyleRun {
        NotesStyleRun(NSRange(location: location, length: length), style)
    }

    @Test func headingsAndTheirMarkers() {
        #expect(runs("# Title") == [r(0, 7, .heading(1)), r(0, 1, .markupDelimiter)])
        #expect(runs("## Budget") == [r(0, 9, .heading(2)), r(0, 2, .markupDelimiter)])
        #expect(runs("### Detail") == [r(0, 10, .heading(3)), r(0, 3, .markupDelimiter)])
        #expect(runs("#### deep").isEmpty && runs("##nospace").isEmpty)
    }

    @Test func boldItalicAndTheirDelimiters() {
        #expect(runs("a **b** c") == [r(2, 5, .bold), r(2, 2, .markupDelimiter), r(5, 2, .markupDelimiter)])
        #expect(runs("_it_ and *it*") == [r(0, 4, .italic), r(0, 1, .markupDelimiter), r(3, 1, .markupDelimiter),
                                          r(9, 4, .italic), r(9, 1, .markupDelimiter), r(12, 1, .markupDelimiter)])
        // Not emphasis: inside a word, around spaces, unclosed.
        #expect(runs("snake_case_name").isEmpty && runs("a * b * c").isEmpty && runs("**open").isEmpty)
        #expect(runs("2 * 3 = 6").isEmpty)
    }

    @Test func bulletsNestAndTasks() {
        #expect(runs("- one") == [r(0, 2, .bulletMarker(indent: 0))])
        #expect(runs("  - two") == [r(0, 4, .bulletMarker(indent: 1))])
        #expect(runs("      * deep") == [r(0, 8, .bulletMarker(indent: 2))])
        #expect(runs("- [ ] todo") == [r(0, 2, .bulletMarker(indent: 0)), r(2, 3, .taskBox(checked: false))])
        #expect(runs("- [x] done") == [r(0, 2, .bulletMarker(indent: 0)), r(2, 3, .taskBox(checked: true)), r(6, 4, .checkedTaskText)])
        #expect(runs("-no space").isEmpty)
    }

    @Test func decisionQuestionAndFallback() {
        let decision = runs("- **Decision:** keep it")
        #expect(decision.contains(r(4, 9, .decisionLabel)) && decision.contains(r(2, 13, .bold)))
        #expect(runs("- **Question:** who?").contains(r(4, 9, .questionLabel)))
        #expect(runs(NotesDocument.fallbackHeader).first == r(0, NotesDocument.fallbackHeader.utf16.count, .fallbackHeader))
        #expect(runs("plain words only").isEmpty)
    }

    @Test func offsetsAreUTF16AcrossLinesAndEmoji() {
        let text = "👋 hi\n## 日本 **x**\n- 🎉 [ ] no"
        let all = NotesMarkdown.styleRuns(Substring(text), base: 100)
        // "👋 hi\n" is 6 UTF-16 units; the heading line starts at 106.
        #expect(all.contains(r(106, 11, .heading(2))))
        #expect(all.contains(r(112, 5, .bold)))
        // The emoji is the item's text, so `[ ]` after it is not a box.
        #expect(all.contains(r(118, 2, .bulletMarker(indent: 0))) && !all.contains { if case .taskBox = $0.style { true } else { false } })
        let ns = text as NSString
        for run in all { #expect(NSMaxRange(run.range) - 100 <= ns.length) }
    }

    @Test func sectionsCoverEveryUnit() {
        let text = "intro\n\n## A\n- a\n\n## B\n- b\n### B1\nx"
        let sections = NotesMarkdown.sections(text)
        #expect(sections.map(\.heading) == [nil, "A", "B", "B1"])
        #expect(sections.map(\.range.location) == [0, 7, 17, 26])
        #expect(sections.reduce(0) { $0 + $1.range.length } == text.utf16.count)
        #expect(NotesMarkdown.sections("## Only").map(\.heading) == ["Only"])
        #expect(NotesMarkdown.sections("").isEmpty)
    }

    @Test func blocksReadH1AndCheckedTasks() {
        #expect(NotesMarkdown.blocks("# Title\n- [x] done\n    - deep") == [
            .heading(level: 1, text: "Title"), .bullet(indent: 0, text: "done", task: true, checked: true),
            .bullet(indent: 2, text: "deep", task: false, checked: false),
        ])
    }

    @Test func taskToggleFindsTheBox() throws {
        let text = "## A\n- [ ] one\n- [x] two\n- plain"
        let first = try #require(NotesMarkdown.taskToggle(text, at: 7))
        #expect(first.range == NSRange(location: 8, length: 1) && first.replacement == "x")
        #expect(NotesMarkdown.taskToggle(text, at: 18)?.replacement == " ")
        #expect(NotesMarkdown.taskToggle(text, at: 12) == nil)          // on the item's text
        #expect(NotesMarkdown.taskToggle(text, at: 27) == nil)          // a plain bullet
    }

    @Test func tenThousandCharsStyleQuickly() {
        let line = "- **Decision:** keep the _vendor_ contract and [ ] more words here\n## Heading\n"
        let text = String(repeating: line, count: 10_000 / line.count + 1)
        let clock = ContinuousClock()
        var count = 0
        let elapsed = clock.measure { count = NotesMarkdown.styleRuns(Substring(text)).count }
        #expect(count > 0)
        #expect(elapsed < .milliseconds(20), "styleRuns took \(elapsed)")
    }
}

/// In the serialized protocol suite: these share `NotesURLStub`.
extension NotesProtocolTests {
    @Test func reorganizeRequestHasExactlyTheWireKeys() throws {
        let r = NotesReorganizeRequest(notes: "## A\n- b", outline: ["Earlier"], final: true, version: 9, range: NSRange(location: 3, length: 4))
        let o = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as? [String: Any])
        #expect(Set(o.keys) == ["notes", "outline", "final"])
        #expect(o["notes"] as? String == "## A\n- b" && o["outline"] as? [String] == ["Earlier"] && o["final"] as? Bool == true)
        let s = NotesStructureRequest(transcript: "t", version: 3, windowGeneration: 2)
        let so = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any])
        #expect(Set(so.keys) == ["transcript", "outline", "final"])
    }

    @Test func reorganizeResponsesDecode() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let good = try decoder.decode(NotesReorganizeResponse.self, from: Data(###"{"markdown":"## A","reorganized":true,"changed":true,"error":null,"timings_ms":{"reorganize":1234.5}}"###.utf8))
        #expect(good.reorganized && good.changed && good.markdown == "## A" && good.timingsMs?["reorganize"] == 1234.5)
        let same = try decoder.decode(NotesReorganizeResponse.self, from: Data(###"{"markdown":"## A","reorganized":true,"changed":false}"###.utf8))
        #expect(same.reorganized && !same.changed)
        let bad = try decoder.decode(NotesReorganizeResponse.self, from: Data(#"{"markdown":null,"reorganized":false,"changed":false,"error":"rejected"}"#.utf8))
        #expect(!bad.reorganized && bad.error == "rejected")
        let lenient = try decoder.decode(NotesReorganizeResponse.self, from: Data(#"{"reorganized":true,"changed":true,"x":1}"#.utf8))
        #expect(!lenient.reorganized && !lenient.changed)
    }

    @Test func healthDecodesNotesReorganize() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        #expect(try decoder.decode(Health.self, from: Data(#"{"ok":true,"notes_reorganize":true}"#.utf8)).notesReorganize == true)
        #expect(try decoder.decode(Health.self, from: Data(#"{"ok":true,"notes_structure":true}"#.utf8)).notesReorganize == nil)
    }

    @Test func reorganizeURLKeepsTheBasePath() {
        #expect(ServerConfig(baseURL: URL(string: "https://mainframe.x.ts.net/chirp")!).notesReorganizeURL.absoluteString
                == "https://mainframe.x.ts.net/chirp/v1/notes/reorganize")
    }

    @Test func reorganizePostsAndDecodes() async throws {
        NotesURLStub.status = 200
        NotesURLStub.body = Data(###"{"markdown":"## A\n- b","reorganized":true,"changed":true,"error":null,"timings_ms":{}}"###.utf8)
        let r = try await ServerConfig(token: "tok").reorganizeNotes(NotesReorganizeRequest(notes: "## A\n- b", version: 4), session: NotesURLStub.session)
        #expect(r.markdown == "## A\n- b")
        #expect(NotesURLStub.lastRequest?.url?.path == "/v1/notes/reorganize" && NotesURLStub.lastRequest?.httpMethod == "POST")
        #expect(NotesURLStub.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(NotesURLStub.lastRequest?.timeoutInterval == 50)
        let body = try #require(NotesURLStub.lastBody)
        let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(sent.keys) == ["notes", "outline", "final"])
    }

    @Test(arguments: [(401, NotesStructureError.auth), (404, .unsupported(404)), (409, .off), (503, .busy), (500, .http(500))])
    func reorganizeMapsErrors(status: Int, expected: NotesStructureError) async {
        NotesURLStub.status = status
        NotesURLStub.body = Data(#"{"type":"error","code":"x","message":"y"}"#.utf8)
        do {
            _ = try await ServerConfig().reorganizeNotes(NotesReorganizeRequest(notes: "a"), session: NotesURLStub.session)
            Issue.record("expected an error")
        } catch let e as NotesStructureError {
            #expect(e == expected)
        } catch {
            Issue.record("wrong error \(error)")
        }
    }
}
