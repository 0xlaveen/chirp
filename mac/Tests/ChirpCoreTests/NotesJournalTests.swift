import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

/// A fresh temporary journal folder per test (the folder itself is created by the store).
private func tempDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("chirp-journal-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("Recovery", isDirectory: true)
}

/// A document with everything the journal has to keep: emoji and CRLF text, a gap, a kept-original segment, speaker
/// turns with a renamed person, a tail the AI owns, fallback blocks and a dirty flag.
private func richDocument() -> NotesDocument {
    var d = NotesDocument(startedAt: Date(timeIntervalSince1970: 1_792_504_980))
    d.userEdit(NSRange(location: 0, length: 0), "My note 🎯\r\nsecond line é\r\n")
    d.append(NotesSegment(id: 0, offset: 0, raw: "we ship friday 🚀", text: "We ship Friday 🚀.", corrected: true))
    d.append(.gap(id: 1, offset: 30, reason: "busy"))
    d.append(NotesSegment(id: 2, offset: 60, raw: "maya sends the spec", text: "maya sends the spec", keptOriginal: true))
    d.attachSpeakers([SpeakerAttribution.Turn(slot: 3, start: 60, text: "maya sends the spec", approximate: true)], toSegment: 2)
    d.renameSpeaker(1, to: "Maya")
    if let r = d.nextStructureRequest() { d.apply(NotesStructureResponse(markdown: "## Plan\r\n- Ship Friday 🚀", structured: true), for: r) }
    d.freezeOverflow()
    return d
}

@MainActor
@Suite(.serialized) struct NotesJournalTests {
    // MARK: Codable

    @Test func theDocumentRoundTripsThroughJSON() throws {
        var d = richDocument()
        d.livePartial = ""   // display only: not stored
        let data = try JSONEncoder().encode(d)
        let back = try JSONDecoder().decode(NotesDocument.self, from: data)
        #expect(back == d)
        #expect(back.id == d.id && back.tailStart == d.tailStart && back.isDirty && back.text == d.text)
        #expect(back.segments[1].isGap && back.segments[2].keptOriginal && back.segments[2].turns?.first?.approximate == true)
        #expect(back.roster.displayName(1) == "Maya" && back.text.contains("\r\n"))
    }

    @Test func theLivePartialIsNotStored() throws {
        var d = richDocument()
        d.livePartial = "words that were never committed"
        let json = String(decoding: try JSONEncoder().encode(d), as: UTF8.self)
        #expect(!json.contains("never committed"))
        #expect(try JSONDecoder().decode(NotesDocument.self, from: Data(json.utf8)).livePartial.isEmpty)
    }

    // MARK: the store

