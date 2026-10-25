import AVFoundation
import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

// Live Notes call audio (#211): the mixer and its echo gate, the "You" labels, the roster's microphone person, the
// capture behind a fake tap, the frame router, and the session's wiring (sources, notices, capture lifetime).

/// 16 kHz mono PCM16: `seconds` of a tone at `amplitude` (0…1), or digital silence at 0.
func pcm(_ seconds: Double, amplitude: Double = 0.3, frequency: Double = 220) -> Data {
    let n = Int(seconds * 16_000)
    var out = Data(count: n * 2)
    out.withUnsafeMutableBytes { raw in
        let s = raw.bindMemory(to: Int16.self)
        for i in 0..<n { s[i] = Int16(amplitude * 32_000 * sin(2 * .pi * frequency * Double(i) / 16_000)).littleEndian }
    }
    return out
}

private func samples(_ data: Data) -> [Int16] {
    data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)).map { Int16(littleEndian: $0) } }
}

/// 50 ms microphone frames.
private func frames(_ seconds: Double, amplitude: Double = 0.3) -> [Data] {
    let all = pcm(seconds, amplitude: amplitude)
    return stride(from: 0, to: all.count, by: PCMConverter.frameBytes).map { all.subdata(in: $0..<min($0 + PCMConverter.frameBytes, all.count)) }
}

@Suite struct CallAudioMixerTests {
    @Test func remoteWaitsForThePrimeThenPlaysInOrder() {
        let mixer = CallAudioMixer()
        mixer.pushRemote(pcm(0.1))
        // Under the 150 ms prime: the call side is silent and nothing is taken from the queue.
        let first = mixer.mix(mic: Data(count: PCMConverter.frameBytes))
        #expect(first.remoteLevel.peak == 0)
        #expect(abs(mixer.backlog - 0.1) < 0.001)
        mixer.pushRemote(pcm(0.1))
        let second = mixer.mix(mic: Data(count: PCMConverter.frameBytes))
        #expect(second.remote == pcm(0.2).prefix(PCMConverter.frameBytes))
        #expect(abs(mixer.backlog - 0.15) < 0.001)
        #expect(second.mix == second.remote, "a silent microphone adds nothing")
    }

    @Test func underrunPadsWithSilenceAndPrimesAgain() {
        let mixer = CallAudioMixer()
        mixer.pushRemote(pcm(0.16))
        _ = mixer.mix(mic: Data(count: PCMConverter.frameBytes))
        _ = mixer.mix(mic: Data(count: PCMConverter.frameBytes))
        _ = mixer.mix(mic: Data(count: PCMConverter.frameBytes))
        let short = mixer.mix(mic: Data(count: PCMConverter.frameBytes))   // 10 ms left of 50
        #expect(mixer.underruns == 1)
        #expect(samples(short.remote).suffix(640).allSatisfy { $0 == 0 })
        mixer.pushRemote(pcm(0.1))
        #expect(mixer.mix(mic: Data(count: PCMConverter.frameBytes)).remoteLevel.peak == 0, "waits for the prime again")
    }

    @Test func backlogOverTheCapDropsBackToThePrime() {
        let mixer = CallAudioMixer()
        mixer.pushRemote(pcm(1.2))
        #expect(mixer.dropped == 1)
        #expect(abs(mixer.backlog - CallAudioMixer.prime) < 0.001)
    }

    @Test func sumClampsInsteadOfWrapping() {
        let loud = Data([Int16.max, Int16.min, 1000].flatMap { withUnsafeBytes(of: $0.littleEndian, Array.init) })
        let mixed = samples(CallAudioMixer.sum(loud, loud))
        #expect(mixed == [Int16.max, Int16.min, 2000])
    }

