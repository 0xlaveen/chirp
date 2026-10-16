import CoreAudio
import Foundation

/// The system default input device, which `AVAudioEngine` follows.
enum InputDevice {
    private static var defaultInputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultName() -> String? {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = defaultInputAddress
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    /// Calls `handler` on the main queue whenever the default input device changes.
    static func observeChanges(_ handler: @escaping @Sendable () -> Void) {
        var address = defaultInputAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in
            handler()
        }
    }
}
