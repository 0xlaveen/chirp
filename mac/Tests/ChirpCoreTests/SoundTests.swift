import AVFoundation
import AppKit
import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

// MARK: preferences and pack selection

@Suite struct SoundPreferencesTests {
    private func prefs() throws -> (Preferences, UserDefaults, String) {
        let suite = "chirp-sound-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (Preferences(defaults: defaults), defaults, suite)
    }

    @Test func aFreshInstallIsOffWithTheChirpPackAtSixtyPercent() throws {
        let (p, defaults, suite) = try prefs()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(p.soundsEnabled == false && p.soundPack == .chirp && p.soundVolume == 0.6)
        #expect(p.customStartSound == nil && p.customStopSound == nil)
    }

    @Test func packVolumeAndCustomFilesPersist() throws {
        let (p, defaults, suite) = try prefs()
        defer { defaults.removePersistentDomain(forName: suite) }
        p.soundPack = .glass
        p.soundVolume = 0.25
        let start = CustomSound(fileName: "custom-start-ab12cd34.m4a", displayName: "chime.m4a", duration: 0.8)
        p.customStartSound = start
        let again = Preferences(defaults: defaults)
        #expect(again.soundPack == .glass && again.soundVolume == 0.25 && again.customStartSound == start)
        #expect(again.customSound(for: .start) == start && again.customSound(for: .stop) == nil)
        p.customStartSound = nil
        #expect(Preferences(defaults: defaults).customStartSound == nil)
    }

    @Test func unknownOrCorruptValuesFallBackToTheDefaults() throws {
        let (p, defaults, suite) = try prefs()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("marimba-9000", forKey: "soundPack")
        defaults.set(7.5, forKey: "soundVolume")
        defaults.set(Data("not json".utf8), forKey: "customStartSound")
        #expect(p.soundPack == .chirp && p.soundVolume == 1 && p.customStartSound == nil)
        p.soundVolume = -3
        #expect(p.soundVolume == 0)
        p.soundVolume = .nan
        #expect(p.soundVolume == 0.6)
    }

    @Test func eachPackHasAStartAndStopFileExceptSystemAndCustom() {
        for pack in SoundPack.builtIn where pack != .system {
            #expect(pack.resourceName(for: .start) == "\(pack.rawValue)-start" && pack.resourceName(for: .stop) == "\(pack.rawValue)-stop")
        }
        #expect(SoundPack.system.resourceName(for: .start) == nil && SoundPack.custom.resourceName(for: .stop) == nil)
        #expect(SoundPack.default == .chirp)
    }
}

// MARK: timing and volume

@Suite struct SoundTimingTests {
    @Test func theMicWaitsForTheCuePlusTwentyMillisecondsButNeverOverThreeHundred() {
        #expect(abs(SoundTiming.micDelay(cueDuration: 0.12) - 0.14) < 1e-9)
        #expect(abs(SoundTiming.micDelay(cueDuration: 0.25) - 0.27) < 1e-9)
        #expect(SoundTiming.micDelay(cueDuration: 0.28) == 0.3)
        #expect(SoundTiming.micDelay(cueDuration: 0.3) == 0.3)
        #expect(SoundTiming.micDelay(cueDuration: 4) == 0.3)
        #expect(abs(SoundTiming.micDelay(cueDuration: 0) - 0.02) < 1e-9)
        #expect(abs(SoundTiming.micDelay(cueDuration: -1) - 0.02) < 1e-9)
    }

    @Test func aLongStartCueIsTrimmedToThreeHundredMillisecondsWithAFade() {
        #expect(SoundTiming.playLength(.start, duration: 0.12) == 0.12)
        #expect(SoundTiming.playLength(.start, duration: 0.3) == 0.3)
        #expect(SoundTiming.playLength(.start, duration: 1.2) == 0.3)
        #expect(SoundTiming.isTrimmed(.start, duration: 1.2) && !SoundTiming.isTrimmed(.start, duration: 0.3) && !SoundTiming.isTrimmed(.start, duration: 0.12))
        #expect(SoundTiming.fadeOut(.start, duration: 1.2, custom: true) == SoundTiming.trimFade)
        #expect(SoundTiming.fadeOut(.start, duration: 1.2, custom: false) == SoundTiming.trimFade)   // Tink is cut too
        #expect(SoundTiming.fadeOut(.start, duration: 0.12, custom: false) == 0)                      // built-ins carry their own fade
        #expect(SoundTiming.fadeOut(.start, duration: 0.12, custom: true) == SoundTiming.endFade)    // a custom file gets a short one
        #expect(SoundTiming.fadeOut(.start, duration: 0.01, custom: true) == 0.005)                   // never longer than half the cue
    }

