import AppKit
import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

@Suite struct DictationParityTests {
    @Test func segmentBoundariesMatchPhones() {
        var s = RollingDictationSegmenter()
        let cut1 = s.feed(rms: 0.5, duration: 44)
        #expect(!cut1)
        let cut2 = s.feed(rms: 0, duration: 0.6)
        #expect(!cut2)
        let cut3 = s.feed(rms: 0, duration: 0.4)
        #expect(cut3)
        s = RollingDictationSegmenter()
        let cut4 = s.feed(rms: 0.5, duration: 70)
        #expect(!cut4)
        let cut5 = s.feed(rms: 0, duration: 0.3)
        #expect(cut5)
        s = RollingDictationSegmenter()
        let cut6 = s.feed(rms: 0.5, duration: 89.9)
        #expect(!cut6)
        let cut7 = s.feed(rms: 0.5, duration: 0.1)
        #expect(cut7)
        #expect(RollingDictationSegmenter.maxTotal == 600)
    }

    /// Same cases as KeyboardPolicy/FinalCasingTests and Android FinalCasingTest; no casing change on Mac.
    @Test func phoneCommandRulesAndDefault() {
        let suite = "chirp-parity-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        #expect(!prefs.spokenCommands)
        prefs.spokenCommands = true
        #expect(Preferences(defaults: defaults).spokenCommands)
        for (input, expected) in [("Okay, new line.", "Okay,\n"), ("New paragraph", "\n\n"),
                                  ("And then new paragraph!", "And then\n\n"), ("NEW LINE…  ", "\n"),
                                  ("new lines", "new lines"), ("a new line of work", "a new line of work"),
                                  ("renew line", "renew line"), ("new line: text", "new line: text"),
                                  ("say new line new paragraph", "say new line\n\n")] {
            #expect(SpokenCommands.apply(input, enabled: true) == expected)
            #expect(SpokenCommands.apply(input, enabled: false) == input)
        }
        #expect(RollingDictationSession.join(["one\n", "two", "", "three"]) == "one\ntwo three")
    }

    @Test @MainActor func privateSessionEndsOnTimerLockOrProcessEnd() {
        var clock: TimeInterval = 100
        let privacy = PrivateSession(now: { clock })
        #expect(!privacy.isActive)
        privacy.setEnabled(true)
        clock += 3599
        #expect(privacy.isActive)
        clock += 1
        privacy.expireIfNeeded()
        #expect(!privacy.isActive)
        privacy.setEnabled(true)
        privacy.screenLocked()
        #expect(!privacy.isActive)
        privacy.setEnabled(true)
        #expect(!PrivateSession().isActive)
        privacy.setEnabled(false)
        #expect(!privacy.isActive)
    }

    @Test @MainActor func privateMenuAndHUDState() {
        var inputs = MenuInputs()
        inputs.health = Health(ready: true)
        #expect(!MenuContent.header(inputs).status.contains("Private session"))
        inputs.privateSession = true
        #expect(MenuContent.header(inputs).status.contains("Private session"))
        let row = MenuContent.entries(inputs).first { $0.action == .togglePrivateSession }
        #expect(row?.mark == .on && row?.title == "Private session")
        let model = HUDModel()
        model.privateSession = true
        model.duration = "2:01 / 10:00"
        model.reset()
        #expect(!model.privateSession && model.duration == nil)
        var state = SettingsState()
        state.privateSession = true
        state.spokenCommands = true
        let form = SettingsForm(state)
        form.apply(state, full: true)
        #expect(form.privateSession.state == .on && form.spokenCommands.state == .on)
        state.privateSession = false
        form.apply(state)
        #expect(form.privateSession.state == .off)
    }
}

/// Real StreamSessions with controllable transports: test rolling orchestration, not a duplicate state model.
private final class RollingSocket: StreamTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let messages: AsyncStream<URLSessionWebSocketTask.Message>
    private let input: AsyncStream<URLSessionWebSocketTask.Message>.Continuation
    let starts: AsyncStream<Void>
    private let started: AsyncStream<Void>.Continuation
    let stops: AsyncStream<Void>
    private let stopped: AsyncStream<Void>.Continuation
    private var bytes = 0
    private var cancelled = false
    var audioBytes: Int { lock.withLock { bytes } }
    var didClose: Bool { lock.withLock { cancelled } }
    init() {
        (messages, input) = AsyncStream.makeStream()
        (starts, started) = AsyncStream.makeStream()
        (stops, stopped) = AsyncStream.makeStream()
    }
    func resume() {}
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        switch message {
        case .data(let data): lock.withLock { bytes += data.count }
        case .string(let text):
            if text.contains("\"type\":\"start\"") {
                input.yield(.string(#"{"type":"ready","session":"test","debug_retention":false}"#))
                started.yield()
            }
            if text.contains("\"type\":\"stop\"") { stopped.yield() }
        @unknown default: break
        }
    }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        var iterator = messages.makeAsyncIterator()
        guard let message = await iterator.next() else { throw URLError(.cancelled) }
        return message
    }
    func cancel(with code: URLSessionWebSocketTask.CloseCode) {
        lock.withLock { cancelled = true }
        input.finish()
    }
    func emit(_ json: String) { input.yield(.string(json)) }
    func final(_ text: String, raw: String? = nil, corrected: Bool = true) {
        let data = try! JSONSerialization.data(withJSONObject: ["type": "final", "text": text, "raw": raw ?? text, "corrected": corrected])
        input.yield(.string(String(decoding: data, as: UTF8.self)))
    }
    func waitForStart() async { for await _ in starts { break } }
    func waitForStop() async { for await _ in stops { break } }
}

