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

    @Test func deletingLegacyRecoveryPreservesTheSharedLibraryKey() throws {
        let root = try notesRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let secrets = MemorySecretStore()
        let store = try NotesStore(root: root, secrets: secrets)
        try store.journalStore.write(NotesJournalRecord(document: NotesDocument(text: "x"), elapsed: 1))
        try store.deleteRecovery()
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.recoveryDirectory.path).isEmpty)
        #expect(try secrets.read(account: NotesStore.keyAccount)?.count == 32)
        // The shared library key remains available for both stores.
        try store.journalStore.write(NotesJournalRecord(document: NotesDocument(text: "y"), elapsed: 1))
        #expect(store.journalStore.recoverable().count == 1)
    }

    @Test func sealedLibraryMigratesRecoveryOnceAndQuarantinesCorruption() async throws {
        let root = try notesRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let secrets = MemorySecretStore()
        let store = try NotesStore(root: root, secrets: secrets)
        var document = NotesDocument(text: "## Secret plan\n- [ ] Send invitation")
        document.append(NotesSegment(id: 0, offset: 4, raw: "private raw transcript"))
        let record = NotesJournalRecord(document: document, elapsed: 14)
        try store.journalStore.write(record)
        let corrupt = store.recoveryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try Data("invalid sealed record".utf8).write(to: corrupt)
        try await store.migrateRecovery()
        try await store.libraryStore.rename(document.id, title: "Chosen title")
        try store.journalStore.write(record)
        try await store.migrateRecovery()
        #expect(try await store.libraryStore.list().map(\.title) == ["Chosen title"])
        #expect(try await store.libraryStore.record(document.id).recovered == true)
        #expect(!FileManager.default.fileExists(atPath: corrupt.path))
        let quarantine = store.recoveryDirectory.appendingPathComponent("quarantine")
        #expect(try FileManager.default.contentsOfDirectory(atPath: quarantine.path).count == 1)
        for url in [store.libraryStore.directory.appendingPathComponent("index.json"), store.libraryStore.noteDirectory(document.id).appendingPathComponent("note.json")] {
            let data = try Data(contentsOf: url)
            #expect((try? JSONSerialization.jsonObject(with: data)) == nil)
            #expect(!String(decoding: data, as: UTF8.self).contains("Secret plan"))
            #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
            #if os(iOS)
            #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey] as? FileProtectionType == .complete)
            #endif
        }
        let relaunched = try NotesStore(root: root, secrets: secrets)
        #expect(try await relaunched.libraryStore.record(document.id).document.text == document.text)
        #expect(try await relaunched.libraryStore.search("private raw").count == 1)
        #expect(!String(describing: try await relaunched.libraryStore.record(document.id)).contains("Secret"))
    }

    @Test func upgradePreservesOptOutAndAudioIsOffByDefault() throws {
        let preferences = try JSONDecoder().decode(NotesPreferences.self, from: Data(#"{"recoveryCopy":false}"#.utf8))
        #expect(!preferences.keepNotes && preferences.libraryUpgradeNotice)
        #expect(!preferences.keepAudio && preferences.retention == .never)
        #expect(try JSONDecoder().decode(NotesPreferences.self, from: Data("{}".utf8)).keepNotes)
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