    @Test func theStopCueIsNotLimitedByTheMicButCapsAtOneAndAHalfSeconds() {
        #expect(SoundTiming.playLength(.stop, duration: 0.9) == 0.9)
        #expect(SoundTiming.playLength(.stop, duration: 1.5) == 1.5)
        #expect(SoundTiming.playLength(.stop, duration: 10) == 1.5)
        #expect(SoundTiming.isTrimmed(.stop, duration: 10) && !SoundTiming.isTrimmed(.stop, duration: 0.9))
    }

    @Test func theWarningNamesTheRule() {
        #expect(SoundTiming.longStartWarning == "Long start sounds are trimmed to 0.3 s so they aren't recorded.")
    }

    @Test func volumeMapsFromTheSliderToAGain() {
        #expect(SoundTiming.gain(volume: 0) == 0 && SoundTiming.gain(volume: 1) == 1)
        #expect(SoundTiming.gain(volume: -1) == 0 && SoundTiming.gain(volume: 9) == 1)
        let steps = stride(from: 0.0, through: 1.0, by: 0.05).map { SoundTiming.gain(volume: $0) }
        #expect(zip(steps, steps.dropFirst()).allSatisfy { $0 < $1 })   // strictly increasing
        #expect(abs(SoundTiming.gain(volume: 0.6) - 0.4648) < 0.001)
        #expect(SoundTiming.percent(volume: 0.6) == 60 && SoundTiming.percent(volume: 1.3) == 100 && SoundTiming.percent(volume: 0) == 0)
    }

    @Test func durationsReadAsSeconds() {
        #expect(SoundTiming.durationText(0.42) == "0.42 s" && SoundTiming.durationText(12.34) == "12.3 s")
    }
}

// MARK: custom-file import (injected file system)

/// An in-memory disk: files with a size and a duration (nil = not audio).
final class FakeSoundFS: SoundFileSystem, @unchecked Sendable {
    struct File { var size: Int; var duration: TimeInterval? }
    private let lock = NSLock()
    private var files: [URL: File]
    private(set) var directories: Set<URL> = []
    var failCopy = false

    init(_ files: [URL: File] = [:]) { self.files = files }

    var paths: Set<String> { lock.withLock { Set(files.keys.map(\.path)) } }
    func add(_ url: URL, size: Int = 1000, duration: TimeInterval?) { lock.withLock { files[url] = File(size: size, duration: duration) } }
    func fileExists(at url: URL) -> Bool { lock.withLock { files[url] != nil } }
    func fileSize(at url: URL) -> Int? { lock.withLock { files[url]?.size } }
    func createDirectory(at url: URL) throws { lock.withLock { _ = directories.insert(url) } }
    func copyItem(at source: URL, to destination: URL) throws {
        try lock.withLock {
            if failCopy { throw CocoaError(.fileWriteOutOfSpace) }
            guard let f = files[source] else { throw CocoaError(.fileNoSuchFile) }
            files[destination] = f
        }
    }
    func removeItem(at url: URL) throws { _ = lock.withLock { files.removeValue(forKey: url) } }
    func audioDuration(at url: URL) throws -> TimeInterval {
        guard let d = lock.withLock({ files[url]?.duration }) else { throw CocoaError(.fileReadCorruptFile) }
        return d
    }
}

@Suite struct CustomSoundImportTests {
    let dir = URL(fileURLWithPath: "/Users/x/Library/Application Support/Chirp/Sounds", isDirectory: true)
    let downloads = URL(fileURLWithPath: "/Users/x/Downloads", isDirectory: true)

