import AVFoundation
import ChirpCore
import CoreAudio

/// `AVAudioEngine` behind the `CaptureEngine` seam.
final class SystemCaptureEngine: CaptureEngine, @unchecked Sendable {
    private var engine = AVAudioEngine()
    private var observer: NSObjectProtocol?
    private var onConfigurationChange: (@Sendable () -> Void)?
    /// The device the user picked (nil follows the system default input), read at every (re)start so a
    /// device that was unplugged falls back to the default.
    private let pickedDevice: @Sendable () -> AudioObjectID?
    /// The device the input unit is pinned to; nil while it follows the system default.
    private var pinned: AudioObjectID?

    init(pickedDevice: @escaping @Sendable () -> AudioObjectID? = { nil }) { self.pickedDevice = pickedDevice }

    var inputFormat: AVAudioFormat? {
        applyPickedDevice()
        let format = engine.inputNode.outputFormat(forBus: 0)
        return format.sampleRate > 0 && format.channelCount > 0 ? format : nil
    }

    /// Pins the input unit to the picked device. Going back to the default needs a fresh engine, because a unit
    /// bound to a device no longer follows the system default.
    private func applyPickedDevice() {
        let wanted = pickedDevice()
        guard wanted != pinned else { return }
        if let wanted {
            do { try engine.inputNode.auAudioUnit.setDeviceID(wanted) } catch {
                chirpLog.error("input device pin failed status=\((error as NSError).code, privacy: .public)")
                return
            }
        } else {
            engine = AVAudioEngine()
            observe()
        }
        pinned = wanted
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
        onConfigurationChange = handler
        observe()
    }

    private func observe() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let handler = onConfigurationChange else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { _ in handler() }
    }
}
