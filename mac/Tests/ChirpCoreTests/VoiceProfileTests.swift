import Foundation
import Security
import Testing
@testable import ChirpCore
@testable import ChirpUI

/// Issue #18 M3: opt-in voice profiles. Voiceprints, matching, the policy (consent, remember, update, forget), the
/// window's suggestions, and that no voiceprint ever reaches a file, a log, an export or a request.

private func unit(_ i: Int) -> [Float] { var v = [Float](repeating: 0, count: 256); v[i] = 1; return v }
/// A voice whose cosine to `unit(i)` is `cos` (the rest along `unit(j)`).
private func near(_ i: Int, _ j: Int, _ cos: Float) -> [Float] { var v = unit(i); v[i] = cos; v[j] = (1 - cos * cos).squareRoot(); return v }
private func heard(_ e: [Float], _ seconds: TimeInterval) -> Voiceprint { var p = Voiceprint(); p.add(e, seconds: seconds); return p }

final class FakeEmbedder: VoiceEmbedder, @unchecked Sendable {
    func embedding(_ samples: [Float]) throws -> [Float] { unit(0) }
}

/// A voice model with nothing behind it: records loads (true: a download) and can be missing.
final class FakeVoiceModelStore: VoiceModelStore, @unchecked Sendable {
    private let lock = NSLock()
    private var downloaded: Bool
    private var _loads: [Bool] = []
    init(downloaded: Bool) { self.downloaded = downloaded }
    var loads: [Bool] { lock.withLock { _loads } }
    var modelID: String { "fake@1" }
    var sizeText: String { "8 MB" }
    func isDownloaded() -> Bool { lock.withLock { downloaded } }
    func hasFiles() -> Bool { isDownloaded() }
    func remove() throws { lock.withLock { downloaded = false } }
    func setDownloaded(_ on: Bool) { lock.withLock { downloaded = on } }
    func load(download: Bool, progress: @escaping @Sendable (Double) -> Void) async throws -> any VoiceEmbedder {
        lock.withLock { _loads.append(download); if download { downloaded = true } }
        return FakeEmbedder()
    }
}

@Suite struct VoiceprintTests {
    @Test func aVoiceprintIsTheSpeechWeightedMean() {
        var p = heard(unit(0), 3)
        p.add(unit(1), seconds: 1)
        #expect(p.seconds == 4)
        #expect(abs(Voiceprint.cosine(p.centroid, unit(0)) - 3 / Float(10).squareRoot()) < 1e-5)
        var q = Voiceprint()
        q.add(p)
        q.add([Float](repeating: .nan, count: 256), seconds: 5)    // a broken embedding is ignored
        q.add(unit(0), seconds: 0)
        #expect(q == p)
        #expect(Voiceprint.cosine([1, 0], [1, 0, 0]) == -1)
    }

    @Test func matchingNeedsTheThresholdTheMarginEnoughSpeechAndTheSameModel() {
        let maya = VoiceProfile(name: "Maya", embedding: unit(0), model: "m", seconds: 30)
        let theo = VoiceProfile(name: "Theo", embedding: unit(1), model: "m", seconds: 30)
        let old = VoiceProfile(name: "Ana", embedding: unit(2), model: "old", seconds: 30)
        let voices: [Int: Voiceprint] = [
            1: heard(near(0, 9, 0.9), 12),                          // Maya
            2: heard(near(1, 9, 0.6), 40),                          // not alike enough
            3: heard(unit(0), 5),                                   // too little speech
            4: heard(Voiceprint(sum: unit(0).enumerated().map { $1 + ($0 == 1 ? 1 : 0) }).centroid, 20),  // between two: no margin
            5: heard(unit(2), 30),                                  // only an old-model profile
        ]
        #expect(VoiceMatch.suggest(voices, profiles: [maya, theo, old], model: "m") == [1: maya.id])
        // One profile, two candidates: the closer one gets it.
        let two: [Int: Voiceprint] = [1: heard(near(0, 9, 0.8), 12), 2: heard(near(0, 9, 0.95), 12)]
        #expect(VoiceMatch.suggest(two, profiles: [maya], model: "m") == [2: maya.id])
    }
}

@MainActor
@Suite struct SpeakerVoicesTests {
    final class Box { var preference: Bool?; var prompts: [SpeakerVoices.Prompt] = [] }