    private func store(_ fs: FakeSoundFS) -> CustomSoundStore {
        let counter = Counter()
        return CustomSoundStore(directory: dir, fs: fs, makeID: { "id\(counter.next())" })
    }
    final class Counter: @unchecked Sendable { private var n = 0; func next() -> Int { n += 1; return n } }

    @Test func copiesTheFileIntoApplicationSupportAndKeepsItsNameAndLength() throws {
        let original = downloads.appendingPathComponent("My Chime.M4A")
        let fs = FakeSoundFS([original: .init(size: 5000, duration: 0.84)])
        let sound = try store(fs).importFile(from: original, cue: .start)
        #expect(sound.displayName == "My Chime.M4A" && sound.duration == 0.84)
        #expect(sound.fileName == "custom-start-id1.m4a")   // a lower-case, sanitised extension
        #expect(fs.directories == [dir])
        #expect(fs.paths.contains(dir.appendingPathComponent(sound.fileName).path))
    }

    @Test func movingOrDeletingTheOriginalDoesNotBreakTheCopy() throws {
        let original = downloads.appendingPathComponent("ding.wav")
        let fs = FakeSoundFS([original: .init(size: 900, duration: 0.2)])
        let s = store(fs)
        let sound = try s.importFile(from: original, cue: .stop)
        try fs.removeItem(at: original)
        let library = SoundLibrary(bundled: nil, store: s, fs: fs, system: dir)
        let resolved = try #require(library.resolve(.stop, pack: .custom, custom: sound))
        #expect(resolved.url == s.url(for: sound) && resolved.isCustom && resolved.duration == 0.2)
    }

    @Test func replacingASoundRemovesTheOldCopy() throws {
        let a = downloads.appendingPathComponent("a.wav"), b = downloads.appendingPathComponent("b.mp3")
        let fs = FakeSoundFS([a: .init(size: 100, duration: 0.1), b: .init(size: 100, duration: 0.2)])
        let s = store(fs)
        let first = try s.importFile(from: a, cue: .start)
        let second = try s.importFile(from: b, cue: .start, replacing: first)
        #expect(!fs.paths.contains(s.url(for: first).path) && fs.paths.contains(s.url(for: second).path))
        s.remove(second)
        #expect(!fs.paths.contains(s.url(for: second).path))
        s.remove(nil)   // nothing to remove is fine
    }

    @Test func aFileThatIsNotAudioImportsNothing() {
        let junk = downloads.appendingPathComponent("notes.txt")
        let fs = FakeSoundFS([junk: .init(size: 10, duration: nil)])
        #expect(throws: CustomSoundStore.ImportError.unreadable) { try store(fs).importFile(from: junk, cue: .start) }
        #expect(fs.paths == [junk.path])   // no stray copy
        let empty = downloads.appendingPathComponent("silence.wav")
        fs.add(empty, duration: 0)
        #expect(throws: CustomSoundStore.ImportError.unreadable) { try store(fs).importFile(from: empty, cue: .start) }
    }

    @Test func aMissingOrHugeFileIsRefused() {
        let fs = FakeSoundFS()
        #expect(throws: CustomSoundStore.ImportError.missing) { try store(fs).importFile(from: downloads.appendingPathComponent("gone.wav"), cue: .stop) }
        let big = downloads.appendingPathComponent("album.wav")
        fs.add(big, size: CustomSoundStore.maxBytes + 1, duration: 300)
        #expect(throws: CustomSoundStore.ImportError.tooBig) { try store(fs).importFile(from: big, cue: .stop) }
    }

    @Test func aFailedCopyReportsWhyAndKeepsTheOldSound() {
        let a = downloads.appendingPathComponent("a.wav")
        let fs = FakeSoundFS([a: .init(size: 100, duration: 0.1)])
        fs.failCopy = true
        do {
            _ = try store(fs).importFile(from: a, cue: .start)
            Issue.record("expected a copy failure")
        } catch let error as CustomSoundStore.ImportError {
            guard case .copyFailed = error else { Issue.record("wrong error \(error)"); return }
            #expect(error.errorDescription?.hasPrefix("Couldn't copy") == true)
        } catch { Issue.record("wrong error \(error)") }
    }

