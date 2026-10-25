import AVFoundation
import AppKit
import ChirpCore
import CoreAudio
import CoreMedia
import ScreenCaptureKit

/// Live Notes call audio on the Mac (#211): a Core Audio process tap of everything the Mac plays (except Chirp's own
/// sounds) or of one app, read through a private aggregate device; ScreenCaptureKit audio-only capture when no tap
/// can be made. Both need Screen & System Audio Recording; macOS asks the first time. Nothing here is logged except
/// OSStatus codes.
enum CallAudio {
    /// The app's tap: process taps first, then ScreenCaptureKit.
    static func makeTap() -> SystemAudioTap { FallbackAudioTap([ProcessAudioTap(), ScreenCaptureAudioTap()]) }

    /// Apps whose audio can be recorded on their own: running, regular apps that already have an audio process
    /// (a call app does once it joins), and every running call app.
    static func apps() -> [CallAudioApp] {
        let audio = Set(AudioProcesses.all().compactMap(\.bundleID))
        let own = Bundle.main.bundleIdentifier
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> CallAudioApp? in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, id != own else { return nil }
            let known = CallAudioApp.knownCallApps.contains(id)
            guard known || audio.contains(where: { AudioProcesses.matches($0, app: id) }) else { return nil }
            return CallAudioApp(bundleID: id, name: app.localizedName ?? id)
        }
        return CallAudioApp.sorted(apps)
    }
}

/// Core Audio's process objects: who plays audio, by bundle id and pid.
enum AudioProcesses {
    struct Process {
        let id: AudioObjectID
        let bundleID: String?
        let pid: pid_t
    }

    /// Processes some apps play through: a browser's helpers share its bundle id prefix; Safari and FaceTime play
    /// through system processes.
    static let aliases: [String: [String]] = [
        "com.apple.Safari": ["com.apple.WebKit.GPU", "com.apple.WebKit.WebContent"],
        "com.apple.FaceTime": ["com.apple.avconferenced"],
    ]

    static func matches(_ processBundle: String, app: String) -> Bool {
        processBundle == app || processBundle.hasPrefix(app + ".") || (aliases[app] ?? []).contains(processBundle)
    }

    static func all() -> [Process] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map { Process(id: $0, bundleID: string($0, kAudioProcessPropertyBundleID), pid: pid($0)) }
    }

    /// The process objects of `app` (and its helpers).
    static func objects(for app: String) -> [AudioObjectID] {
        all().filter { $0.bundleID.map { matches($0, app: app) } ?? false }.map(\.id)
    }

    /// This process's object, if it has played audio (the start and stop sounds).
    static func object(pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid = pid
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &id)
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        let s = value.takeRetainedValue() as String
        return s.isEmpty ? nil : s
    }

    private static func pid(_ object: AudioObjectID) -> pid_t {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        _ = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pid)
        return pid
    }
}

/// A Core Audio process tap (macOS 14.2+) read through a private, tap-only aggregate device. Everything the Mac plays
/// except Chirp itself, or one app's processes. The tap is unmuted, so the call still plays as usual.
final class ProcessAudioTap: SystemAudioTap, @unchecked Sendable {
    let kind = CallAudioKind.processTap
    private let lock = NSLock()
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "chirp.notes.call-audio", qos: .userInitiated)

    func start(app: CallAudioApp?, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        stop()
        let description: CATapDescription
        if let app {
            let processes = AudioProcesses.objects(for: app.bundleID)
            guard !processes.isEmpty else { throw CallAudioError.noSource }
            description = CATapDescription(stereoMixdownOfProcesses: processes)
        } else {
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: AudioProcesses.object(pid: getpid()).map { [$0] } ?? [])
        }
        description.uuid = UUID()
        description.name = "Chirp call audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else { throw CallAudioError.unavailable("tap \(status)") }
        lock.withLock { tap = tapID }
        do {
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
            guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
                throw CallAudioError.unavailable("format \(status)")
            }
            let settings: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Chirp call audio",
                kAudioAggregateDeviceUIDKey: "chirp.notes.call-audio.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]],
            ]
            var aggregateID = AudioObjectID(kAudioObjectUnknown)
            status = AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregateID)
            guard status == noErr, aggregateID != kAudioObjectUnknown else { throw CallAudioError.unavailable("aggregate \(status)") }
            lock.withLock { aggregate = aggregateID }
            var procID: AudioDeviceIOProcID?
            status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
                // The buffer list is only valid in this call: the capture converts it before returning.
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
                onBuffer(buffer)
            }
            guard status == noErr, let procID else { throw CallAudioError.unavailable("ioproc \(status)") }
            lock.withLock { proc = procID }
            status = AudioDeviceStart(aggregateID, procID)
            guard status == noErr else { throw CallAudioError.unavailable("start \(status)") }
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        let (tapID, aggregateID, procID) = lock.withLock { () -> (AudioObjectID, AudioObjectID, AudioDeviceIOProcID?) in
            defer { tap = AudioObjectID(kAudioObjectUnknown); aggregate = AudioObjectID(kAudioObjectUnknown); proc = nil }
            return (tap, aggregate, proc)
        }
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
    }
}

/// ScreenCaptureKit audio-only capture: the fallback when no process tap can be made. It needs Screen & System Audio
/// Recording up front (asked here once); the stream starts in the background, and a failure there leaves the call
/// silent, which the session reports.
final class ScreenCaptureAudioTap: NSObject, SystemAudioTap, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let kind = CallAudioKind.screenCapture
    private let lock = NSLock()
    private var stream: SCStream?
    private var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var generation = 0
    private let queue = DispatchQueue(label: "chirp.notes.call-audio.sck", qos: .userInitiated)

    func start(app: CallAudioApp?, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        stop()
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            throw CallAudioError.unavailable("screen capture not allowed")
        }
        let mine = lock.withLock { () -> Int in
            generation += 1
            self.onBuffer = onBuffer
            return generation
        }
        Task { [weak self] in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                guard let self, let display = content.displays.first else { return }
                let filter: SCContentFilter
                if let app {
                    let apps = content.applications.filter { AudioProcesses.matches($0.bundleIdentifier, app: app.bundleID) }
                    filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
                } else {
                    let own = content.applications.filter { $0.processID == getpid() }
                    filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
                }
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = 48_000
                config.channelCount = 1
                // Audio only: the smallest, slowest video the stream allows.
                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.queue)
                guard self.lock.withLock({ self.generation == mine && self.onBuffer != nil }) else { return }
                try await stream.startCapture()
                let current = self.lock.withLock { () -> Bool in
                    guard self.generation == mine else { return false }
                    self.stream = stream
                    return true
                }
                if !current { try? await stream.stopCapture() }
            } catch {
                chirpLog.error("notes call audio screen-capture failed code=\((error as NSError).code, privacy: .public)")
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let sink = lock.withLock({ onBuffer }),
              var asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &asbd) else { return }
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                                                                  into: buffer.mutableAudioBufferList)
        guard status == noErr else { return }
        sink(buffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        chirpLog.error("notes call audio screen-capture stopped code=\((error as NSError).code, privacy: .public)")
    }

    func stop() {
        let stream = lock.withLock { () -> SCStream? in
            defer { self.stream = nil; onBuffer = nil; generation += 1 }
            return self.stream
        }
        if let stream { Task { try? await stream.stopCapture() } }
    }
}
