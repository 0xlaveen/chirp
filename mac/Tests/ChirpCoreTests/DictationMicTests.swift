import Foundation
import Testing
@testable import ChirpCore

/// A clock the test moves by hand (uptime seconds).
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval
    init(_ t: TimeInterval) { self.t = t }
    func now() -> TimeInterval { lock.withLock { t } }
    func advance(_ d: TimeInterval) { lock.withLock { t += d } }
}

/// What a dictation's sink received: each frame and whether it was zeroed for the cue.
private final class SentAudio: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [(Data, Bool)] = []
    func add(_ frame: Data, _ muted: Bool) { lock.withLock { frames.append((frame, muted)) } }
    var muted: [Bool] { lock.withLock { frames.map(\.1) } }
    var data: Data { lock.withLock { frames.reduce(into: Data()) { $0.append($1.0) } } }
    var samples: [Int16] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }
}

/// The same deliveries through a plain `AudioCapture`: what the microphone heard, frame for frame.
private func heard(_ deliveries: [Double]) throws -> Data {
    let engine = FakeEngine()
    let capture = AudioCapture(engine: engine)
    let box = SentAudio()
    try capture.start { box.add($0, false) }
    for seconds in deliveries { engine.deliver(seconds: seconds) }
    return box.data
}

private func samples(_ seconds: TimeInterval) -> Int { Int((seconds * PCMConverter.sampleRate).rounded()) }

@Suite struct DictationMicTests {
    /// Opening the input on the fake engine costs this much on the test clock.
    static let engineStart: TimeInterval = 0.03
    /// The default pack's start cue (Assets/Sounds/chirp-start.wav).
    static let chirpCue: TimeInterval = 0.12

    private func make() -> (DictationMic, FakeEngine, TestClock) {
        let clock = TestClock(100)
        let engine = FakeEngine()
        engine.onStart = { clock.advance(Self.engineStart) }
        return (DictationMic(capture: AudioCapture(engine: engine), now: { clock.now() }), engine, clock)
    }

    /// What `DictationController` does at a dictation's start: open the microphone (unless the press already did),
    /// attach the dictation's sink, then play the start cue and zero its window. Nothing waits for the cue.
    private func start(_ mic: DictationMic, clock: TestClock, cue: TimeInterval?, into sent: SentAudio) throws {
        try mic.open()
        mic.attach { sent.add($0, $1) }
        if let cue { mic.excludeCue(at: clock.now(), length: SoundTiming.muteWindow(cueDuration: cue)) }
    }

    @Test func soundsOnOrOffTheFirstSampleIsCapturedAtTheSameTime() throws {
        var latency: [Bool: TimeInterval] = [:]
        for soundsOn in [false, true] {
            let (mic, engine, clock) = make()
            let sent = SentAudio()
            let pressed = clock.now()
            try start(mic, clock: clock, cue: soundsOn ? Self.chirpCue : nil, into: sent)
            engine.deliver(seconds: 0.5)
            latency[soundsOn] = try #require(mic.openedAt) - pressed

            let window = samples(SoundTiming.muteWindow(cueDuration: Self.chirpCue))   // 160 ms
            let pcm = sent.samples
            if soundsOn {
                // The cue's window is zeroed; the whole frames inside it are flagged, and what follows is kept.
                #expect(pcm[..<window].allSatisfy { $0 == 0 })
                #expect(pcm[window..<(window + 640)].contains { $0 != 0 })
                #expect(sent.muted.prefix(4) == [true, true, true, false])
            } else {
                #expect(pcm[160..<window].contains { $0 != 0 })
                #expect(!sent.muted.contains(true))
            }
            #expect(sent.data.count == (try heard([0.5])).count)   // zeroed, never dropped
            mic.close()
        }
        // Hotkey-down → first captured sample: only the input's own start-up, with the cue or without it.
        #expect(latency[false] == latency[true])
        #expect(abs(try #require(latency[true]) - Self.engineStart) < 1e-9)
        // Before, the microphone opened only after the cue (cue + 20 ms, at most 300 ms), then started up.
        let before = SoundTiming.micDelay(cueDuration: Self.chirpCue) + Self.engineStart
        #expect(try #require(latency[true]) < before)
    }

    @Test func aCuePlayedBeforeTheMicrophoneCouldOpenZeroesNothing() throws {
        // The first dictation waits for the permission prompt: the cue is long over by the time the input opens.
        let (mic, engine, clock) = make()
        let sent = SentAudio()
        mic.excludeCue(at: clock.now(), length: SoundTiming.muteWindow(cueDuration: Self.chirpCue))
        clock.advance(2)
        try mic.open()
        mic.attach { sent.add($0, $1) }
        engine.deliver(seconds: 0.3)
        #expect(!sent.muted.contains(true))
        #expect(sent.data == (try heard([0.3])))
    }

    @Test func thePreRollIsSentFirstInOrderAndOnlyTheCueInsideItsWindowIsZeroed() throws {
        // A held Right ⌥: the microphone opened on the press, the dictation started (and the cue played) 200 ms later.
        let (mic, engine, _) = make()
        let sent = SentAudio()
        try mic.open()
        engine.deliver(seconds: 0.2)
        mic.attach { sent.add($0, $1) }
        let opened = try #require(mic.openedAt)
        mic.excludeCue(at: opened + 0.2, length: SoundTiming.muteWindow(cueDuration: Self.chirpCue))
        engine.deliver(seconds: 0.3)
        mic.close()

        let reference = try heard([0.2, 0.3])
        let pcm = sent.samples
        let from = samples(0.2), to = samples(0.2 + SoundTiming.muteWindow(cueDuration: Self.chirpCue))
        #expect(sent.data.count >= reference.count + 640)   // plus the trailing frame `stop` flushes
        // The pre-roll, unchanged and first; the window is zeroed (± a sample of rounding); the rest is unchanged.
        #expect(sent.data.prefix((from - 1) * 2) == reference.prefix((from - 1) * 2))
        #expect(pcm[from..<to].allSatisfy { $0 == 0 })
        #expect(sent.data[((to + 1) * 2)..<reference.count] == reference[((to + 1) * 2)...])
    }