    @Test func theExtensionIsSanitised() {
        #expect(CustomSoundStore.cleanExtension("MP3") == "mp3" && CustomSoundStore.cleanExtension("") == "audio")
        #expect(CustomSoundStore.cleanExtension("a/../b") == "ab" && CustomSoundStore.cleanExtension("m4a 2") == "m4a2")
        #expect(CustomSoundStore.cleanExtension("verylongextension") == "veryl")
    }

    @Test func aLongCustomStartPlaysOnlyThreeHundredMillisecondsAndTheMicWaitsForThat() throws {
        let long = downloads.appendingPathComponent("long.m4a"), longStop = downloads.appendingPathComponent("long-stop.m4a")
        let fs = FakeSoundFS([long: .init(size: 9000, duration: 1.2), longStop: .init(size: 9000, duration: 3.0)])
        let s = store(fs)
        let library = SoundLibrary(bundled: nil, store: s, fs: fs, system: dir)
        let start = try library.resolve(.start, pack: .custom, custom: s.importFile(from: long, cue: .start))
        let r = try #require(start)
        #expect(r.duration == 1.2 && r.playLength == 0.3 && r.isTrimmed && r.fadeOut == SoundTiming.trimFade && r.micDelay == 0.3)
        let stop = try #require(try library.resolve(.stop, pack: .custom, custom: s.importFile(from: longStop, cue: .stop)))
        #expect(stop.playLength == 1.5 && stop.micDelay == 0)
    }

    @Test func aShortCustomStartDelaysTheMicByItsLengthPlusTwentyMilliseconds() throws {
        let tap = downloads.appendingPathComponent("tap.wav")
        let fs = FakeSoundFS([tap: .init(size: 900, duration: 0.15)])
        let s = store(fs)
        let library = SoundLibrary(bundled: nil, store: s, fs: fs, system: dir)
        let r = try #require(library.resolve(.start, pack: .custom, custom: try s.importFile(from: tap, cue: .start)))
        #expect(!r.isTrimmed && abs(r.micDelay - 0.17) < 1e-9)
    }
}

// MARK: finding the files, and the fallbacks