    private func voices(_ model: FakeVoiceModelStore, _ store: VoiceProfileStore = MemoryVoiceProfileStore(), enabled: Bool,
                        answer: Bool? = nil) -> (SpeakerVoices, Box) {
        let box = Box()
        let v = SpeakerVoices(modelStore: model, profileStore: store, enabled: enabled, onPreference: { box.preference = $0 })
        v.confirm = { prompt, done in box.prompts.append(prompt); if let answer { done(answer) } }
        return (v, box)
    }

    /// Person 1 = slot 4, person 2 = slot 7.
    private func document(name1: String? = nil, name2: String? = nil) -> NotesDocument {
        var d = NotesDocument()
        d.append(NotesSegment(id: 0, offset: 0, raw: "a b"))
        d.attachSpeakers([.init(slot: 4, start: 0, text: "a"), .init(slot: 7, start: 1, text: "b")], toSegment: 0)
        if let name1 { d.renameSpeaker(1, to: name1) }
        if let name2 { d.renameSpeaker(2, to: name2) }
        return d
    }

    @Test func offByDefaultAndNothingDownloadsWithoutConsent() async throws {
        let name = "chirp-test-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: name)!.removePersistentDomain(forName: name) }
        #expect(!Preferences(defaults: UserDefaults(suiteName: name)!).notesVoiceProfiles)
        let model = FakeVoiceModelStore(downloaded: false)
        let (v, box) = voices(model, enabled: false, answer: false)
        v.setEnabled(true)
        #expect(box.prompts == [.download(size: "8 MB")] && model.loads.isEmpty && !v.enabled)
        let (w, box2) = voices(model, enabled: false, answer: true)
        w.setEnabled(true)
        for _ in 0..<100 where !w.enabled { await Task.yield() }
        #expect(model.loads == [true] && w.enabled && box2.preference == true)
        // A stored "on" with the model gone comes back off, and Record never fetches it.
        model.setDownloaded(false)
        let (x, box3) = voices(model, enabled: true)
        #expect(!x.enabled && box3.preference == false)
        #expect(await x.prepare() == nil && model.loads == [true])
    }

    @Test func rememberNeedsANameEnoughSpeechAndSavesOneProfile() async throws {
        let model = FakeVoiceModelStore(downloaded: true), store = MemoryVoiceProfileStore()
        let (v, _) = voices(model, store, enabled: true)
        _ = await v.prepare()
        #expect(model.loads == [false])
        let prints = [4: heard(unit(0), 25), 7: heard(unit(1), 15)]
        #expect(!v.canRemember(1, in: document(), prints))                       // no name
        #expect(v.canRemember(1, in: document(name1: "Maya"), prints))
        #expect(!v.canRemember(2, in: document(name2: "Theo"), prints))           // 15 s
        #expect(throws: SpeakerVoices.Failure.notEnough) { try v.remember(2, name: "Theo", voice: prints[7]) }
        #expect(throws: SpeakerVoices.Failure.notEnough) { try v.remember(1, name: " ", voice: prints[4]) }
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let maya = try v.remember(1, name: "Maya", voice: prints[4], now: at)
        #expect(try store.load() == [maya] && maya.model == "fake@1" && maya.seconds == 25 && maya.created == at)
        #expect(v.link(1) == maya && !v.canRemember(1, in: document(name1: "Maya"), prints))
    }

    @Test func suggestionsSkipNamedLinkedAndDeclinedAndNeverRename() throws {
        let maya = VoiceProfile(name: "Maya", embedding: unit(0), model: "fake@1", seconds: 30)
        let old = VoiceProfile(name: "Theo", embedding: unit(1), model: "older@0", seconds: 30)
        let (v, _) = voices(FakeVoiceModelStore(downloaded: true), MemoryVoiceProfileStore([maya, old]), enabled: true)
        let prints = [4: heard(near(0, 9, 0.9), 12), 7: heard(unit(1), 30)]
        let d = document()
        #expect(v.suggestions(d, prints) == [1: maya])                             // Theo's is another model's
        #expect(v.incompatibleCount == 1)
        #expect(d.roster.displayName(1) == "Person 1")                             // a suggestion renames nothing
        #expect(v.suggestions(document(name1: "Ana"), prints).isEmpty)
        v.decline(1, maya)
        #expect(v.suggestions(d, prints).isEmpty)
        v.reset()
        v.accept(2, maya)                                                          // linked to someone else
        #expect(v.suggestions(d, prints).isEmpty)
        v.reset()
        #expect(v.suggestions(d, prints) == [1: maya])
        v.setEnabled(false)
        #expect(v.suggestions(d, prints).isEmpty)
    }

