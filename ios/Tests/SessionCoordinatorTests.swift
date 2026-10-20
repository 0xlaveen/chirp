import AVFoundation
import ChirpCore
import ChirpIOSCore
import Foundation
import Testing
@testable import ChirpIOS

@Suite("App session lifecycle", .serialized)
@MainActor
struct SessionCoordinatorTests {
    final class Values {
        var copied: [String] = []
        var date = Date()
        var activity = true
        var transports: [SyntheticTransport] = []
    }
    @MainActor struct Fixture {
        let model: SessionCoordinator
        let transport: SyntheticTransport
        let audio: SyntheticAudio
        let values: Values
        let stores: AppServices
        let root: URL
        func clean() { model.endSession(); try? FileManager.default.removeItem(at: root) }
    }
    func fixture(permission: Bool = true) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-unit-" + UUID().uuidString)
        let stores = try AppServices(root: root, secrets: MemorySecretStore())
        let credentials = try PairingLink.parse("chirp://pair?url=https%3A%2F%2Fsynthetic.test.ts.net%2Fchirp&token=synthetic-only")
        try await stores.pairing.verifyAndSave(credentials, health: { _ in Health(engine: "synthetic", ready: true) })
        let http = URLSessionConfiguration.ephemeral; http.protocolClasses = [SyntheticHTTP.self]
        let transport = SyntheticTransport(), audio = SyntheticAudio(), values = Values()
        let model = SessionCoordinator(services: stores, audio: audio, http: URLSession(configuration: http),
            makeStream: { _, options, _ in
                let next = values.transports.isEmpty ? transport : SyntheticTransport()
                values.transports.append(next)
                return StreamSession(transport: next, options: options)
            },
            requestPermission: { permission }, permissionGranted: { permission }, activityBegin: { _ in }, activityActive: { values.activity },
            activityUpdate: { _, _ in }, activityEnd: {}, copyText: { values.copied.append($0) },
            now: { values.date }, production: false)
        return Fixture(model: model, transport: transport, audio: audio, values: values, stores: stores, root: root)
    }
    func eventually(_ check: () -> Bool) async throws {
        for _ in 0..<200 {
            if check() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(check(), "Expected synthetic event to complete within one second")
    }
    func ready(_ f: Fixture, index: Int = 0) async throws {
        f.values.transports[index].push(#"{"type":"ready","session":"synthetic","debug_retention":false}"#)
        try await eventually { f.model.phase == .listening }
    }

    @Test func normalFinalNeverCopiesAndHistoryStartsOff() async throws {
        let f = try await fixture(); defer { f.clean() }
        try await f.model.begin()
        try await ready(f)
        f.transport.push(#"{"type":"partial","seq":1,"text":"raw words","stable":"","words":[{"text":"raw","start":0,"end":0.2,"stable":false}]}"#)
        try await eventually { f.model.text == "raw words" }
        #expect(f.model.words.count == 1)
        f.model.stopDictation()
        f.transport.push(#"{"type":"correcting","seq":2,"raw":"raw words","profile":"default"}"#)
        try await eventually { f.model.phase == .correcting }
        f.transport.push(#"{"type":"final","text":"Raw words.","raw":"raw words","corrected":true}"#)
        try await eventually { f.model.phase == .finished }
        #expect(f.values.copied.isEmpty)
        #expect(try f.stores.history.entries().isEmpty)
        #expect(f.audio.armed)
        f.model.copy()
        #expect(f.values.copied == ["Raw words."])
    }

    @Test func stopBeforeReadyAndRepeatedStopIntentsResolveTogether() async throws {
        let f = try await fixture(); defer { f.clean() }
        try await f.model.begin(source: .companion)
        let first = Task { try await f.model.perform(action: .stop) }
        let second = Task { try await f.model.perform(action: .stop) }
        try await Task.sleep(for: .milliseconds(10))
        #expect(!f.transport.sent.contains { if case .string(let value) = $0 { value == ClientMessage.stop } else { false } })
        try await ready(f)
        f.transport.push(#"{"type":"final","text":"Fresh synthetic final","raw":"Fresh synthetic final"}"#)
        _ = try await first.value
        _ = try await second.value
        #expect(f.values.copied == ["Fresh synthetic final"])
    }

    @Test func toggleStartsInArmedSessionThenStopsAndCopies() async throws {
        let f = try await fixture(); defer { f.clean() }
        try await f.model.armSession()
        _ = try await f.model.perform(action: .toggle)
        try await ready(f)
        let stopping = Task { try await f.model.perform(action: .toggle) }
        try await Task.sleep(for: .milliseconds(10))
        f.transport.push(#"{"type":"final","text":"Hotkey final"}"#)
        #expect(try await stopping.value == "Copied. Paste with ⌘V.")
        #expect(f.values.copied == ["Hotkey final"])
        #expect(f.model.armed)
    }

    @Test func keyboardStopIntentDoesNotCopy() async throws {
        let f = try await fixture(); defer { f.clean() }
        try await f.model.begin(source: .keyboard)
        try await ready(f)
        let stopping = Task { try await f.model.perform(action: .stop) }
        try await Task.sleep(for: .milliseconds(10))
        f.transport.push(#"{"type":"final","text":"Keyboard final"}"#)
        _ = try await stopping.value
        #expect(f.values.copied.isEmpty)
    }

    @Test func cancelAndEndFenceDelayedCompanionFinal() async throws {
        for ending in [false, true] {
            let f = try await fixture(); defer { f.clean() }
            try await f.model.begin(source: .companion); try await ready(f)
            if ending { f.model.endSession() } else { f.model.cancelDictation() }
            f.transport.push(#"{"type":"final","text":"Must never copy"}"#)
            try await Task.sleep(for: .milliseconds(20))
            #expect(f.model.text.isEmpty)
            #expect(f.values.copied.isEmpty)
            #expect(try f.stores.history.entries().isEmpty)
        }
    }

    @Test func sessionExpiryClearsTextAndMicrophone() async throws {
        let f = try await fixture(); defer { f.clean() }
        try await f.model.begin(); try await ready(f)
        f.transport.push(#"{"type":"partial","seq":1,"text":"transient","stable":""}"#)
        try await eventually { !f.model.text.isEmpty }
        f.values.date = f.values.date.addingTimeInterval(301)
        f.model.reconcile()
        #expect(!f.model.armed && !f.audio.armed)
        #expect(f.model.text.isEmpty && f.model.raw.isEmpty && f.model.words.isEmpty)
        #expect(try f.stores.bridge.state() == nil)
    }

    @Test func permissionAndActivityFailureNeverArmCapture() async throws {
        let denied = try await fixture(permission: false); defer { denied.clean() }
        await #expect(throws: SessionFailure.permission) { try await denied.model.armSession() }
        #expect(!denied.audio.armed)
        let dismissed = try await fixture(); defer { dismissed.clean() }
        try await dismissed.model.armSession()
        dismissed.values.activity = false
        dismissed.model.reconcile()
        #expect(!dismissed.audio.armed && !dismissed.model.armed)
    }

    @Test func duplicateBeginDoesNotEndCurrentUtterance() async throws {
        let f = try await fixture(); defer { f.clean() }
        try await f.model.begin(); try await ready(f)
        do { try await f.model.begin(source: .keyboard); Issue.record("Duplicate start accepted") } catch {}
        #expect(f.model.armed && f.model.phase == .listening)
    }

    @Test func staleCaptureCallbacksCannotStopOrFailNextUtterance() async throws {
        let f = try await fixture(); defer { f.clean() }
        try await f.model.begin(); try await ready(f)
        let oldLimit = try #require(f.audio.limits.first)
        let oldFailure = try #require(f.audio.failures.first)
        f.model.cancelDictation()
        try await f.model.begin()
        #expect(f.values.transports.count == 2)
        #expect(f.values.transports[0] !== f.values.transports[1])
        try await ready(f, index: 1)
        oldLimit(); oldFailure()
        try await Task.sleep(for: .milliseconds(20))
        #expect(f.model.armed && f.model.phase == .listening)
        #expect(f.audio.finishCount == 0)
    }

    @Test func useRawUpdatesExistingEncryptedHistory() async throws {
        let f = try await fixture(); defer { f.clean() }
        try f.stores.history.setEnabled(true)
        try await f.model.begin(); try await ready(f); f.model.stopDictation()
        f.transport.push(#"{"type":"final","text":"Cleaned.","raw":"raw","corrected":true}"#)
        try await eventually { f.model.phase == .finished }
        let before = try #require(f.stores.history.entries().first)
        f.model.useRaw()
        let after = try #require(f.stores.history.entries().first)
        #expect(after.id == before.id && after.text == "raw" && !after.corrected)
        #expect(f.values.copied.isEmpty)
    }

    @Test func privateModeNeverEntersHistory() async throws {
        let f = try await fixture(); defer { f.clean() }
        try f.stores.history.setEnabled(true)
        f.model.preferences.privacyMode = true; f.model.savePreferences()
        try await f.model.begin(); try await ready(f); f.model.stopDictation()
        f.transport.push(#"{"type":"final","text":"Private final"}"#)
        try await eventually { f.model.phase == .finished }
        #expect(try f.stores.history.entries().isEmpty)
    }

    @Test(arguments: ["", " \n\t"])
    func blankCompanionFinalResolvesStopWithoutHistoryOrClipboard(_ blank: String) async throws {
        let f = try await fixture(); defer { f.clean() }
        try f.stores.history.setEnabled(true)
        try await f.model.begin(source: .companion); try await ready(f)
        let stopping = Task { () -> Bool in
            do { _ = try await f.model.perform(action: .stop); return false }
            catch { return (error as? SessionFailure) == .cancelled }
        }
        try await eventually { f.audio.finishCount == 1 }
        let message = try JSONSerialization.data(withJSONObject: ["type": "final", "text": blank, "raw": blank])
        f.transport.push(String(decoding: message, as: UTF8.self))
        #expect(await stopping.value, "Blank final must resolve the pending companion waiter with an error")
        #expect(f.model.armed && f.model.phase == .armed)
        #expect(f.model.text.isEmpty && f.model.raw.isEmpty && f.model.words.isEmpty)
        #expect(f.model.notice == SessionFailure.noResult.localizedDescription)
        f.transport.push(#"{"type":"final","text":"Delayed stale final"}"#)
        try await Task.sleep(for: .milliseconds(20))
        #expect(f.values.copied.isEmpty)
        #expect(try f.stores.history.entries().isEmpty)
    }

    @Test func cleanupRequiresExplicitKnownDestinationConsent() {
        var preferences = IOSPreferences()
        let local = Health(correction: "available", correctionLeavesMachine: false)
        #expect(!preferences.permitsCorrection(health: local))
        preferences.correction = true
        #expect(preferences.permitsCorrection(health: local))
        let external = Health(correction: "available", correctionLeavesMachine: true, correctionHost: "synthetic.example")
        #expect(!preferences.permitsCorrection(health: external))
        preferences.consentHost = "synthetic.example"
        #expect(preferences.permitsCorrection(health: external))
        #expect(!preferences.permitsCorrection(health: Health(correction: "available", correctionLeavesMachine: true)))
    }
}