@Suite struct SoundLibraryTests {
    let bundle = URL(fileURLWithPath: "/App/Contents/Resources/Sounds", isDirectory: true)
    let system = URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true)
    let support = URL(fileURLWithPath: "/Support/Sounds", isDirectory: true)

    private func library(_ fs: FakeSoundFS, bundled: URL? = nil) -> SoundLibrary {
        SoundLibrary(bundled: bundled ?? bundle, store: CustomSoundStore(directory: support, fs: fs), fs: fs, system: system)
    }
    private func disk() -> FakeSoundFS {
        let fs = FakeSoundFS()
        for pack in ["chirp", "soft", "glass", "click"] {
            fs.add(bundle.appendingPathComponent("\(pack)-start.wav"), duration: 0.12)
            fs.add(bundle.appendingPathComponent("\(pack)-stop.wav"), duration: 0.14)
        }
        fs.add(system.appendingPathComponent("Tink.aiff"), duration: 0.614)
        fs.add(system.appendingPathComponent("Pop.aiff"), duration: 1.77)
        return fs
    }

    @Test func eachPackResolvesToItsBundledFiles() throws {
        let lib = library(disk())
        for pack in [SoundPack.chirp, .soft, .glass, .click] {
            #expect(try #require(lib.resolve(.start, pack: pack, custom: nil)).url == bundle.appendingPathComponent("\(pack.rawValue)-start.wav"))
            #expect(try #require(lib.resolve(.stop, pack: pack, custom: nil)).url == bundle.appendingPathComponent("\(pack.rawValue)-stop.wav"))
        }
        let start = try #require(lib.resolve(.start, pack: .chirp, custom: nil))
        #expect(abs(start.micDelay - 0.14) < 1e-9 && start.fadeOut == 0 && !start.isCustom && start.trim == 1)
    }

    @Test func theSystemPackIsTinkAndPopAndTinkIsCutAtThreeHundredMilliseconds() throws {
        let lib = library(disk())
        let tink = try #require(lib.resolve(.start, pack: .system, custom: nil))
        #expect(tink.url == system.appendingPathComponent("Tink.aiff") && tink.playLength == 0.3 && tink.micDelay == 0.3 && tink.trim == 0.55)
        let pop = try #require(lib.resolve(.stop, pack: .system, custom: nil))
        #expect(pop.url == system.appendingPathComponent("Pop.aiff") && pop.playLength == 1.5 && pop.trim == 0.85)
    }

    @Test func aMissingBundledFileFallsBackToTheSystemSound() throws {
        let fs = disk()
        try fs.removeItem(at: bundle.appendingPathComponent("chirp-start.wav"))
        let r = try #require(library(fs).resolve(.start, pack: .chirp, custom: nil))
        #expect(r.url == system.appendingPathComponent("Tink.aiff") && r.trim == 0.55)
        // No bundle at all (swift run): the same.
        let none = SoundLibrary(bundled: nil, store: CustomSoundStore(directory: support, fs: fs), fs: fs, system: system)
        #expect(none.resolve(.stop, pack: .glass, custom: nil)?.url == system.appendingPathComponent("Pop.aiff"))
    }

    @Test func aMissingCustomFileFallsBackToTheDefaultPackAndThenToSilence() throws {
        let fs = disk()
        let ghost = CustomSound(fileName: "custom-start-dead.m4a", displayName: "x.m4a", duration: 1)
        #expect(library(fs).resolve(.start, pack: .custom, custom: ghost)?.url == bundle.appendingPathComponent("chirp-start.wav"))
        #expect(library(fs).resolve(.stop, pack: .custom, custom: nil)?.url == bundle.appendingPathComponent("chirp-stop.wav"))   // only a start file chosen
        let bare = FakeSoundFS()
        #expect(library(bare).resolve(.start, pack: .chirp, custom: nil) == nil)
    }

    @Test func aCorruptBundledFileIsTreatedAsMissing() throws {
        let fs = disk()
        fs.add(bundle.appendingPathComponent("soft-start.wav"), duration: nil)
        #expect(library(fs).resolve(.start, pack: .soft, custom: nil)?.url == system.appendingPathComponent("Tink.aiff"))
    }

    @Test func theStockSoundsAreTrimmedBelowMinusTwelveDecibels() throws {
        for (cue, name) in [(SoundCue.start, "Tink"), (.stop, "Pop")] {
            let url = system.appendingPathComponent("\(name).aiff")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let file = try AVAudioFile(forReading: url)
            let buf = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buf)
            let data = try #require(buf.floatChannelData)
            var peak: Float = 0
            for ch in 0..<Int(buf.format.channelCount) { for i in 0..<Int(buf.frameLength) { peak = max(peak, abs(data[ch][i])) } }
            let trimmed = Double(peak) * SoundPack.system.levelTrim(for: cue)
            #expect(20 * log10(trimmed) <= -12, "\(name) peaks at \(20 * log10(trimmed)) dBFS after its trim")
        }
    }
}

// MARK: the generated packs

