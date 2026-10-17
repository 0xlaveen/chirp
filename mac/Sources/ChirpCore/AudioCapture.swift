import AVFoundation
import Foundation

public enum CaptureError: Error { case noInputDevice, converter }

/// The microphone engine behind `AudioCapture`, so start-up failures can be tested without hardware or TCC.
public protocol CaptureEngine: AnyObject {
    /// The input's native format; nil when there is no input device (a 0 Hz or 0-channel format).
    var inputFormat: AVAudioFormat? { get }
    func installTap(_ block: @escaping @Sendable (AVAudioPCMBuffer) -> Void)
    func removeTap()
    func prepare()
    func start() throws
    func stop()
    /// Called when the default input changes (e.g. the USB mic is unplugged) and the engine has stopped.
    /// nil removes the handler.
    func setConfigurationChangeHandler(_ handler: (@Sendable () -> Void)?)
}

/// Microphone → 16 kHz mono PCM16 frames. The engine is kept between dictations (so it is ready), but the input is
/// stopped when idle so the mic indicator goes off. Every failure unwinds what was installed, so a retry starts clean.
public final class AudioCapture: @unchecked Sendable {
    private let engine: CaptureEngine
    private let lock = NSLock()
    private var converter: PCMConverter?
    private var onFrame: (@Sendable (Data) -> Void)?
    private var onFailure: (@Sendable () -> Void)?
    /// Tracked on its own: a failed start leaves a tap installed while `onFrame` is already cleared.
    private var tapInstalled = false

    public init(engine: CaptureEngine) { self.engine = engine }

    public var isRunning: Bool { lock.withLock { onFrame != nil } }

    /// Starts capturing. `onFailure` runs when the engine cannot be rebuilt after an input-device change.
    public func start(onFailure: (@Sendable () -> Void)? = nil, onFrame: @escaping @Sendable (Data) -> Void) throws {
        if isRunning { stop() }
        lock.withLock { self.onFrame = onFrame; self.onFailure = onFailure }
        do { try install() } catch {
            unwind()
            throw error
        }
        engine.setConfigurationChangeHandler { [weak self] in self?.rebuild() }
    }

    private func install() throws {
        guard let format = engine.inputFormat else { throw CaptureError.noInputDevice }
        guard let converter = PCMConverter(from: format) else { throw CaptureError.converter }
        lock.withLock { self.converter = converter; tapInstalled = true }
        engine.installTap { [weak self] buffer in
            guard let self else { return }
            let (conv, sink) = self.lock.withLock { (self.converter, self.onFrame) }
            guard let conv, let sink else { return }
            for frame in conv.frames(from: buffer) { sink(frame) }
        }
        engine.prepare()
        try engine.start()
    }

    /// The default input changed: rebuild on the new device, or give up cleanly.
    private func rebuild() {
        guard isRunning else { return }
        removeTapIfInstalled()
        do { try install() } catch {
            let failure = lock.withLock { onFailure }
            unwind()
            failure?()
        }
    }

    private func removeTapIfInstalled() {
        let installed = lock.withLock { () -> Bool in defer { tapInstalled = false }; return tapInstalled }
        if installed { engine.removeTap() }
    }

    /// Undoes a partial start: tap, engine, converter and callbacks. Safe to call in any state.
    private func unwind() {
        engine.setConfigurationChangeHandler(nil)
        removeTapIfInstalled()
        engine.stop()
        lock.withLock { converter = nil; onFrame = nil; onFailure = nil }
        engine.prepare()
    }

    /// Stops the input and delivers any trailing partial frame, padded to at least 20 ms. Idempotent.
    public func stop() {
        let (conv, sink, idle) = lock.withLock { (converter, onFrame, onFrame == nil && !tapInstalled) }
        if idle { return }
        unwind()
        if var tail = conv?.flush(), let sink {
            if tail.count < 640 { tail.append(Data(count: 640 - tail.count)) }
            sink(tail)
        }
    }
}
