import Foundation
import Testing
@testable import ChirpCore

/// A model store with no model behind it: it records every load, can hold one until released, and can fail.
final class FakeModelStore: SpeakerModelStore, @unchecked Sendable {
    private let lock = NSLock()
    private var _downloaded: Bool
    private var _files: Bool
    private var _loads: [Bool] = []
    private var _removes = 0
    private var held: CheckedContinuation<Void, Never>?
    var hold = false
    var fail = false

    init(downloaded: Bool) {
        _downloaded = downloaded
        _files = downloaded
    }

    var sizeText: String { "106 MB" }
    /// Every load so far: true for a download (the network), false for an offline load.
    var loads: [Bool] { lock.withLock { _loads } }
    var removes: Int { lock.withLock { _removes } }
    func setDownloaded(_ on: Bool, files: Bool? = nil) { lock.withLock { _downloaded = on; _files = files ?? on } }
    func isDownloaded() -> Bool { lock.withLock { _downloaded } }
    func hasFiles() -> Bool { lock.withLock { _files } }
    func remove() throws { lock.withLock { _removes += 1; _downloaded = false; _files = false } }

    func load(download: Bool, progress: @escaping @Sendable (Double) -> Void) async throws -> any SpeakerDiarizerFactory {
        let shouldHold = lock.withLock { () -> Bool in
            _loads.append(download)
            if download { _files = true }
            return hold
        }
        if shouldHold { await withCheckedContinuation { c in lock.withLock { held = c } } }
        try Task.checkCancellation()
        if fail { throw CocoaError(.fileReadCorruptFile) }
        lock.withLock { if download { _downloaded = true } }
        return FakeFactory()
    }

    func release() {
        let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in defer { held = nil }; hold = false; return held }
        c?.resume()
    }
}

final class FakeFactory: SpeakerDiarizerFactory, @unchecked Sendable {
    func makeDiarizer() -> SpeakerDiarizing { FakeDiarizer(script: []) }
}

@MainActor
@Suite struct SpeakerLabelsTests {
    private func labels(_ store: FakeModelStore, enabled: Bool, answer: Bool? = nil) -> (SpeakerLabels, Box) {
        let box = Box()
        let l = SpeakerLabels(store: store, enabled: enabled, onPreference: { box.preference = $0 })
        l.confirm = { prompt, done in
            box.prompts.append(prompt)
            if let answer { done(answer) }
        }
        return (l, box)
    }

    final class Box { var preference: Bool?; var prompts: [SpeakerLabels.Prompt] = [] }

    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(2)) }
    }

    // MARK: B1: no download without consent

    @Test func launchWithTheModelGoneTurnsLabelsOff() {
        let store = FakeModelStore(downloaded: false)
        let (l, box) = labels(store, enabled: true)
        #expect(!l.enabled && box.preference == false && l.model == .notDownloaded && store.loads.isEmpty)
    }

    @Test func recordWithTheModelGoneNeverLoadsOrDownloads() async {
        let store = FakeModelStore(downloaded: true)
        let (l, box) = labels(store, enabled: true)
        store.setDownloaded(false)          // removed from disk after launch
        #expect(l.needsLoad)
        #expect(await l.prepare() == nil)
        #expect(store.loads.isEmpty && box.prompts.isEmpty)
        #expect(!l.enabled && box.preference == false && l.model == .notDownloaded)
    }

    @Test func recordLoadsOfflineOnly() async {
        let store = FakeModelStore(downloaded: true)
        let (l, _) = labels(store, enabled: true)
        #expect(await l.prepare() != nil)
        #expect(store.loads == [false])
        // The same document keeps its diarizer; New frees it, and the next Record loads (offline) again.
        let first = l.diarizer
        #expect(await l.prepare() === first)
        l.reset()
        #expect(l.diarizer == nil && l.needsLoad)
        _ = await l.prepare()
        #expect(store.loads == [false, false])
    }

    @Test func turningOnAsksBeforeTheDownloadAndDecliningFetchesNothing() async {
        let store = FakeModelStore(downloaded: false)
        let (l, box) = labels(store, enabled: false, answer: false)
        l.setEnabled(true, documentHasLabels: false)
        #expect(box.prompts == [.download(size: "106 MB")])
        try? await Task.sleep(for: .milliseconds(20))
        #expect(store.loads.isEmpty && !l.enabled)
    }

    @Test func downloadOnlyAfterTheUsersDownload() async {
        let store = FakeModelStore(downloaded: false)
        let (l, box) = labels(store, enabled: false, answer: true)
        l.setEnabled(true, documentHasLabels: false)
        await settle { l.enabled }
        #expect(store.loads == [true] && l.enabled && box.preference == true && l.model == .ready)
        // Already loaded: Record makes the diarizer without another load.
        #expect(l.readyDiarizer() != nil && store.loads == [true])
    }

    @Test func aDamagedModelFailsOfflineAndOnlyARedownloadTheUserAcceptsRepairsIt() async {
        let store = FakeModelStore(downloaded: true)
        store.fail = true
        let (l, box) = labels(store, enabled: true, answer: true)
        #expect(await l.prepare() == nil)
        #expect(store.loads == [false] && l.model == .failed("the model did not load") && !l.enabled)
        store.fail = false
        l.setEnabled(true, documentHasLabels: false)
        #expect(box.prompts == [.redownload(size: "106 MB")])
        await settle { l.enabled }
        #expect(store.removes == 1 && store.loads == [false, true] && l.model == .ready)
    }

    // MARK: edges

    @Test func switchingOffCancelsADownload() async {
        let store = FakeModelStore(downloaded: false)
        store.hold = true
        let (l, _) = labels(store, enabled: false, answer: true)
        l.setEnabled(true, documentHasLabels: false)
        await settle { l.model.isDownloading && store.loads == [true] }
        l.setEnabled(false, documentHasLabels: false)
        store.release()
        await settle { !l.isLoading }
        #expect(!l.enabled && l.model == .notDownloaded && l.readyDiarizer() == nil)
    }

    @Test func removeIsRefusedWhileLoadingAndCoversPartialDownloads() async {
        let store = FakeModelStore(downloaded: true)
        store.hold = true
        let (l, box) = labels(store, enabled: true)
        let prepared = Task { await l.prepare() }
        await settle { l.isLoading }
        #expect(!l.canRemove && !l.remove() && store.removes == 0)
        store.release()
        _ = await prepared.value
        // A partial download (files but no complete model) can be removed too.
        store.setDownloaded(false, files: true)
        #expect(l.canRemove && l.remove())
        #expect(store.removes == 1 && !l.enabled && box.preference == false && l.diarizer == nil)
    }

    @Test func switchingOffFreesTheModelUnlessTheDocumentHasLabels() async {
        let store = FakeModelStore(downloaded: true)
        let (l, _) = labels(store, enabled: true)
        _ = await l.prepare()
        l.setEnabled(false, documentHasLabels: true)
        #expect(l.diarizer != nil)             // kept: on again keeps Person N
        l.setEnabled(true, documentHasLabels: true)
        #expect(l.readyDiarizer() != nil && store.loads == [false])
        l.setEnabled(false, documentHasLabels: false)
        #expect(l.diarizer == nil && !l.needsLoad)
        l.setEnabled(true, documentHasLabels: false)
        #expect(l.needsLoad)
    }
}
