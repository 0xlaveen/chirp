import ChirpCore
import CoreAudio
import Foundation

/// Input devices through Core Audio: the list for the menu, the system default, and the picked device's id.
enum InputDevice {
    struct Entry {
        let id: AudioObjectID
        let input: AudioInput
    }

    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultInputID() -> AudioObjectID? {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = address(kAudioHardwarePropertyDefaultInputDevice)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &id) == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func hasInput(_ id: AudioObjectID) -> Bool {
        var a = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    private static func entry(_ id: AudioObjectID) -> Entry? {
        guard let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        return Entry(id: id, input: AudioInput(uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid))
    }

    /// Every device that can record, in the system's order.
    static func all() -> [Entry] {
        var a = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter(hasInput).compactMap(entry)
    }

    static func systemDefault() -> Entry? { defaultInputID().flatMap(entry) }

    /// The Core Audio id of the picked device while it is connected; nil follows the system default.
    static func pickedID(uid: String?) -> AudioObjectID? {
        guard let uid else { return nil }
        return all().first { $0.input.uid == uid }?.id
    }

    /// Calls `handler` on the main queue when the default input or the device list changes.
    static func observeChanges(_ handler: @escaping @Sendable () -> Void) {
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
            var a = address(selector)
            AudioObjectAddPropertyListenerBlock(system, &a, .main) { _, _ in handler() }
        }
    }
}