    @Test func echoGateDropsAQuietMicrophoneWhileTheCallTalks() {
        let mixer = CallAudioMixer()
        mixer.pushRemote(pcm(1.0, amplitude: 0.3))
        var gated: [Bool] = []
        for f in frames(0.5, amplitude: 0.03) {   // the call through the speakers, much quieter at the microphone
            let out = mixer.mix(mic: f)
            if out.remoteLevel.rms > 0 { gated.append(out.micIsEcho) }
            if out.micIsEcho { #expect(out.mix == out.remote, "one copy of each remote word") }
        }
        #expect(!gated.isEmpty && gated.allSatisfy { $0 })
    }

    @Test func talkingOverTheCallKeepsTheMicrophone() {
        let mixer = CallAudioMixer()
        mixer.pushRemote(pcm(1.0, amplitude: 0.2))
        for f in frames(0.5, amplitude: 0.3) {
            let out = mixer.mix(mic: f)
            #expect(!out.micIsEcho)
            #expect(out.mix != out.remote || out.remoteLevel.peak == 0)
        }
    }

    @Test func gateOpensAfterTheHangoverWhenTheCallStops() {
        let mixer = CallAudioMixer()
        mixer.pushRemote(pcm(0.4, amplitude: 0.3))
        var echo: [Bool] = []
        for f in frames(1.6, amplitude: 0.01) { echo.append(mixer.mix(mic: f).micIsEcho) }
        // Frames 3…10 carry the call (after the prime); the gate holds 350 ms more, then opens.
        #expect(echo[5])
        #expect(!echo.last!)
        let open = echo.lastIndex(of: true)!
        #expect(open >= 10 && open <= 18)
    }

    @Test func resetDropsTheQueue() {
        let mixer = CallAudioMixer()
        mixer.pushRemote(pcm(0.5))
        mixer.reset()
        #expect(mixer.backlog == 0)
        #expect(mixer.mix(mic: Data(count: PCMConverter.frameBytes)).remoteLevel.peak == 0)
    }
}

/// A diarizer that records what it was fed.
final class RecordingDiarizer: SpeakerDiarizing, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var fed: [(bytes: Data, at: TimeInterval)] = []
    var timeline = SpeakerTimeline()
    private(set) var flushes = 0
    private(set) var resets = 0
    private(set) var embedder: (any VoiceEmbedder)?
    func feed(_ pcm16: Data, at documentTime: TimeInterval) { lock.withLock { fed.append((pcm16, documentTime)) } }
    func flush() async { lock.withLock { flushes += 1 } }
    var snapshot: SpeakerTimeline { lock.withLock { timeline } }
    func reset() { lock.withLock { resets += 1 } }
    func attachEmbedder(_ embedder: (any VoiceEmbedder)?) { lock.withLock { self.embedder = embedder } }
}

@Suite struct CallSpeakersTests {
    private func frame(mic: Double, remote: Double, echo: Bool = false) -> CallFrame {
        let m = mic > 0 ? pcm(0.05, amplitude: mic) : Data(count: PCMConverter.frameBytes)
        let r = remote > 0 ? pcm(0.05, amplitude: remote, frequency: 330) : Data(count: PCMConverter.frameBytes)
        return CallFrame(mix: CallAudioMixer.sum(m, r), mic: m, remote: r, micLevel: Level(pcm16: m), remoteLevel: Level(pcm16: r), micIsEcho: echo)
    }

    /// Feeds `seconds` of one kind of frame starting at `start`; returns the end.
    @discardableResult
    private func feed(_ s: CallSpeakers, _ f: CallFrame, from start: TimeInterval, seconds: Double) -> TimeInterval {
        var t = start
        for _ in 0..<Int((seconds / 0.05).rounded()) { s.feed(f, at: t); t += 0.05 }
        return t
    }

    @Test func theCallSideAloneReachesTheDiarizer() {
        let remote = RecordingDiarizer()
        let s = CallSpeakers(remote: remote)
        let f = frame(mic: 0.3, remote: 0.2)
        s.feed(f, at: 1.5)
        #expect(remote.fed.count == 1)
        #expect(remote.fed[0].bytes == f.remote)
        #expect(remote.fed[0].at == 1.5)
        s.feed(f.mix, at: 1.55)   // no call audio: the mix, as before
        #expect(remote.fed[1].bytes == f.mix)
    }

    @Test func microphoneSpeechIsYouAfterTheHangover() async {
        let remote = RecordingDiarizer()
        remote.timeline = SpeakerTimeline(spans: [SpeakerSpan(slot: 0, start: 0, end: 1)], finalizedThrough: 10)
        let s = CallSpeakers(remote: remote)
        var t = feed(s, frame(mic: 0.3, remote: 0), from: 2, seconds: 1)
        t = feed(s, frame(mic: 0, remote: 0), from: t, seconds: 0.2)       // a short pause stays inside the turn
        t = feed(s, frame(mic: 0.3, remote: 0), from: t, seconds: 0.5)
        var snap = s.snapshot
        #expect(snap.spans.filter { $0.slot == SpeakerRoster.youSlot }.isEmpty, "still open")
        #expect(snap.tentative.contains { $0.slot == SpeakerRoster.youSlot && $0.start == 2 })
        #expect(snap.finalizedThrough == 2, "nothing after the open turn is settled")
        feed(s, frame(mic: 0, remote: 0), from: t, seconds: 1)
        snap = s.snapshot
        let you = snap.spans.filter { $0.slot == SpeakerRoster.youSlot }
        #expect(you.count == 1)
        #expect(abs(you[0].start - 2) < 1e-9 && abs(you[0].end - 3.7) < 1e-9)
        #expect(snap.spans.contains { $0.slot == 0 }, "the remote spans are kept")
    }