    @Test func thePreRollHoldsAtMostOneSecondDroppingTheOldest() throws {
        let (mic, engine, _) = make()
        let sent = SentAudio()
        try mic.open()
        for _ in 0..<6 { engine.deliver(seconds: 0.5) }   // 3 s with no dictation attached
        mic.attach { sent.add($0, $1) }
        let limit = samples(DictationMic.preRollLimit) * 2
        let reference = try heard(Array(repeating: 0.5, count: 6))
        #expect(sent.data.count <= limit)
        #expect(sent.data.count > limit - PCMConverter.frameBytes)
        #expect(sent.data == reference.suffix(sent.data.count))
        mic.close()
    }

    @Test func aPressThatNeverBecomesADictationDropsItsPreRollUnsentAndClosesTheMicrophone() throws {
        let (mic, engine, _) = make()
        try mic.open()
        engine.deliver(seconds: 0.3)
        #expect(mic.isOpen && engine.taps == 1)
        mic.close()   // a chord (⌥←) or an early release
        #expect(!mic.isOpen && engine.taps == 0 && engine.stops >= 1)

        // Nothing of it reaches the next dictation.
        let sent = SentAudio()
        mic.attach { sent.add($0, $1) }
        #expect(sent.data.isEmpty)
        mic.close()
        try mic.open()
        mic.attach { sent.add($0, $1) }
        engine.deliver(seconds: 0.1)
        #expect(sent.data == (try heard([0.1])))
        mic.close()
    }
}

/// A socket that is still connecting: every send waits until `connect()`. Records audio and text frames.
private final class ConnectingSocket: StreamTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var isConnected = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var frames: [Data] = []
    private var texts: [String] = []
    private let messages: AsyncStream<URLSessionWebSocketTask.Message>
    private let input: AsyncStream<URLSessionWebSocketTask.Message>.Continuation
    let stops: AsyncStream<Void>
    private let stopped: AsyncStream<Void>.Continuation

    init() {
        (messages, input) = AsyncStream.makeStream()
        (stops, stopped) = AsyncStream.makeStream()
    }

    var audio: Data { lock.withLock { frames.reduce(into: Data()) { $0.append($1) } } }
    var sentTexts: [String] { lock.withLock { texts } }

    func connect() {
        let resume = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isConnected = true
            defer { waiting = [] }
            return waiting
        }
        for c in resume { c.resume() }
    }

    func resume() {}
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                if isConnected { return true }
                waiting.append(c)
                return false
            }
            if now { c.resume() }
        }
        switch message {
        case .data(let data): lock.withLock { frames.append(data) }
        case .string(let text):
            lock.withLock { texts.append(text) }
            if text.contains("\"type\":\"start\"") {
                input.yield(.string(#"{"type":"ready","session":"test","debug_retention":false}"#))
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
    func cancel(with code: URLSessionWebSocketTask.CloseCode) { input.finish() }
}

@Suite(.timeLimit(.minutes(1))) struct DictationStartTests {
    @Test func audioCapturedWhileTheSocketConnectsIsSentInOrderOnceItIsUp() async throws {
        let engine = FakeEngine()
        let mic = DictationMic(capture: AudioCapture(engine: engine))
        let socket = ConnectingSocket()
        let session = RollingDictationSession(correctionTimeout: 5, makeStream: {
            StreamSession(transport: socket, options: StartOptions())
        })
        try mic.open()
        mic.attach { frame, _ in session.sendAudio(frame) }
        await session.open()
        for _ in 0..<6 { engine.deliver(seconds: 0.5) }   // 3 s before the socket is up
        #expect(socket.audio.isEmpty)
        socket.connect()
        mic.close()
        await session.stop()
        for await _ in socket.stops { break }
        // Nothing was dropped while connecting: every frame, in order, then the trailing one `stop` flushes.
        let reference = try heard(Array(repeating: 0.5, count: 6))
        #expect(socket.audio.count >= reference.count + 640)
        #expect(socket.audio.prefix(reference.count) == reference)
        await session.close()
    }

    @Test func anAccidentalTapStillCancelsCleanly() async throws {
        var machine = DictationMachine(mode: .holdToTalk)
        let engine = FakeEngine()
        let mic = DictationMic(capture: AudioCapture(engine: engine))
        let socket = ConnectingSocket()
        socket.connect()
        let session = RollingDictationSession(correctionTimeout: 5, makeStream: {
            StreamSession(transport: socket, options: StartOptions())
        })
        #expect(machine.handle(.hotkeyDown(at: 0)) == [.start])
        try mic.open()   // at once: no cue wait
        mic.attach { frame, _ in session.sendAudio(frame) }
        await session.open()
        engine.deliver(seconds: 0.1)
        #expect(machine.handle(.hotkeyUp(at: 0.1)) == [.abort(DictationMachine.holdHint)])
        #expect(machine.state == .error(DictationMachine.holdHint))
        // The controller's teardown: microphone first, then the socket is told to discard.
        mic.close()
        await session.cancel()
        #expect(!mic.isOpen && engine.taps == 0)
        engine.deliver(seconds: 0.1)
        var finals = 0
        for await event in session.events { if case .message(.final) = event { finals += 1 } }
        #expect(finals == 0)
        #expect(!socket.sentTexts.contains { $0.contains("\"type\":\"stop\"") })
    }
}