    @Test func theFolderAndFileAreOwnerOnlyAndNoTempFileIsLeft() throws {
        let dir = tempDirectory()
        let store = NotesJournalStore(directory: dir)
        let record = NotesJournalRecord(document: richDocument(), elapsed: 3120)
        let bytes = try store.write(record)
        #expect(bytes > 0)
        func mode(_ url: URL) throws -> Int { (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1 }
        #expect(try mode(dir) == 0o700)
        #expect(try mode(store.file(record.document.id)) == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["\(record.document.id.uuidString).json"])
        #expect(store.recoverable().map(\.document) == [record.document])
    }

    @Test func aTornTempFileNeverShadowsTheGoodOne() throws {
        let dir = tempDirectory()
        let store = NotesJournalStore(directory: dir)
        let good = NotesJournalRecord(document: richDocument(), elapsed: 60)
        try store.write(good)
        // A crash in the middle of the next write: half a JSON in the temp file, the rename never happened.
        let temp = dir.appendingPathComponent("\(good.document.id.uuidString).json.tmp")
        try Data("{\"schema\":1,\"document\":{\"text\":\"half".utf8).write(to: temp)
        let found = store.recoverable()
        #expect(found.count == 1 && found[0].document == good.document)
        #expect(!FileManager.default.fileExists(atPath: temp.path))
    }

    @Test func aNewerSchemaIsIgnoredAndKeptOnDisk() throws {
        let dir = tempDirectory()
        let store = NotesJournalStore(directory: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let future = dir.appendingPathComponent("\(UUID().uuidString).json")
        try Data("{\"schema\":\(NotesJournalRecord.schema + 1),\"somethingNew\":true}".utf8).write(to: future)
        let garbage = dir.appendingPathComponent("\(UUID().uuidString).json")
        try Data("not json".utf8).write(to: garbage)
        #expect(store.recoverable().isEmpty)
        #expect(FileManager.default.fileExists(atPath: future.path) && FileManager.default.fileExists(atPath: garbage.path))
    }

    @Test func theNewestSessionComesFirst() throws {
        let store = NotesJournalStore(directory: tempDirectory())
        let old = NotesJournalRecord(document: NotesDocument(text: "old"), elapsed: 1, writtenAt: Date(timeIntervalSince1970: 100))
        let new = NotesJournalRecord(document: NotesDocument(text: "new"), elapsed: 1, writtenAt: Date(timeIntervalSince1970: 200))
        try store.write(old)
        try store.write(new)
        #expect(store.recoverable().map(\.document.text) == ["new", "old"])
    }

    // MARK: the writer on a fake clock

    private func make(_ dir: URL, clock: ManualClock, enabled: Bool = true) -> NotesJournal {
        NotesJournal(store: NotesJournalStore(directory: dir), enabled: enabled, sleep: { await clock.sleep($0) })
    }

    private func files(_ dir: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }

    /// Lets the debounce task reach its `sleep`.
    private func settleTimer() async { try? await Task.sleep(for: .milliseconds(30)) }

    @Test func editsAreWrittenAtMostEveryTwoSecondsAndRideAlong() async throws {
        let dir = tempDirectory(), clock = ManualClock()
        let journal = make(dir, clock: clock)
        var d = NotesDocument(startedAt: Date(timeIntervalSince1970: 0))
        journal.update(d, elapsed: 0)
        d.userEdit(NSRange(location: 0, length: 0), "a")
        journal.update(d, elapsed: 1)
        await settleTimer()
        clock.advance(1.9)
        await journal.settle()
        #expect(files(dir).isEmpty)
        d.userEdit(NSRange(location: 1, length: 0), "b")   // inside the window: no new timer, rides along
        journal.update(d, elapsed: 2)
        clock.advance(0.2)
        await settleTimer()
        await journal.settle()
        #expect(files(dir).count == 1)
        #expect(try #require(journal.store.recoverable().first).document.text == "ab")
        // The next change starts a new window.
        d.userEdit(NSRange(location: 2, length: 0), "c")
        journal.update(d, elapsed: 3)
        await settleTimer()
        clock.advance(1.9)
        await journal.settle()
        #expect(journal.store.recoverable().first?.document.text == "ab")
        clock.advance(0.2)
        await settleTimer()
        await journal.settle()
        #expect(journal.store.recoverable().first?.document.text == "abc")
    }

    @Test func aSegmentAnAppliedChangeAndStopAreWrittenAtOnce() async throws {
        let dir = tempDirectory(), clock = ManualClock()
        let journal = make(dir, clock: clock)
        var d = NotesDocument(startedAt: Date(timeIntervalSince1970: 0))
        d.append(NotesSegment(id: 0, offset: 0, raw: "we ship friday"))
        journal.update(d, elapsed: 5)
        await journal.settle()
        #expect(journal.store.recoverable().first?.document.segments.count == 1)
        #expect(journal.store.recoverable().first?.elapsed == 5)
        // An applied AI change (the controller passes urgent) and Stop (urgent too) do not wait for the timer.
        let r = try #require(d.nextStructureRequest())
        d.apply(NotesStructureResponse(markdown: "- Ship Friday", structured: true), for: r)
        journal.update(d, elapsed: 6, urgent: true)
        await journal.settle()
        #expect(journal.store.recoverable().first?.document.text == "- Ship Friday")
        d.freezeAll()
        journal.update(d, elapsed: 7, urgent: true)
        await journal.settle()
        #expect(journal.store.recoverable().first?.document == { var s = d; s.livePartial = ""; return s }())
    }

    @Test func theJournalIsDeletedOnSaveDiscardAndNew() async throws {
        let dir = tempDirectory(), clock = ManualClock()
        let journal = make(dir, clock: clock)
        var d = NotesDocument(startedAt: Date(timeIntervalSince1970: 0))
        d.append(NotesSegment(id: 0, offset: 0, raw: "one"))
        journal.update(d, elapsed: 1)
        await journal.settle()
        #expect(files(dir).count == 1)

        d.markSaved()   // Save…
        journal.update(d, elapsed: 1)
        await journal.settle()
        #expect(files(dir).isEmpty)

        d.userEdit(NSRange(location: 0, length: 0), "typed again")
        journal.update(d, elapsed: 1, urgent: true)
        await journal.settle()
        #expect(files(dir).count == 1)
        journal.discard()   // Discard in the quit alert
        await journal.settle()
        #expect(files(dir).isEmpty)

        d.userEdit(NSRange(location: 0, length: 0), "more")
        journal.update(d, elapsed: 1, urgent: true)
        await journal.settle()
        #expect(files(dir).count == 1)
        journal.update(NotesDocument(), elapsed: 0)   // New: another document replaces it
        await journal.settle()
        #expect(files(dir).isEmpty)
    }

    @Test func theSwitchOffDeletesTheCopyAndOnWritesItAgain() async throws {
        let dir = tempDirectory(), clock = ManualClock()
        let journal = make(dir, clock: clock)
        var d = NotesDocument(startedAt: Date(timeIntervalSince1970: 0))
        d.userEdit(NSRange(location: 0, length: 0), "meeting notes")
        journal.update(d, elapsed: 1, urgent: true)
        await journal.settle()
        #expect(files(dir).count == 1)
        journal.setEnabled(false)
        await journal.settle()
        #expect(files(dir).isEmpty)
        d.userEdit(NSRange(location: 0, length: 0), "x")
        journal.update(d, elapsed: 2, urgent: true)
        await journal.settle()
        #expect(files(dir).isEmpty)
        journal.setEnabled(true)
        await journal.settle()
        #expect(journal.store.recoverable().first?.document.text == "xmeeting notes")
    }

    @Test func aSavedDocumentWithNothingNewIsNotJournaled() async throws {
        let dir = tempDirectory(), clock = ManualClock()
        let journal = make(dir, clock: clock)
        journal.update(NotesDocument(), elapsed: 0)
        journal.update(NotesDocument(text: "loaded"), elapsed: 0, urgent: true)   // never edited, so never dirty
        await journal.settle()
        #expect(files(dir).isEmpty)
    }

    // MARK: recovery after a crash

    @Test func aCrashedSessionComesBackAsAStoppedDirtyDocument() async throws {
        let dir = tempDirectory(), clock = ManualClock()
        let original = richDocument()
        var last = original
        do {
            // The first run: notes and segments are journaled, then the process "dies" without a quit or a flush.
            let journal = make(dir, clock: clock)
            var d = original
            journal.update(d, elapsed: 3120, urgent: true)
            await journal.settle()
            d.userEdit(NSRange(location: 0, length: 0), "typed after the last write ")   // inside the debounce: lost
            journal.update(d, elapsed: 3125)
        }
        // The next launch, on the same folder.
        let relaunched = make(dir, clock: clock)
        let record = try #require(relaunched.store.recoverable().first)
        last.livePartial = ""
        #expect(record.document == last && record.elapsed == 3120 && record.document.isDirty)

        let recorder = NotesRecorder(makeSession: { _ in fatalError("no sockets in this test") }, structure: { _ in throw NotesStructureError.unsupported(404) },
                                     options: StartOptions(client: "mac"), structuring: false)
        relaunched.adopt(record)
        recorder.restore(record.document, elapsed: record.elapsed)
        #expect(recorder.state == .stopped && recorder.document.isDirty && recorder.document.text == last.text)
        #expect(recorder.elapsed == 3120)
        // The old diarizer slots mean nothing to the next one; the people (and the name) stay.
        #expect(recorder.document.roster.displayName(1) == "Maya" && recorder.document.roster.existingPerson(forSlot: 3) == nil)

        // Keeping it continues the same session file; the journal follows the restored document.
        relaunched.update(recorder.document, elapsed: recorder.elapsed, urgent: true)
        await relaunched.settle()
        #expect(files(dir) == ["\(record.document.id.uuidString).json"])
    }

    @Test func discardingARecoveredSessionRemovesItsFile() async throws {
        let dir = tempDirectory(), clock = ManualClock()
        let store = NotesJournalStore(directory: dir)
        try store.write(NotesJournalRecord(document: richDocument(), elapsed: 60))
        let relaunched = make(dir, clock: clock)
        let id = try #require(relaunched.store.recoverable().first?.document.id)
        relaunched.discard(id)
        await relaunched.settle()
        #expect(files(dir).isEmpty)
    }

    // MARK: keep a saved file up to date

    @Test func anEditAfterSaveRewritesTheFileWithinTheDebounceAndTheDocumentStaysSaved() async throws {
        let dir = tempDirectory(), clock = ManualClock()
        let journal = make(dir, clock: clock)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Chirp Notes \(UUID().uuidString).md")
        var d = NotesDocument(startedAt: Date(timeIntervalSince1970: 0))
        d.append(NotesSegment(id: 0, offset: 0, raw: "we ship friday"))
        try d.exportMarkdown().write(to: file, atomically: true, encoding: .utf8)
        d.markSaved()
        journal.update(d, elapsed: 1)
        journal.didSave(to: file, keep: true)
        #expect(journal.keepStatus == .saving(file: file.lastPathComponent))
        var marked = 0
        journal.onKeepSaved = { marked += 1; d.markSaved(); journal.update(d, elapsed: 2) }

        d.userEdit(NSRange(location: 0, length: 0), "- Ship Friday")
        journal.update(d, elapsed: 2)
        await settleTimer()
        clock.advance(1.9)
        #expect(!(try String(contentsOf: file, encoding: .utf8)).contains("Ship Friday"))
        clock.advance(0.2)
        await settleTimer()
        await journal.settle()
        #expect(try String(contentsOf: file, encoding: .utf8) == d.exportMarkdown())
        #expect(marked == 1 && !d.isDirty && files(dir).isEmpty)
        try? FileManager.default.removeItem(at: file)
    }

    @Test func aMovedOrDeletedFileStopsTheWritesAndTheJournalTakesOver() async throws {
        let dir = tempDirectory(), clock = ManualClock()
        let journal = make(dir, clock: clock)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Chirp Notes \(UUID().uuidString).md")
        var d = NotesDocument(startedAt: Date(timeIntervalSince1970: 0))
        d.userEdit(NSRange(location: 0, length: 0), "first")
        try d.exportMarkdown().write(to: file, atomically: true, encoding: .utf8)
        d.markSaved()
        journal.update(d, elapsed: 1)
        journal.didSave(to: file, keep: true)
        var changes = 0
        journal.onKeepChange = { changes += 1 }

        try FileManager.default.moveItem(at: file, to: file.appendingPathExtension("moved"))
        d.userEdit(NSRange(location: 5, length: 0), " second")
        journal.update(d, elapsed: 2, urgent: true)
        await journal.settle()
        #expect(journal.keepStatus == .stopped("Stopped saving — file moved") && journal.keepStatus.text == "Stopped saving — file moved")
        #expect(changes == 1 && !FileManager.default.fileExists(atPath: file.path))
        // The unsaved notes are still protected by the recovery copy.
        #expect(journal.store.recoverable().first?.document.text == "first second")
        try? FileManager.default.removeItem(at: file.appendingPathExtension("moved"))
    }

    @Test func aRecoveredSessionResumesKeepingItsFileOnlyIfItIsStillThere() async throws {
        let dir = tempDirectory(), clock = ManualClock()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Chirp Notes \(UUID().uuidString).md")
        try Data("x".utf8).write(to: file)
        let record = NotesJournalRecord(document: richDocument(), elapsed: 9, savedFile: file, keepSaving: true)
        let there = make(dir, clock: clock)
        there.adopt(record)
        #expect(there.keepStatus == .saving(file: file.lastPathComponent))
        try FileManager.default.removeItem(at: file)
        let gone = make(dir, clock: clock)
        gone.adopt(record)
        #expect(gone.keepStatus == .stopped(KeepSavingStatus.moved))
    }

    // MARK: the switch

    @Test func theRecoveryCopyIsOnByDefaultAndTheFooterSaysWhereItLives() throws {
        let defaults = try #require(UserDefaults(suiteName: "chirp-journal-\(UUID().uuidString)"))
        let prefs = Preferences(defaults: defaults)
        #expect(prefs.notesRecoveryCopy)
        prefs.notesRecoveryCopy = false
        #expect(!prefs.notesRecoveryCopy)
        #expect(NotesStatus.privacyRecovery.contains("Application Support/Chirp/Recovery"))
        #expect(NotesStatus.privacyRecoveryHelp.contains("never audio") && NotesStatus.recoveryHelp.contains("never audio"))
        #expect(NotesJournalStore.defaultDirectory.path.hasSuffix("Library/Application Support/Chirp/Recovery"))
    }

    // MARK: wording

    @Test func theBannerNamesTheStartTimeAndLength() {
        let utc = TimeZone(identifier: "UTC")!
        let at = Date(timeIntervalSince1970: 1_792_504_980)   // 2026-10-20 14:03 UTC
        #expect(NotesStatus.recovered(startedAt: at, elapsed: 52 * 60 + 20, timeZone: utc) == "Recovered unsaved notes from 14:03 (52 min)")
        #expect(NotesStatus.recovered(startedAt: at, elapsed: 20, timeZone: utc).hasSuffix("(under 1 min)"))
        #expect(NotesStatus.recovered(startedAt: at, elapsed: 3600 + 5 * 60, timeZone: utc).hasSuffix("(1 h 05 min)"))
    }
}