    @Test func echoAndClicksAreNeverYou() async {
        let s = CallSpeakers(remote: RecordingDiarizer())
        var t = feed(s, frame(mic: 0.3, remote: 0.4, echo: true), from: 0, seconds: 2)
        t = feed(s, frame(mic: 0.3, remote: 0), from: t, seconds: 0.1)    // a click
        feed(s, frame(mic: 0, remote: 0), from: t, seconds: 1)
        await s.flush()
        #expect(s.snapshot.spans.isEmpty)
    }

    @Test func flushClosesTheTurnAndResetForgetsIt() async {
        let remote = RecordingDiarizer()
        remote.timeline = SpeakerTimeline(finalizedThrough: 100)
        let s = CallSpeakers(remote: remote)
        feed(s, frame(mic: 0.3, remote: 0), from: 0, seconds: 1)
        await s.flush()
        #expect(remote.flushes == 1)
        #expect(s.snapshot.spans.map(\.slot) == [SpeakerRoster.youSlot])
        s.reset()
        #expect(remote.resets == 1)
        #expect(s.snapshot.spans.isEmpty)
    }

    @Test func theSettledFrontierIsTheEarlierOfBothSides() {
        let remote = RecordingDiarizer()
        remote.timeline = SpeakerTimeline(finalizedThrough: 1)
        let s = CallSpeakers(remote: remote)
        feed(s, frame(mic: 0, remote: 0.3), from: 0, seconds: 3)
        #expect(s.snapshot.finalizedThrough == 1)
        remote.timeline = SpeakerTimeline(finalizedThrough: 10)
        #expect(abs(s.snapshot.finalizedThrough - (3 - CallSpeakers.youHangover)) < 1e-9)
    }

    @Test func attributionSplitsYouFromTheCall() {
        // The words of one segment: "You" talk 0–1 s, then a remote voice 1.2–2 s.
        let spans = [SpeakerSpan(slot: SpeakerRoster.youSlot, start: 0, end: 1), SpeakerSpan(slot: 0, start: 1.2, end: 2)]
        let words = [WordTiming(text: "send", start: 0.1, end: 0.4), WordTiming(text: "it", start: 0.5, end: 0.8),
                     WordTiming(text: "will", start: 1.3, end: 1.5), WordTiming(text: "do", start: 1.6, end: 1.9)]
        let turns = SpeakerAttribution.turns(words: words, raw: "send it will do", text: "Send it. Will do.", offset: 0, end: 2, spans: spans)
        #expect(turns?.map(\.slot) == [SpeakerRoster.youSlot, 0])
        var document = NotesDocument()
        document.append(NotesSegment(id: 0, offset: 0, raw: "send it will do", text: "Send it. Will do."))
        document.attachSpeakers(turns ?? [], toSegment: 0)
        let names = document.segments[0].turns?.map { document.roster.displayName($0.person) }
        #expect(names == ["You", "Person 1"], "You never takes a Person number")
    }
}

@Suite struct CallRosterTests {
    @Test func theMicrophoneIsYouUntilRenamed() {
        var roster = SpeakerRoster()
        let remote = roster.id(forSlot: 0)
        let you = roster.id(forSlot: SpeakerRoster.youSlot)
        #expect(roster.displayName(remote) == "Person 1")
        #expect(roster.displayName(you) == "You")
        #expect(roster.displayName(roster.id(forSlot: 1)) == "Person 2", "numbered without You")
        #expect(roster.ownName(you) == "You")
        roster.rename(you, to: "Maya")
        #expect(roster.displayName(you) == "Maya")
        roster.rename(you, to: " ")
        #expect(roster.displayName(you) == "You")
    }

    @Test func aRecoveredSessionKeepsOneYou() {
        var roster = SpeakerRoster()
        let you = roster.id(forSlot: SpeakerRoster.youSlot)
        roster.forgetSlots()
        #expect(roster.id(forSlot: SpeakerRoster.youSlot) == you)
        #expect(roster.people.count == 1)
    }

