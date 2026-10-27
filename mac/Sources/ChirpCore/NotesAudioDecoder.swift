import AudioToolbox
import Foundation

/// Kept Notes audio (an AAC `.m4a` clip) back to what the server takes: 16 kHz mono PCM16, little-endian. Reads the
/// clip from memory through `AudioFileOpenWithCallbacks`, so a sealed clip (iOS) is opened and decoded without a
/// plaintext copy on disk; Core Audio drops the encoder's priming and resamples. Never logs.
public enum NotesAudioDecoder {
    public enum Failure: Error, Equatable { case unreadable(OSStatus), empty }

    /// The clip at `url`, opened with `codec` when the library seals its files.
    public static func decode(contentsOf url: URL, codec: NotesJournalCodec? = nil,
                              sampleRate: Double = PCMConverter.sampleRate) throws -> Data {
        let stored = try Data(contentsOf: url)
        return try decode(codec?.open(stored) ?? stored, sampleRate: sampleRate)
    }

    public static func decode(_ clip: Data, sampleRate: Double = PCMConverter.sampleRate) throws -> Data {
        guard !clip.isEmpty else { throw Failure.empty }
        let source = MemorySource(clip)
        let context = Unmanaged.passUnretained(source).toOpaque()
        var file: AudioFileID?
        var status = AudioFileOpenWithCallbacks(context, MemorySource.read, nil, MemorySource.size, nil,
                                                kAudioFileM4AType, &file)
        guard status == noErr, let file else { throw Failure.unreadable(status) }
        defer { AudioFileClose(file) }
        var ext: ExtAudioFileRef?
        status = ExtAudioFileWrapAudioFileID(file, false, &ext)
        guard status == noErr, let ext else { throw Failure.unreadable(status) }
        defer { ExtAudioFileDispose(ext) }
        var client = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16,
            mReserved: 0)
        status = ExtAudioFileSetProperty(ext, kExtAudioFileProperty_ClientDataFormat,
                                         UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
        guard status == noErr else { throw Failure.unreadable(status) }
        var pcm = Data()
        let chunk = 4096
        var buffer = [Int16](repeating: 0, count: chunk)
        while true {
            var frames = UInt32(chunk)
            let read: OSStatus = buffer.withUnsafeMutableBytes { bytes in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 1, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
                return ExtAudioFileRead(ext, &frames, &list)
            }
            guard read == noErr else { throw Failure.unreadable(read) }
            if frames == 0 { break }
            buffer.withUnsafeBytes { pcm.append(contentsOf: $0.prefix(Int(frames) * 2)) }
        }
        guard !pcm.isEmpty else { throw Failure.empty }
        return pcm
    }

    /// The clip's bytes for Core Audio's read callbacks; it lives for the whole decode.
    private final class MemorySource {
        let data: Data
        init(_ data: Data) { self.data = data }

        static let read: AudioFile_ReadProc = { context, position, count, buffer, actual in
            let source = Unmanaged<MemorySource>.fromOpaque(context).takeUnretainedValue()
            let total = Int64(source.data.count)
            guard position >= 0, position <= total else { actual.pointee = 0; return OSStatus(kAudioFilePositionError) }
            let n = Int(min(Int64(count), total - position))
            source.data.withUnsafeBytes { bytes in
                if n > 0 { memcpy(buffer, bytes.baseAddress! + Int(position), n) }
            }
            actual.pointee = UInt32(n)
            return noErr
        }

        static let size: AudioFile_GetSizeProc = { context in
            Int64(Unmanaged<MemorySource>.fromOpaque(context).takeUnretainedValue().data.count)
        }
    }
}