/// Runs `scripts/make-sounds.swift` into a temporary folder (it is deterministic) and reads the WAVs back.
struct GeneratedSounds {
    struct Wav {
        let sampleRate: Int, channels: Int, bits: Int, samples: [Double], bytes: Int
        var duration: Double { Double(samples.count) / Double(sampleRate) }
        var peak: Double { samples.map { abs($0) }.max() ?? 0 }
        var peakDB: Double { 20 * log10(peak) }
        func rms(from: Double, to: Double) -> Double {
            let a = max(0, Int(from * Double(sampleRate))), b = min(samples.count, Int(to * Double(sampleRate)))
            guard b > a else { return 0 }
            return (samples[a..<b].reduce(0) { $0 + $1 * $1 } / Double(b - a)).squareRoot()
        }
        /// The loudest 30 ms (unweighted RMS, dB).
        var loudest30msDB: Double {
            let w = Int(0.03 * Double(sampleRate))
            var best = 0.0
            var i = 0
            while i + w <= samples.count { best = max(best, samples[i..<i + w].reduce(0) { $0 + $1 * $1 } / Double(w)); i += 16 }
            return 10 * log10(best)
        }
        func zeroCrossingHz(from: Double, to: Double) -> Double {
            let a = Int(from * Double(sampleRate)), b = Int(to * Double(sampleRate))
            var n = 0
            for i in (a + 1)..<b where (samples[i - 1] < 0) != (samples[i] < 0) { n += 1 }
            return Double(n) / 2 / (Double(b - a) / Double(sampleRate))
        }
        /// Energy at `hz` in a window (Goertzel).
        func energy(at hz: Double, from: Double, to: Double) -> Double {
            let a = Int(from * Double(sampleRate)), b = min(samples.count, Int(to * Double(sampleRate)))
            var re = 0.0, im = 0.0
            for i in a..<b {
                let ph = 2 * Double.pi * hz * Double(i) / Double(sampleRate)
                re += samples[i] * cos(ph); im -= samples[i] * sin(ph)
            }
            return re * re + im * im
        }
    }

    static let macDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let committed = macDirectory.appendingPathComponent("Assets/Sounds", isDirectory: true)
    static let names = ["chirp", "soft", "glass", "click"].flatMap { ["\($0)-start", "\($0)-stop"] }

    static func read(_ url: URL) throws -> Wav {
        let d = try Data(contentsOf: url)
        func u32(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 | Int(d[o + 2]) << 16 | Int(d[o + 3]) << 24 }
        func u16(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 }
        #expect(String(decoding: d[0..<4], as: UTF8.self) == "RIFF" && String(decoding: d[8..<12], as: UTF8.self) == "WAVE")
        #expect(u16(20) == 1)   // PCM
        let count = u32(40) / 2
        var out: [Double] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let v = Int16(bitPattern: UInt16(u16(44 + i * 2)))
            out.append(Double(v) / 32768)
        }
        return Wav(sampleRate: u32(24), channels: u16(22), bits: u16(34), samples: out, bytes: d.count)
    }

    /// Runs the generator once (cached) and returns the folder it wrote.
    static let regenerated: URL? = {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-sounds-\(UUID().uuidString)", isDirectory: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["swift", macDirectory.appendingPathComponent("scripts/make-sounds.swift").path, "--out", out.path]
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        return p.terminationStatus == 0 ? out : nil
    }()
}

@Suite struct GeneratedSoundTests {
    private func wavs(in dir: URL) throws -> [String: GeneratedSounds.Wav] {
        var out: [String: GeneratedSounds.Wav] = [:]
        for name in GeneratedSounds.names { out[name] = try GeneratedSounds.read(dir.appendingPathComponent("\(name).wav")) }
        return out
    }

    @Test func theCommittedFilesAreWhatTheGeneratorWrites() throws {
        let fresh = try #require(GeneratedSounds.regenerated, "make-sounds.swift failed to run")
        for name in GeneratedSounds.names {
            let a = try GeneratedSounds.read(GeneratedSounds.committed.appendingPathComponent("\(name).wav"))
            let b = try GeneratedSounds.read(fresh.appendingPathComponent("\(name).wav"))
            #expect(a.samples.count == b.samples.count, "\(name) length")
            // 16-bit samples: a different libm may round a sample by one step, so allow two.
            let worst = zip(a.samples, b.samples).map { abs($0 - $1) }.max() ?? 1
            #expect(worst <= 2.0 / 32768, "\(name) differs from the generator by \(worst * 32768) steps; rerun scripts/make-sounds.swift")
        }
    }

    @Test func theGeneratorIsDeterministic() throws {
        let one = try #require(GeneratedSounds.regenerated)
        let two = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-sounds-\(UUID().uuidString)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["swift", GeneratedSounds.macDirectory.appendingPathComponent("scripts/make-sounds.swift").path, "--out", two.path]
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        defer { try? FileManager.default.removeItem(at: two) }
        for name in GeneratedSounds.names {
            #expect(try Data(contentsOf: one.appendingPathComponent("\(name).wav")) == Data(contentsOf: two.appendingPathComponent("\(name).wav")), "\(name)")
        }
    }