private final class RollingSockets: @unchecked Sendable {
    private let lock = NSLock()
    private var sockets: [RollingSocket] = []
    var all: [RollingSocket] { lock.withLock { sockets } }
    func make() -> StreamSession {
        let socket = RollingSocket()
        lock.withLock { sockets.append(socket) }
        var limits = StreamLimits()
        // Fast-forward the audio clock without the real-time producer's socket backpressure.
        limits.maxQueuedBytes = 20_000_000
        return StreamSession(transport: socket, options: StartOptions(), limits: limits)
    }
}

@Suite(.timeLimit(.minutes(1))) struct RollingDictationTests {
    private func audio(_ seconds: Double) -> Data {
        let count = Int(seconds * PCMConverter.sampleRate)
        return [Int16](repeating: 10_000, count: count).withUnsafeBytes { Data($0) }
    }
    private func result(_ session: RollingDictationSession) async -> FinalResult? {
        for await event in session.events {
            if case .message(.final(let final)) = event { return final }
        }
        return nil
    }

    @Test @MainActor func past119SecondsFinalsCommitInCaptureOrderWithWholeRawReplacement() async throws {
        let sockets = RollingSockets()
        let session = RollingDictationSession(correctionTimeout: 5, makeStream: { sockets.make() })
        await session.open()
        session.sendAudio(audio(90))
        session.sendAudio(audio(35))
        await session.stop()
        #expect(sockets.all.count == 2)
        for socket in sockets.all { await socket.waitForStop() }
        sockets.all[1].final("Second.", raw: "second")
        sockets.all[0].final("First.", raw: "first")
        let final = try #require(await result(session))
        #expect(final.text == "First. Second." && final.raw == "first second" && final.canUseRaw)
        #expect(sockets.all.map(\.audioBytes) == [90 * 32_000, 35 * 32_000])
        let system = FakeSystem(), board = FakePasteboard()
        system.ax = .verified(NSRange(location: 0, length: final.raw.utf16.count))
        let inserter = system.inserter(board: board)
        #expect(await inserter.insert(final.raw, undoRaw: final.raw, undoWindow: TextInserter.swapWindow) == .inserted(.ax))
        #expect(await inserter.replaceInserted(with: final.text))
        #expect(await inserter.useRaw() == .inserted(.ax))
        #expect(system.calls == ["ax", "axReplace:0,12:first second→First. Second.",
                                 "axReplace:0,14:First. Second.→first second"])
        inserter.forgetUndo()
        await session.close()
    }

    @Test func cancelAllSocketsDiscardsLateFinals() async {
        let sockets = RollingSockets()
        let session = RollingDictationSession(correctionTimeout: 5, makeStream: { sockets.make() })
        await session.open()
        session.sendAudio(audio(90))
        session.sendAudio(audio(31))
        for socket in sockets.all { await socket.waitForStart() }
        await session.cancel()
        for socket in sockets.all { socket.final("Late.") }
        #expect(await result(session) == nil)
        #expect(sockets.all.allSatisfy { $0.didClose })
    }

    @Test func tenMinuteLimitNeverSendsOversizedUtterance() async throws {
        let sockets = RollingSockets()
        let session = RollingDictationSession(correctionTimeout: 5, makeStream: { sockets.make() })
        await session.open()
        session.sendAudio(audio(601))
        #expect(sockets.all.count == 7)
        for (index, socket) in sockets.all.enumerated() {
            await socket.waitForStop()
            socket.final("\(index)")
        }
        let final = try #require(await result(session))
        #expect(final.text == "0 1 2 3 4 5 6")
        #expect(sockets.all.map(\.audioBytes).reduce(0, +) == 600 * 32_000)
        #expect(sockets.all.allSatisfy { $0.audioBytes <= 90 * 32_000 })
        await session.close()
    }

    @Test func commandOnlyFinalRemainsInsertableAndRawStaysVerbatim() async throws {
        let sockets = RollingSockets()
        let session = RollingDictationSession(correctionTimeout: 5, commands: true, makeStream: { sockets.make() })
        await session.open()
        await session.stop()
        await sockets.all[0].waitForStop()
        sockets.all[0].final("New paragraph.", corrected: false)
        let final = try #require(await result(session))
        #expect(final.text == "\n\n" && !final.text.isEmpty)
        #expect(final.raw == "New paragraph." && !final.canUseRaw)
        await session.close()
    }

    @Test func segmentCleanupFailureKeepsRawAndCommandBreaksSurviveJoining() async throws {
        let sockets = RollingSockets()
        let session = RollingDictationSession(correctionTimeout: 0.02, commands: true, makeStream: { sockets.make() })
        await session.open()
        session.sendAudio(audio(90))
        session.sendAudio(audio(1))
        await session.stop()
        for socket in sockets.all { await socket.waitForStop() }
        sockets.all[0].final("First new paragraph.", raw: "first new paragraph")
        sockets.all[1].emit(#"{"type":"correcting","seq":1,"raw":"second new line","profile":"default"}"#)
        let final = try #require(await result(session))
        #expect(final.text == "First\n\nsecond\n")
        #expect(final.raw == "first new paragraph second new line")
        #expect(final.correctionError != nil)
        await session.close()
    }
}
