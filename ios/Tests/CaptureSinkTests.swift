import AVFoundation
import ChirpCore
import Foundation
import Testing
@testable import ChirpIOS

@Suite("Bounded capture sink")
struct CaptureSinkTests {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func add() { lock.withLock { value += 1 } }
    }
    func buffer(samples: UInt32 = 1600) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let value = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: samples))
        value.frameLength = samples
        if let data = value.floatChannelData?[0] { for i in 0..<Int(samples) { data[i] = 0.1 } }
        return value
    }
    func binaryBytes(_ transport: SyntheticTransport) -> Int {
        transport.sent.reduce(0) { sum, message in if case .data(let data) = message { sum + data.count } else { sum } }
    }

    /// Regression: on device, AVAudioEngine runs taps on its realtime thread. A main-actor-isolated tap
    /// trapped in Swift 6's runtime isolation check as soon as a session armed the microphone.
    @Test func microphoneTapRunsOffTheMainActor() async throws {
        let transport = SyntheticTransport(), session = StreamSession(transport: transport, options: StartOptions())
        let sink = CaptureSink(), input = try buffer()
        sink.configure(format: input.format)
        await session.open()
        try sink.begin(session, onFailure: {}, onLimit: {})
        sink.ready()
        let tap = MicrophoneCapture.tap(sink)
        let time = AVAudioTime(sampleTime: 0, atRate: 16_000)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue(label: "dev.chirp.tests.realtime").async { tap(input, time); done.resume() }
        }
        #expect(binaryBytes(transport) > 0)
        await session.stop()
    }

    @Test func idleDiscardsAndReadyPrecedesAllAudioIncludingFlush() async throws {
        let transport = SyntheticTransport(), session = StreamSession(transport: transport, options: StartOptions())
        let sink = CaptureSink(), input = try buffer()
        let failures = Counter()
        sink.configure(format: input.format)
        sink.receive(input) // Armed idle audio has no destination and cannot enqueue.
        #expect(binaryBytes(transport) == 0)
        await session.open()
        try sink.begin(session, onFailure: { failures.add() }, onLimit: {})
        sink.receive(input)
        #expect(binaryBytes(transport) == 0)
        sink.finish() // Stop before ready must retain the converter tail in the same bounded gate.
        sink.ready()
        await session.stop()
        #expect(binaryBytes(transport) >= 3200)
        #expect(failures.count == 0)
        let messages = transport.sent
        if let last = messages.last, case .string(let value) = last { #expect(value == ClientMessage.stop) }
        else { Issue.record("Stop must follow every PCM frame") }
        await session.close()
    }

    @Test func preReadyOverflowFailsWithoutTransmittingAudio() async throws {
        let transport = SyntheticTransport(), session = StreamSession(transport: transport, options: StartOptions())
        let sink = CaptureSink(), input = try buffer(samples: 40_000), failures = Counter()
        sink.configure(format: input.format)
        try sink.begin(session, onFailure: { failures.add() }, onLimit: {})
        sink.receive(input)
        sink.ready()
        #expect(failures.count >= 1)
        #expect(binaryBytes(transport) == 0)
        sink.discard(); await session.close()
    }

    @Test func longSyntheticCaptureStopsBelowHardProtocolBound() async throws {
        let transport = SyntheticTransport(), session = StreamSession(transport: transport, options: StartOptions())
        let sink = CaptureSink(), input = try buffer(), failures = Counter(), limits = Counter()
        sink.configure(format: input.format)
        await session.open(); try sink.begin(session, onFailure: { failures.add() }, onLimit: { limits.add() }); sink.ready()
        for _ in 0..<1300 { sink.receive(input); await Task.yield() }
        sink.finish(); await session.stop()
        #expect(limits.count == 1)
        #expect(failures.count == 0)
        #expect(binaryBytes(transport) <= 120 * 32_000)
        #expect(binaryBytes(transport) >= 119 * 32_000)
        await session.close()
    }
}
