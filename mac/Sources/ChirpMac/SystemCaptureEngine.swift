import AVFoundation
import ChirpCore

/// `AVAudioEngine` behind the `CaptureEngine` seam.
final class SystemCaptureEngine: CaptureEngine, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var observer: NSObjectProtocol?

    var inputFormat: AVAudioFormat? {
        let format = engine.inputNode.outputFormat(forBus: 0)
        return format.sampleRate > 0 && format.channelCount > 0 ? format : nil
    }

    func installTap(_ block: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { buffer, _ in block(buffer) }
    }

    func removeTap() { engine.inputNode.removeTap(onBus: 0) }
    func prepare() { engine.prepare() }
    func start() throws { try engine.start() }
    func stop() { engine.stop() }

    func setConfigurationChangeHandler(_ handler: (@Sendable () -> Void)?) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let handler else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { _ in handler() }
    }
}
