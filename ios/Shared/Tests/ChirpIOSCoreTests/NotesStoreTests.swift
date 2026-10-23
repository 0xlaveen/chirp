import ChirpCore
import Foundation
import Testing
@testable import ChirpIOSCore

private func notesRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-notes-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@MainActor
struct NotesStoreTests {
    @Test func theRecoveryJournalIsCiphertextAndOpensOnlyWithItsKey() throws {
        let root = try notesRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let secrets = MemorySecretStore()
        let store = try NotesStore(root: root, secrets: secrets)
        var document = NotesDocument(text: "## Launch\n- sentinel-plan ships friday")
        document.append(NotesSegment(id: 0, offset: 0, raw: "sentinel raw words", text: "Sentinel raw words."))
        let record = NotesJournalRecord(document: document, elapsed: 75)
        try store.journalStore.write(record)
        let files = try FileManager.default.contentsOfDirectory(atPath: store.recoveryDirectory.path)
        #expect(files == ["\(document.id.uuidString).json"])
        let bytes = try Data(contentsOf: store.recoveryDirectory.appendingPathComponent(files[0]))
        #expect(!String(decoding: bytes, as: UTF8.self).contains("sentinel"))
        #expect(try secrets.read(account: NotesStore.keyAccount)?.count == 32)
        let reopened = try NotesStore(root: root, secrets: secrets)
        #expect(reopened.journalStore.recoverable().map(\.document) == [document])
        #expect(reopened.journalStore.recoverable().first?.elapsed == 75)
        // Another device's key (or a lost one) cannot open it: nothing is offered and nothing crashes.
        #expect(try NotesStore(root: root, secrets: MemorySecretStore()).journalStore.recoverable().isEmpty)
        #expect(NotesJournalStore(directory: store.recoveryDirectory).recoverable().isEmpty)
    }

    @Test func turningRecoveryOffDeletesTheFilesAndTheKey() throws {
        let root = try notesRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let secrets = MemorySecretStore()
        let store = try NotesStore(root: root, secrets: secrets)
        try store.journalStore.write(NotesJournalRecord(document: NotesDocument(text: "x"), elapsed: 1))
        try store.deleteRecovery()
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.recoveryDirectory.path).isEmpty)
        #expect(try secrets.read(account: NotesStore.keyAccount) == nil)
        // A new copy after that gets a new key.
        try store.journalStore.write(NotesJournalRecord(document: NotesDocument(text: "y"), elapsed: 1))
        #expect(store.journalStore.recoverable().count == 1)
    }

    @Test func preferencesKeepDefaultsForMissingFieldsAndRoundTrip() throws {
        let decoded = try JSONDecoder().decode(NotesPreferences.self, from: Data(#"{"batterySaver":false}"#.utf8))
        #expect(decoded.structure == nil && decoded.autoReorganize && decoded.recoveryCopy && !decoded.batterySaver)
        let root = try notesRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root, secrets: MemorySecretStore())
        #expect(try store.loadPreferences() == NotesPreferences())
        var p = NotesPreferences(); p.structure = false; p.recoveryCopy = false
        try store.save(p)
        #expect(try store.loadPreferences() == p)
    }

    @Test func structuringFollowsTheDestinationAndConsent() {
        let local = Health(engine: "e", ready: true, correction: "available", correctionLeavesMachine: false, notesStructure: true)
        let remote = Health(engine: "e", ready: true, correction: "available", correctionLeavesMachine: true,
                            correctionHost: "api.example.test", notesStructure: true)
        var p = NotesPreferences()
        #expect(!p.structureEnabled(health: nil))
        #expect(p.structureEnabled(health: local))
        #expect(!p.structureEnabled(health: Health(engine: "e", ready: true, correction: "off")))
        #expect(!p.structureEnabled(health: remote))
        p.structure = true; p.structureConsentHost = "api.example.test"
        #expect(p.structureEnabled(health: remote))
        p.structureConsentHost = "other.example.test"
        #expect(!p.structureEnabled(health: remote))
        p.structure = false
        #expect(!p.structureEnabled(health: local))
    }

    @Test func anEditMovesOntoTextThatChangedElsewhereAndIsDroppedWhereItOverlaps() {
        // Typed at the start while an AI append landed at the end.
        let moved = NotesEditRebase.change(shown: "Intro\n- a", edited: "My intro\n- a", current: "Intro\n- a\n- b")
        #expect(moved.map { $0.applied(to: "Intro\n- a\n- b") } == "My intro\n- a\n- b")
        // Typed at the end while the AI rewrote the end.
        let tail = NotesEditRebase.change(shown: "Top\n- a", edited: "Top\n- a!", current: "Top\n- A\n- b")
        #expect(tail == nil)
        // Nothing changed in between: the plain diff.
        #expect(NotesEditRebase.change(shown: "abc", edited: "abXc", current: "abc")?.applied(to: "abc") == "abXc")
        #expect(NotesEditRebase.change(shown: "abc", edited: "abc", current: "abcd") == nil)
    }
}