    @Test func storedRostersStillDecodeAndTheFlagRoundTrips() throws {
        let old = #"{"people":[{"id":1,"name":"Ana"}],"slots":{"0":1}}"#
        let decoded = try JSONDecoder().decode(SpeakerRoster.self, from: Data(old.utf8))
        #expect(decoded.displayName(1) == "Ana")
        var roster = SpeakerRoster()
        _ = roster.id(forSlot: SpeakerRoster.youSlot)
        let back = try JSONDecoder().decode(SpeakerRoster.self, from: JSONEncoder().encode(roster))
        #expect(back.displayName(1) == "You")
        #expect(!String(decoding: try JSONEncoder().encode(SpeakerRoster()), as: UTF8.self).contains("local"))
    }
}

/// A system-audio tap driven by the test: 48 kHz stereo float buffers, as a process tap delivers.
final class FakeCallTap: SystemAudioTap, @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable (AVAudioPCMBuffer) -> Void)?
    var kind: CallAudioKind = .processTap
    var startError: Error?
    private(set) var starts: [CallAudioApp?] = []
    private(set) var stops = 0
    var isRunning: Bool { lock.withLock { sink != nil } }

    func start(app: CallAudioApp?, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        lock.withLock { starts.append(app) }
        if let startError { throw startError }
        lock.withLock { sink = onBuffer }
    }

    func stop() { lock.withLock { stops += 1; sink = nil } }

    /// `seconds` of a tone (or digital silence) in 10 ms buffers.
    func play(_ seconds: Double, amplitude: Float = 0.3) {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        for k in 0..<Int((seconds / 0.01).rounded()) {
            guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480), let sink = lock.withLock({ sink }) else { return }
            b.frameLength = 480
            for c in 0..<2 { for i in 0..<480 { b.floatChannelData![c][i] = amplitude * sinf(Float(k * 480 + i) * 0.05) } }
            sink(b)
        }
    }
}

/// A tap whose start runs `during` before returning (a Stop while the system holds the start).
final class SlowTap: SystemAudioTap, @unchecked Sendable {
    let kind = CallAudioKind.processTap
    var during: () -> Void = {}
    private(set) var stops = 0
    private(set) var running = false
    func start(app: CallAudioApp?, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        running = true
        during()
    }
    func stop() { stops += 1; running = false }
}

@Suite struct CallAudioCaptureTests {
    @Test func tapAudioIsConvertedIntoTheMixer() throws {
        let tap = FakeCallTap()
        let capture = CallAudioCapture(tap: tap)
        try capture.start(app: CallAudioApp(bundleID: "us.zoom.xos", name: "Zoom"))
        #expect(tap.starts == [CallAudioApp(bundleID: "us.zoom.xos", name: "Zoom")])
        tap.play(0.5, amplitude: 0)
        #expect(!capture.hasHeardAudio, "digital silence (no permission) is not audio")
        tap.play(0.5)
        #expect(capture.hasHeardAudio)
        #expect(capture.mixer.backlog > 0.8 && capture.mixer.backlog <= 1.0)
        capture.stop()
        #expect(tap.stops == 1)
        #expect(!capture.isRunning)
        capture.stop()
        #expect(tap.stops == 1, "idempotent")
    }

    @Test func aStartThatReturnsAfterStopUndoesItself() throws {
        let tap = SlowTap()
        let capture = CallAudioCapture(tap: tap)
        tap.during = { capture.stop() }
        try capture.start(app: nil)
        #expect(!capture.isRunning)
        #expect(tap.stops >= 1)
        #expect(!tap.running)
    }

    @Test func aRefusedTapLeavesNothingRunning() {
        let tap = FakeCallTap()
        tap.startError = CallAudioError.unavailable("denied")
        let capture = CallAudioCapture(tap: tap)
        #expect(throws: CallAudioError.self) { try capture.start(app: nil) }
        #expect(!capture.isRunning)
    }

    @Test func fallbackUsesTheNextTapAndSaysWhichRuns() throws {
        let first = FakeCallTap(), second = FakeCallTap()
        first.startError = CallAudioError.unavailable("no tap")
        second.kind = .screenCapture
        let tap = FallbackAudioTap([first, second])
        try tap.start(app: nil) { _ in }
        #expect(tap.kind == .screenCapture)
        #expect(second.isRunning)
        tap.stop()
        #expect(!second.isRunning)
        second.startError = CallAudioError.noSource
        #expect(throws: CallAudioError.noSource) { try tap.start(app: nil) { _ in } }
    }