    @Test func updateIsTheSpeechWeightedMeanAndForgetDeletes() async throws {
        let store = MemoryVoiceProfileStore()
        let (v, _) = voices(FakeVoiceModelStore(downloaded: true), store, enabled: true)
        _ = await v.prepare()
        let maya = try v.remember(1, name: "Maya", voice: heard(unit(0), 30))
        let updated = try v.update(1, voice: heard(unit(1), 10), now: Date(timeIntervalSince1970: 1_900_000_000))
        #expect(updated.seconds == 40 && updated.created == maya.created && updated.updated > maya.updated)
        #expect(abs(Voiceprint.cosine(updated.embedding, unit(0)) - 3 / Float(10).squareRoot()) < 1e-5)
        #expect(throws: SpeakerVoices.Failure.notEnough) { try v.update(2, voice: heard(unit(1), 10)) }   // not linked
        let theo = try v.remember(2, name: "Theo", voice: heard(unit(1), 20))
        v.forget(maya.id)
        #expect(try store.load() == [theo] && v.link(1) == nil && v.link(2) == theo)
        v.forgetAll()
        #expect(try store.load().isEmpty && v.profiles.isEmpty && v.link(2) == nil)
    }

    @Test func logLinesCarryCountsOnly() {
        let line = VoiceLog.profiles(saved: 3, suggestions: 1)
        #expect(line.range(of: #"^notes voices saved=\d+ suggestions=\d+$"#, options: .regularExpression) != nil)
    }

    @Test func settingsTextNamesTheKeychainAndBiometrics() {
        #expect(VoiceProfilesText.explainer.contains("Keychain") && VoiceProfilesText.explainer.contains("biometric"))
        var s = VoiceProfilesState()
        #expect(VoiceProfilesText.status(s) == "Off")
        s.model = .downloading(0.5)
        #expect(VoiceProfilesText.status(s) == "Downloading voice model… 50%")
        let p = VoiceProfile(name: "Maya", embedding: [], model: "a", seconds: 41.6, created: Date(timeIntervalSince1970: 0))
        let utc = TimeZone(identifier: "UTC")!, en = Locale(identifier: "en_US")
        #expect(VoiceProfilesText.detail(p, compatible: true, locale: en, timeZone: utc) == "Saved Jan 1, 1970 · 42 s of speech")
        #expect(VoiceProfilesText.detail(p, compatible: false, locale: en, timeZone: utc).hasSuffix("remember the voice again"))
    }
}

/// The window: a suggestion beside the chip, Yes / Not, Remember with the consent tick, and nothing biometric anywhere
/// but the profile store.
@MainActor
@Suite(.serialized) struct VoiceSessionTests {
    /// A component no other number in a session has: if it shows up in text, a voiceprint leaked.
    static let marker: Float = 0.4242

    private func harness(_ profiles: [VoiceProfile]) async -> (NotesHarness, FakeDiarizer, MemoryVoiceProfileStore) {
        let store = MemoryVoiceProfileStore(profiles)
        let h = NotesHarness(speakers: FakeModelStore(downloaded: true), voiceModel: FakeVoiceModelStore(downloaded: true), profiles: store)
        _ = await h.session.voices.prepare()
        let fake = FakeDiarizer(script: [])
        fake.attachEmbedder(h.session.voices.readyEmbedder)
        h.recorder.speakers = fake
        h.recorder.editSpeakers { d in
            d.append(NotesSegment(id: 0, offset: 0, raw: "we ship ok", text: "We ship. OK."))
            d.attachSpeakers([.init(slot: 4, start: 0, text: "We ship."), .init(slot: 7, start: 1, text: "OK.")], toSegment: 0)
            return []
        }
        var mayaish = near(0, 9, 0.9)
        mayaish[20] = Self.marker
        fake.setVoiceprints([4: heard(mayaish, 14), 7: heard(near(1, 9, 0.9), 25)])
        return (h, fake, store)
    }

    @Test func aSuggestionIsShownAndOnlyAYesRenames() async throws {
        let maya = VoiceProfile(name: "Maya", embedding: unit(0), model: "fake@1", seconds: 30)
        let (h, _, _) = await harness([maya])
        h.session.sync()
        #expect(h.model.voices.enabled && h.model.voices.suggestions == [1: "Maya"])
        #expect(h.document.roster.displayName(1) == "Person 1")
        h.model.onSpeakerEdit(.declineVoice(1))
        #expect(h.model.voices.suggestions.isEmpty && h.document.roster.displayName(1) == "Person 1")
        h.session.voices.reset()
        h.session.sync()
        h.model.onSpeakerEdit(.acceptVoice(1))
        #expect(h.document.roster.displayName(1) == "Maya" && h.model.voices.linked == [1: "Maya"])
        #expect(h.model.voices.suggestions.isEmpty)
    }

