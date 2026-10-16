import AVFoundation
import ChirpCore

enum CaptureError: Error { case noInputDevice, converter }

/// Microphone → 16 kHz mono PCM16 frames. The engine instance is kept between dictations
/// (so it is ready), but the input is stopped when idle so the mic indicator goes off.
final class AudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var converter: PCMConverter?
    private var onFrame: (@Sendable (Data) -> Void)?
    private var observer: NSObjectProtocol?

    var isRunning: Bool { lock.withLock { onFrame != nil } }

    func start(onFrame: @escaping @Sendable (Data) -> Void) throws {
        lock.withLock { self.onFrame = onFrame }
        do { try install() } catch {
            lock.withLock { self.onFrame = nil }
            throw error
        }
        // A device change (e.g. unplugging the USB mic) stops the engine; rebuild on the new default input.
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.engine.inputNode.removeTap(onBus: 0)
            try? self.install()
        }
    }

    private func install() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInputDevice }
        guard let converter = PCMConverter(from: format) else { throw CaptureError.converter }
        lock.withLock { self.converter = converter }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let (conv, sink) = self.lock.withLock { (self.converter, self.onFrame) }
            guard let conv, let sink else { return }
            for frame in conv.frames(from: buffer) { sink(frame) }
        }
        engine.prepare()
        try engine.start()
    }

    /// Stops the input and delivers any trailing partial frame, padded to at least 20 ms.
    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let (conv, sink) = lock.withLock { () -> (PCMConverter?, (@Sendable (Data) -> Void)?) in
            let r = (converter, onFrame)
            onFrame = nil
            converter = nil
            return r
        }
        if var tail = conv?.flush(), let sink {
            if tail.count < 640 { tail.append(Data(count: 640 - tail.count)) }
            sink(tail)
        }
        engine.prepare()   // stay ready for the next dictation
    }
}