    @Test func appsAreSortedCallAppsFirstAndDeduplicated() {
        let apps = CallAudioApp.sorted([
            CallAudioApp(bundleID: "com.spotify.client", name: "Spotify"),
            CallAudioApp(bundleID: "com.google.Chrome", name: "Google Chrome"),
            CallAudioApp(bundleID: "us.zoom.xos", name: "zoom.us"),
            CallAudioApp(bundleID: "com.apple.Music", name: "Music"),
            CallAudioApp(bundleID: "us.zoom.xos", name: "zoom.us"),
        ])
        #expect(apps.map(\.name) == ["zoom.us", "Google Chrome", "Music", "Spotify"])
    }

    @Test func sourcesTitles() {
        #expect(NotesSources.microphone.title == "Microphone")
        #expect(NotesSources(callAudio: true).title == "Microphone + call audio")
        #expect(NotesSources(callAudio: true, app: CallAudioApp(bundleID: "com.apple.FaceTime", name: "FaceTime")).title == "Microphone + FaceTime")
        #expect(NotesSourcesText.chip(NotesSources(callAudio: true)) == "Mic + call audio")
    }

    @Test func preferencesKeepTheDefaultAndTheApp() {
        let suite = "chirp-call-prefs-\(UUID().uuidString)"
        defer { removeTestDefaults(suite) }
        let prefs = Preferences(defaults: UserDefaults(suiteName: suite)!)
        #expect(prefs.notesSources == .microphone)
        prefs.notesCallAudio = true
        prefs.notesCallAudioApp = CallAudioApp(bundleID: "us.zoom.xos", name: "Zoom")
        #expect(prefs.notesSources == NotesSources(callAudio: true, app: CallAudioApp(bundleID: "us.zoom.xos", name: "Zoom")))
        prefs.notesCallAudioApp = nil
        #expect(prefs.notesSources == NotesSources(callAudio: true))
    }

    @Test func launchModeParsesTheCallSelftest() {
        #expect(LaunchMode.parse(["--call-selftest", "--mic", "a.wav", "--remote", "b.wav"]) == .callSelftest)
        #expect(LaunchMode.usageText.contains("--call-selftest"))
    }
}

@Suite struct CallRouterTests {
    @Test func theRouterGivesTheDiarizerBothSidesAndTheSocketTheMix() {
        let router = NotesFrameRouter()
        let diarizer = RecordingDiarizer()
        router.setSpeakers(CallSpeakers(remote: diarizer))
        let audio = NotesSegmentAudio(pool: NotesAudioPool())
        _ = router.swap(to: nil, audio: audio)
        let mic = pcm(0.05, amplitude: 0.3), remote = pcm(0.05, amplitude: 0.2, frequency: 330)
        let frame = CallFrame(mix: CallAudioMixer.sum(mic, remote), mic: mic, remote: remote, micLevel: Level(pcm16: mic),
                              remoteLevel: Level(pcm16: remote), micIsEcho: false)
        _ = router.route(frame.mix, level: Level(pcm16: frame.mix), call: frame)
        _ = router.route(frame.mix, level: Level(pcm16: frame.mix), call: frame)
        #expect(diarizer.fed.map(\.bytes) == [remote, remote])
        #expect(diarizer.fed.map(\.at) == [0, 0.05])
        #expect(audio.contents == [frame.mix, frame.mix], "kept audio is the mix the recognizer heard")
        #expect(abs(router.seconds - 0.1) < 1e-9)
    }
}

@MainActor
@Suite(.serialized) struct CallAudioSessionTests {
    @Test func callAudioIsOffByDefaultAndNeedsATap() async {
        let h = NotesHarness(callTap: nil)
        #expect(!h.model.callAudioAvailable)
        #expect(h.model.sources == .microphone)
        await h.record()
        #expect(!h.model.capturingCall)
        await h.stop()
    }

    @Test func firstTurnOnExplainsBeforeAnythingChanges() async {
        let tap = FakeCallTap()
        let h = NotesHarness(callTap: tap)
        #expect(h.model.callAudioAvailable)
        h.model.onSourcesChange(NotesSources(callAudio: true))
        #expect(h.model.explainingCallAudio == NotesSources(callAudio: true))
        #expect(!h.session.sources.callAudio)
        h.model.onCallAudioExplained(false)
        #expect(h.model.explainingCallAudio == nil)
        #expect(!h.session.sources.callAudio)
        #expect(!h.prefs.notesCallAudioExplained)
        h.model.onSourcesChange(NotesSources(callAudio: true))
        h.model.onCallAudioExplained(true)
        #expect(h.session.sources.callAudio)
        #expect(h.model.sources.callAudio)
        #expect(h.prefs.notesCallAudioExplained)
        #expect(!h.prefs.notesCallAudio, "a note's choice is not the Settings default")
        #expect(tap.starts.isEmpty, "nothing records before Record")
    }