    @Test func formatDurationSizeAndPeak() throws {
        let all = try wavs(in: GeneratedSounds.committed)
        for (name, w) in all {
            #expect(w.sampleRate == 44_100 && w.channels == 1 && w.bits == 16, "\(name) format")
            #expect(w.bytes < 30_000, "\(name) is \(w.bytes) bytes")
            #expect(w.peakDB <= -12, "\(name) peaks at \(w.peakDB) dBFS")
            #expect(w.peakDB > -30, "\(name) is inaudibly quiet (\(w.peakDB) dBFS)")
            #expect(w.duration >= 0.04 && w.duration <= 0.26, "\(name) lasts \(w.duration) s")
        }
        // The chirp pack: gentle, 90–140 ms.
        for name in ["chirp-start", "chirp-stop"] { #expect((0.09...0.14).contains(all[name]!.duration), "\(name) duration") }
    }

    @Test func everyCueStartsAndEndsOnSilenceWithAFade() throws {
        for (name, w) in try wavs(in: GeneratedSounds.committed) {
            #expect(w.samples.first == 0 && w.samples.last == 0, "\(name) must start and end on exact zero")
            // No step at the ends: the first and last few samples are tiny next to the peak.
            #expect(w.samples.prefix(4).allSatisfy { abs($0) <= 0.25 * w.peak }, "\(name) attack")
            #expect(w.samples.suffix(8).allSatisfy { abs($0) <= 0.02 * w.peak }, "\(name) release")
            // The last 5 ms are a fade-out, not a cut.
            #expect(w.rms(from: w.duration - 0.005, to: w.duration) <= 0.05 * w.peak, "\(name) tail")
        }
    }

    @Test func thePacksSitAtASimilarLoudness() throws {
        let all = try wavs(in: GeneratedSounds.committed)
        let levels = all.mapValues(\.loudest30msDB)
        let spread = levels.values.max()! - levels.values.min()!
        #expect(spread <= 4.5, "loudness spread \(spread) dB: \(levels)")   // the click is set 3 dB lower on purpose
        for pack in ["chirp", "soft", "glass", "click"] {
            #expect(abs(levels["\(pack)-start"]! - levels["\(pack)-stop"]!) <= 1.0, "\(pack) start and stop differ")
        }
    }

    @Test func theChirpRisesToStartAndFallsToStop() throws {
        let all = try wavs(in: GeneratedSounds.committed)
        let start = all["chirp-start"]!, stop = all["chirp-stop"]!
        let (s1, s2) = (start.zeroCrossingHz(from: 0.025, to: 0.05), start.zeroCrossingHz(from: 0.085, to: 0.11))
        #expect((2000...2900).contains(s1) && (2900...3600).contains(s2) && s2 > s1 * 1.15, "start sweep \(s1) → \(s2)")
        let (e1, e2) = (stop.zeroCrossingHz(from: 0.027, to: 0.054), stop.zeroCrossingHz(from: 0.095, to: 0.12))
        #expect((2500...3100).contains(e1) && (1900...2600).contains(e2) && e2 < e1 * 0.85, "stop sweep \(e1) → \(e2)")
    }

    @Test func softGoesUpAFifthToStartAndDownToStop() throws {
        let all = try wavs(in: GeneratedSounds.committed)
        let g5 = 783.99, d6 = 1174.66   // G5 and D6: a perfect fifth, 2^(7/12) in equal temperament
        #expect(abs(d6 / g5 - pow(2, 7.0 / 12)) < 0.001)
        let start = all["soft-start"]!, stop = all["soft-stop"]!
        #expect(start.energy(at: g5, from: 0.005, to: 0.06) > 4 * start.energy(at: d6, from: 0.005, to: 0.06))
        #expect(start.energy(at: d6, from: 0.09, to: 0.15) > 4 * start.energy(at: g5, from: 0.09, to: 0.15))
        #expect(stop.energy(at: d6, from: 0.005, to: 0.065) > 4 * stop.energy(at: g5, from: 0.005, to: 0.065))
        // (the first note is still ringing under the second, so the margin is smaller than at the onset)
        #expect(stop.energy(at: g5, from: 0.09, to: 0.16) > 2.5 * stop.energy(at: d6, from: 0.09, to: 0.16))
    }

    @Test func glassRingsOnWithAShortTailAndClicksAreBrief() throws {
        let all = try wavs(in: GeneratedSounds.committed)
        for name in ["glass-start", "glass-stop"] {
            let w = all[name]!
            #expect(w.rms(from: 0.1, to: 0.15) > 0.001, "\(name) has a tail")   // still ringing at 100 ms
            #expect(w.rms(from: 0.1, to: 0.15) < 0.25 * w.rms(from: 0, to: 0.03), "\(name) decays")
        }
        for name in ["click-start", "click-stop"] { #expect(all[name]!.duration <= 0.08) }
    }

    @Test func everyPackFitsTheStartRuleWithoutTrimming() throws {
        // The start cue must finish before the mic opens: every generated start cue plays whole.
        for (name, w) in try wavs(in: GeneratedSounds.committed) where name.hasSuffix("-start") {
            #expect(!SoundTiming.isTrimmed(.start, duration: w.duration), "\(name)")
            #expect(SoundTiming.micDelay(cueDuration: w.duration) < 0.3, "\(name)")
        }
    }
}

// MARK: the Settings form

@MainActor
@Suite struct SoundSettingsFormTests {
    private func hidden(_ form: SettingsForm) -> Bool { form.chooseStart.superview?.superview?.isHidden ?? false }

    @Test func thePackPickerListsEveryPackAndShowsTheCurrentOne() {
        var s = SettingsState()
        s.soundPack = .glass
        let form = SettingsForm(s)
        #expect(form.soundPack.itemTitles == ["Chirp", "Soft", "Glass", "Click", "System", "Custom…"])
        #expect(form.soundPack.titleOfSelectedItem == "Glass")
        #expect(form.previewStart.title.contains("▶") && form.previewStop.title.contains("▶"))
    }

    @Test func theVolumeSliderGoesFromZeroToOneHundredAndStartsAtSixty() {
        let form = SettingsForm(SettingsState())
        #expect(form.volume.minValue == 0 && form.volume.maxValue == 100 && form.volume.doubleValue == 60)
        form.setVolume(0.25)
        #expect(form.volume.doubleValue == 25)
        var s = SettingsState()
        s.soundVolume = 1
        #expect(SettingsForm(s).volume.doubleValue == 100)
    }

    @Test func customFilesShowTheirNameAndLengthAndWarnAboutLongStarts() {
        var s = SettingsState()
        s.soundPack = .custom
        s.customStart = CustomSound(fileName: "custom-start-1.m4a", displayName: "Doorbell.m4a", duration: 1.2)
        s.customStop = CustomSound(fileName: "custom-stop-1.wav", displayName: "tap.wav", duration: 0.18)
        let form = SettingsForm(s)
        #expect(form.customStartHelp.stringValue.hasPrefix(SoundTiming.longStartWarning) && form.customStartHelp.stringValue.contains("1.20 s"))
        #expect(form.removeStart.isEnabled && form.removeStop.isEnabled)
        form.setCustomSounds(start: CustomSound(fileName: "a.wav", displayName: "tap.wav", duration: 0.1), stop: nil)
        #expect(form.customStartHelp.stringValue == SoundTiming.longStartWarning)   // the rule stays visible, not alarming
        #expect(!form.removeStop.isEnabled)
        form.setCustomSounds(start: nil, stop: nil, error: "That file isn't audio Chirp can play (use aiff, wav, caf, m4a or mp3).")
        #expect(form.customStartHelp.textColor == .systemRed && !form.removeStart.isEnabled)
    }

    @Test func theCustomRowsOnlyShowForTheCustomPack() {
        let form = SettingsForm(SettingsState())
        let before = form.fittingSize(for: .dictation).height
        form.showPack(.custom)
        #expect(form.fittingSize(for: .dictation).height > before)
        form.showPack(.soft)
        #expect(form.fittingSize(for: .dictation).height == before)
    }
}