    @Test func rememberAsksForConsentAndSavesOnlyWithTheTick() async throws {
        let (h, _, store) = await harness([])
        h.model.onSpeakerEdit(.rename(2, to: "Theo"))
        h.session.sync()
        #expect(h.model.voices.canRemember == [2])
        var asked: [String] = []
        h.session.confirmRememberVoice = { name, done in asked.append(name); done(false) }
        h.model.onSpeakerEdit(.rememberVoice(2))
        #expect(try asked == ["Theo"] && store.load().isEmpty)
        h.session.confirmRememberVoice = { _, done in done(true) }
        h.model.onSpeakerEdit(.rememberVoice(2))
        let saved = try store.load()
        #expect(saved.map(\.name) == ["Theo"] && saved[0].seconds == 25)
        #expect(h.model.visibleSpeakerBanner?.text == VoiceText.saved("Theo") && h.model.voices.linked == [2: "Theo"])
        // Person 1 (14 s, unnamed) cannot be remembered.
        h.model.onSpeakerEdit(.rememberVoice(1))
        #expect(try store.load().count == 1)
    }

    /// Privacy: voiceprints never reach the document, the journal, an export, a structuring request or a file.
    @Test func noVoiceprintLeavesTheProfileStore() async throws {
        let before = SpeakerPrivacyTests.footprint()
        let (h, _, store) = await harness([])
        h.model.onSpeakerEdit(.rename(1, to: "Maya"))
        h.session.confirmRememberVoice = { _, done in done(true) }
        // 14 s is not enough to remember; give Maya more of the marked voice.
        var mayaish = near(0, 9, 0.9)
        mayaish[20] = Self.marker
        (h.recorder.speakers as? FakeDiarizer)?.setVoiceprints([4: heard(mayaish, 30)])
        h.session.sync()
        h.model.onSpeakerEdit(.rememberVoice(1))
        let saved = try #require(try store.load().first)
        // The saved voice's own marked component, as any text would render it.
        let marker = String(String(saved.embedding[20]).prefix(6))
        #expect(saved.embedding[20] > 0.3 && marker.count == 6)
        let texts = [h.document.exportMarkdown(), String(data: try JSONEncoder().encode(h.document), encoding: .utf8)!,
                     h.document.nextStructureRequest().map { String(data: try! JSONEncoder().encode($0), encoding: .utf8)! } ?? ""]
        for text in texts { #expect(!text.contains(marker) && !text.contains("embedding")) }
        #expect(SpeakerPrivacyTests.footprint() == before)
    }
}

/// The real Keychain (opt-in: `CHIRP_KEYCHAIN_TESTS=1`, it writes to this Mac's keychain under a test service name and
/// deletes it again).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CHIRP_KEYCHAIN_TESTS"] == "1")) struct KeychainVoiceProfileTests {
    @Test func profilesRoundTripNeverSyncAndForgetDeletesThem() throws {
        let store = KeychainVoiceProfileStore(service: "Chirp Voice Profile Test \(UUID().uuidString)")
        defer { try? store.deleteAll() }
        let maya = VoiceProfile(name: "Maya", embedding: unit(3), model: "m", seconds: 30, created: Date(timeIntervalSince1970: 1))
        let theo = VoiceProfile(name: "Theo", embedding: unit(4), model: "m", seconds: 21, created: Date(timeIntervalSince1970: 2))
        try store.save(maya)
        try store.save(theo)
        var renamed = maya
        renamed.seconds = 45
        try store.save(renamed)
        #expect(try store.load() == [renamed, theo])
        // The item is not synchronizable (asked for explicitly: a synchronizable copy would not match).
        var result: AnyObject?
        let status = SecItemCopyMatching([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: store.service,
                                          kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
                                          kSecMatchLimit as String: kSecMatchLimitAll,
                                          kSecReturnAttributes as String: true] as CFDictionary, &result)
        #expect(status == errSecSuccess)
        let items = try #require(result as? [[String: Any]])
        #expect(items.count == 2 && items.allSatisfy { ($0[kSecAttrSynchronizable as String] as? Bool ?? false) == false })
        try store.delete(maya.id)
        #expect(try store.load() == [theo])
        try store.deleteAll()
        #expect(try store.load().isEmpty)
    }
}