    @Test func recordingWithCallAudioMixesBothSidesAndStopsBoth() async {
        let tap = FakeCallTap()
        let h = NotesHarness(speakers: FakeModelStore(downloaded: true), callTap: tap)
        h.prefs.notesCallAudioExplained = true
        let zoom = CallAudioApp(bundleID: "us.zoom.xos", name: "Zoom")
        h.model.onSourcesChange(NotesSources(callAudio: true, app: zoom))
        #expect(h.prefs.notesCallAudioApp == zoom, "the app is remembered for next time")
        await h.record()
        #expect(tap.starts == [zoom])
        #expect(h.model.capturingCall)
        #expect(h.recorder.speakers is CallSpeakers, "the microphone is You, the call is diarized")
        h.model.onSourcesChange(.microphone)
        #expect(h.session.sources.callAudio, "locked while recording")
        #expect(h.edges.beeps == 1)
        for _ in 0..<10 {   // both sides at once, as a call delivers them
            tap.play(0.1)
            await h.speak(0.1)
        }
        await h.until("call level") { h.model.callLevel > 0 }
        // Stop waits for the speaker labels, whose timeouts run on the harness clock.
        let stopping = Task { await h.session.stop() }
        for _ in 0..<60 where h.session.isActive { await h.advance(1) }
        await stopping.value
        #expect(!h.session.isActive)
        #expect(!tap.isRunning)
        #expect(!h.model.capturingCall)
        #expect(h.model.callLevel == 0)
        #expect(h.transcript.count >= 1)
    }

    @Test func pauseAndResumeReopenTheCallSide() async {
        let tap = FakeCallTap()
        let h = NotesHarness(callTap: tap)
        h.prefs.notesCallAudioExplained = true
        h.model.onSourcesChange(NotesSources(callAudio: true))
        await h.record()
        await h.speak(1)
        await h.session.pause()
        #expect(!tap.isRunning)
        await h.resumeForTest()
        #expect(tap.isRunning)
        #expect(tap.starts.count == 2)
        await h.stop()
        #expect(!tap.isRunning)
    }

    @Test func aRefusedTapRecordsTheMicrophoneAndSaysSo() async {
        let tap = FakeCallTap()
        tap.startError = CallAudioError.unavailable("denied")
        let h = NotesHarness(callTap: tap)
        h.prefs.notesCallAudioExplained = true
        h.model.onSourcesChange(NotesSources(callAudio: true))
        await h.record()
        await h.until("call audio notice") { h.model.callNotice == .unavailable }
        #expect(h.recorder.state == .recording)
        #expect(!h.model.capturingCall)
        #expect(h.model.callNote == NotesSourcesText.notice(.unavailable))
        h.model.onOpenCallAudioSettings()
        #expect(h.edges.callSettingsOpened == 1)
        await h.speak(1)
        await h.stop()
        #expect(h.model.callNote == nil)
    }

    @Test func onlySilenceFromTheCallSaysSoUntilItIsHeard() async {
        let tap = FakeCallTap()
        let h = NotesHarness(callTap: tap)
        h.prefs.notesCallAudioExplained = true
        h.model.onSourcesChange(NotesSources(callAudio: true))
        await h.record()
        tap.play(0.5, amplitude: 0)
        await h.advance(19)
        #expect(h.model.callNotice == nil)
        await h.advance(2)
        #expect(h.model.callNotice == .silent)
        tap.play(0.2)
        await h.advance(2)
        #expect(h.model.callNotice == nil)
        await h.stop()
    }

    @Test func newNotesTakeTheSettingsDefault() async {
        let tap = FakeCallTap()
        let h = NotesHarness(callTap: tap)
        h.prefs.notesCallAudio = true
        h.session.defaultSourcesChanged()
        #expect(h.session.sources.callAudio)
        h.prefs.notesCallAudioExplained = true
        h.model.onSourcesChange(.microphone)
        #expect(!h.session.sources.callAudio)
        h.session.reset()
        #expect(h.session.sources.callAudio, "New starts from the default again")
    }
}
