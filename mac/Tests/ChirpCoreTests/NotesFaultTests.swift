import AppKit
import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

/// The fault matrix (#66, docs/research/live-notes-ux.md §3): one end-to-end test per fault, through `NotesHarness`.
/// Transient faults never lose audio (#62): a failed segment is replayed from memory, the server can be offline for
/// up to `NotesRecorder.maxKeptAudio`, the microphone falls back, a mute warns and sleep pauses. The crash rows run
/// against the recovery journal (#61).
@MainActor
@Suite(.serialized) struct NotesFaultTests {
    /// About 13 s of speech, a pause the segmenter cuts at, and the start of the next segment.
    private func segment(_ h: NotesHarness) async {
        let before = h.document.segments.count
        await h.speak(13).pause(1)
        await h.until("segment \(before) committed") { h.document.segments.count > before }
        await h.speak(1)
    }

    private func isError(_ h: NotesHarness) -> Bool { if case .error = h.recorder.state { true } else { false } }

    /// Stop, with the fake clock moving so replays that fail can wait out their backoff.
    private func stopWhileRetrying(_ h: NotesHarness) async {
        let stopping = Task { await h.session.stop() }
        for _ in 0..<90 where h.recorder.state != .stopped { await h.advance(1) }
        await stopping.value
        await h.settle()
    }

    private var offline: (String) -> Bool { { $0.hasPrefix("Chirp server offline — keeping audio (") && $0.hasSuffix(") · retrying") } }

    // MARK: sockets

    @Test func aSocketDropMidSegmentIsReplayedWithNoGap() async {
        let h = NotesHarness()
        h.streams.script(0, SocketScript(dropAfterBytes: 5 * 32_000))
        await h.record()
        await h.speak(8)
        #expect(h.statuses.contains(where: offline))
        #expect(h.recorder.state == .recording && h.session.isCapturing)
        // The dropped segment is cut at once and socket 1 replays all 5 s of it; the next one was kept in memory.
        await h.until("replayed") { h.document.segments.count == 1 }
        #expect(h.transcript == ["Segment 1."] && h.streams.bytesBySocket[1] ?? 0 >= 5 * 32_000)
        // The segment recorded while offline is sent at its cut.
        h.expectStatus(NotesStatus.catchingUp(1))
        await h.speak(13).pause(1)
        await h.speak(2)
        await h.stop()
        #expect(h.gaps == 0 && h.transcript.count == 3)
        #expect(h.recorder.keptAudioBytes == 0)
        h.expectStatus(NotesStatus.stopped).expectEditorInSync()
    }

    @Test func aSocketThatNeverGetsReadyIsReplayed() async {
        let h = NotesHarness()
        h.streams.script(1, SocketScript(start: .stall))
        await h.record()
        await segment(h)
        await h.advance(StreamLimits().readyDeadline.inSeconds)
        await h.until("offline") { h.recorder.connection != .online }
        #expect(h.recorder.state == .recording)
        await h.speak(2)
        await h.stop()
        // Socket 2 replays segment 1; segment 2 was kept in memory and socket 3 sends it at Stop.
        #expect(h.transcript == ["Segment 0.", "Segment 2.", "Segment 3."])
    }

    @Test func aDropWhileFinalizingIsReplayedInOrder() async {
        let h = NotesHarness()
        h.streams.script(0, SocketScript(stop: .drop))
        await h.record()
        await h.speak(13).pause(1)
        await h.until("replayed") { h.document.segments.count == 1 }
        await h.speak(2)
        await h.stop()
        #expect(h.transcript == ["Segment 2.", "Segment 1."])
        #expect(h.recorder.state == .stopped)
    }

    @Test func aFinalThatNeverComesIsReplayed() async {
        let h = NotesHarness()
        h.streams.script(0, SocketScript(stop: .stall))
        await h.record()
        await h.speak(13).pause(1).speak(2)
        await h.advance(NotesRecorder.finalTimeout)
        await h.until("replayed") { h.document.segments.count == 1 }
        await h.stop()
        #expect(h.transcript == ["Segment 2.", "Segment 1."])
    }

    @Test func busyThreeTimesInARowNeverStops() async {
        let h = NotesHarness()
        for i in 1...3 { h.streams.script(i, SocketScript(stop: .error("busy"))) }
        await h.record()
        // Commits wait for the busy segments' replays, which back off on the fake clock: no waiting for them here.
        for _ in 0..<4 { await h.speak(13).pause(1) }
        await h.speak(1)
        #expect(h.recorder.state == .recording && h.session.isCapturing)
        await stopWhileRetrying(h)
        #expect(h.recorder.state == .stopped && h.gaps == 0)
        #expect(h.document.segments.map(\.id) == Array(0..<h.document.segments.count) && h.document.segments.count == 5)
        #expect(!h.statuses.contains { $0.hasPrefix("Notes stopped") })
    }

    @Test func aRejectedTokenStillStopsWithTheReason() async {
        let h = NotesHarness()
        h.streams.script(1, SocketScript(stop: .error("auth")))
        await h.record()
        await segment(h)
        await segment(h)
        await h.until("stopped") { isError(h) }
        #expect(h.status == "Notes stopped: Server rejected the token")
        #expect(h.transcript.first == "Segment 0." && h.gaps == 1)
        #expect(!h.session.isCapturing)
    }

    // MARK: server outages

    @Test(arguments: [10.0, 60])
    func aServerOutageKeepsTheAudioAndCatchesUp(seconds: Double) async {
        let h = NotesHarness()
        await h.record()
        await segment(h)
        await h.until("first append") { h.http.structureRequests.count == 1 }
        h.streams.down = true
        h.streams.dropAll()
        await h.speak(seconds)
        #expect(h.recorder.state == .recording && h.session.isCapturing)
        #expect(offline(h.status))
        if case .offline(let kept) = h.recorder.connection { #expect(kept >= seconds) } else { Issue.record("not offline") }
        // Nothing is structured while segments wait for the server.
        #expect(h.http.structureRequests.count == 1)
        h.streams.down = false
        await h.advance(30)
        await h.stop()
        #expect(h.gaps == 0 && h.recorder.state == .stopped)
        #expect(h.document.segments.map(\.id) == Array(0..<h.document.segments.count))
        #expect(h.recorder.keptAudioBytes == 0)
        h.expectEditorInSync()
    }

    @Test func catchingUpShowsHowManySegmentsAreLeft() async {
        let h = NotesHarness()
        await h.record()
        await segment(h)
        h.streams.down = true
        h.streams.dropAll()
        for _ in 0..<3 { await h.speak(13).pause(1) }
        h.streams.script(h.streams.started, SocketScript(stop: .stall))
        h.streams.down = false
        await h.advance(1)
        await h.until("catching up") { if case .catchingUp = h.recorder.connection { true } else { false } }
        #expect(h.status.hasPrefix("Catching up ") && h.status.hasSuffix(" segments…"))
        #expect(h.http.structureRequests.count == 1)
        await h.advance(NotesRecorder.finalTimeout)
        await stopWhileRetrying(h)
        #expect(h.gaps == 0 && h.recorder.state == .stopped)
    }

    @Test func pastTheCapTheOldestAudioIsOneGap() async {
        let cap: TimeInterval = 3 * 60
        let h = NotesHarness(keptAudio: cap)
        await h.record()
        await segment(h)
        h.streams.down = true
        h.streams.dropAll()
        for _ in 0..<10 {
            await h.speak(29).pause(1)
            #expect(h.recorder.keptAudioBytes <= Int(cap * 32_000))
        }
        #expect(h.recorder.state == .recording)
        h.streams.down = false
        await h.advance(30)
        await h.stop()
        #expect(h.gaps == 1 && h.recorder.state == .stopped)
        #expect(h.transcript.first == "Segment 0." && h.transcript[1] == "⚠︎")
        #expect(h.document.segments[1].failure == NotesRecorder.offlineTooLong)
        #expect(h.transcript.count > 3)
    }

    @Test func stopWhileTheServerIsDownGivesUpAfterTheLimit() async {
        let h = NotesHarness()
        await h.record()
        await segment(h)
        h.streams.down = true
        h.streams.dropAll()
        await h.speak(5)
        let stopping = Task { await h.session.stop() }
        await h.until("finishing") { h.recorder.state == .stopping }
        await h.settle()
        h.expectStatus(NotesStatus.finishingOffline)
        for _ in 0..<Int(NotesRecorder.stopReplayLimit) + 5 where h.recorder.state != .stopped { await h.advance(1) }
        await stopping.value
        await h.settle()
        #expect(h.recorder.state == .stopped)
        #expect(h.transcript == ["Segment 0.", "⚠︎"] && h.document.segments[1].failure == NotesRecorder.offlineAtStop)
        #expect(h.recorder.keptAudioBytes == 0)
    }

    // MARK: structuring

    @Test(arguments: [NotesAnswer.timeout, .status(503)])
    func aTransientStructureFailureRetries(answer: NotesAnswer) async {
        let h = NotesHarness()
        h.http.answerStructure(answer)
        await h.record()
        await segment(h)
        await h.until("first pass failed") { h.recorder.structuring.isFailure }
        #expect(!h.text.contains("Segment 0."))
        await h.advance(NotesRecorder.minInterval)
        await h.until("retried") { h.text.contains("- Segment 0.") }
        #expect(h.http.structureRequests.count == 2)
        #expect(h.http.structureRequests[0].text == h.http.structureRequests[1].text)
        await h.stop()
        h.expectEditorInSync()
    }

    @Test func aRejectedWindowIsRetriedInHalves() async {
        let sentence = "We talked about the budget for the next quarter and agreed to revisit it."
        let h = NotesHarness(finalText: { n in (0..<12).map { "\(sentence) Point \(n).\($0)." }.joined(separator: " ") })
        h.http.answerStructure(.rejected("novel_name"))
        await h.record()
        await segment(h)
        await h.until("split") { h.http.structureRequests.count == 3 }
        await h.until("applied") { h.text.contains("Point 0.11") }
        let parts = h.http.structureRequests.map(\.text)
        #expect(parts[1] + " " + parts[2] == parts[0] || parts[1] + "\n" + parts[2] == parts[0] || parts[1] + parts[2] == parts[0])
        #expect(!h.text.contains(NotesDocument.fallbackHeader))
        await h.stop()
        h.expectEditorInSync()
    }

    @Test(arguments: [(404, StructuringOff.unsupported), (409, .correctionOff)])
    func aMissingOrOffEndpointTurnsStructuringOff(status: Int, off: StructuringOff) async {
        let h = NotesHarness()
        h.http.answerStructure(.status(status))
        await h.record()
        await segment(h)
        await h.until("off") { h.recorder.structuring == .off(off) }
        h.expectStatus(NotesStatus.listening)
        await h.typeAtEnd("my note")
        #expect(h.text.hasSuffix("my note"))
        await segment(h)
        await h.stop()
        #expect(h.http.structureRequests.count == 1)
        #expect(h.transcript == ["Segment 0.", "Segment 1.", "Segment 2."])
        h.expectEditorInSync()
    }

    // MARK: reorganize and the editor

    private func stoppedWithNotes(reorganize: Bool = true) async -> NotesHarness {
        // Organize needs `NotesDocument.minReorganizeChars` of notes.
        let h = NotesHarness(health: Health(correction: "available", notesStructure: true, notesCorrection: true, notesReorganize: reorganize),
                             finalText: { "Segment \($0): we agreed to ship the beta on Friday and to review the budget next week." })
        h.prefs.notesAutoReorganize = false
        h.session.model.onAutoReorganizeToggle(false)
        await h.record()
        await segment(h)
        await h.stop()
        await h.until("notes") { h.text.contains("- Segment 1:") }
        return h
    }

    @Test func typingDuringOrganizeIsAConflictAndKeepsTheTyping() async {
        let h = await stoppedWithNotes()
        h.http.hold = true
        h.model.onReorganize()
        await h.until("organizing") { h.http.waiting == 1 }
        await h.typeAtEnd("\nmine")
        h.http.release()
        await h.until("done") { !h.recorder.passInFlight }
        #expect(h.recorder.reorganizeStatus == .conflict)
        #expect(h.model.reorganizeNote == "Notes changed while organizing — try again")
        #expect(h.text.hasSuffix("\nmine"))
        h.expectEditorInSync()
    }

    @Test func composingDuringOrganizeDiscardsIt() async {
        let h = await stoppedWithNotes()
        let before = h.text
        h.http.hold = true
        h.model.onReorganize()
        await h.until("organizing") { h.http.waiting == 1 }
        let end = (h.text as NSString).length
        h.editor.textView.setSelectedRange(NSRange(location: end, length: 0))
        h.editor.textView.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: end, length: 0))
        h.http.release()
        await h.until("done") { !h.recorder.passInFlight }
        #expect(h.recorder.reorganizeStatus == .conflict)
        h.editor.textView.unmarkText()
        await h.settle()
        #expect(h.text.hasPrefix(before))
        h.expectEditorInSync()
    }

    @Test func anOrganizeFromBeforeNewNeverLands() async {
        let h = await stoppedWithNotes()
        h.http.hold = true
        h.model.onReorganize()
        await h.until("organizing") { h.http.waiting == 1 }
        h.session.reset()
        await h.settle()
        h.http.release()
        await h.settle()
        #expect(h.text.isEmpty && h.document.segments.isEmpty)
        #expect(h.recorder.reorganizeStatus != .running)
        h.expectEditorInSync()
    }

    @Test func oneUndoTakesBackAnOrganize() async {
        let h = await stoppedWithNotes()
        let before = h.text
        h.http.answerReorganize(.ok("## Summary\n- Two segments"))
        h.model.onReorganize()
        await h.until("applied") { h.text.contains("## Summary") }
        #expect(h.edges.announcements.contains(NotesStatus.reorganized))
        await h.undo()
        #expect(h.text == before)
        await h.redo()
        #expect(h.text.contains("## Summary"))
        h.expectEditorInSync()
    }

    @Test func anAppendDuringUndoAndRedoReplaysOntoTheRightText() async {
        let h = NotesHarness()
        await h.record()
        await segment(h)
        await h.until("first append") { h.text.contains("- Segment 0.") }
        await h.typeAtEnd("\nmy note")
        await h.undo()
        #expect(!h.text.contains("my note"))
        await h.advance(NotesRecorder.minInterval)
        await segment(h)
        await h.until("second append") { h.text.contains("- Segment 1.") }
        h.expectEditorInSync()
        await h.redo()
        h.expectEditorInSync()
        await h.stop()
        #expect(h.text.contains("- Segment 0.") && h.text.contains("- Segment 1."))
        h.expectEditorInSync()
    }

    // MARK: the microphone

    @Test func aLostDeviceFallsBackToTheNextInput() async {
        let h = NotesHarness()
        h.engine.fallbacks = ["MacBook Pro Microphone"]
        await h.record()
        await h.speak(2)
        h.engine.changeDevice(replacement: false)
        await h.settle()
        #expect(h.recorder.state == .recording && h.session.isCapturing)
        h.expectStatus(NotesStatus.switchedMic("MacBook Pro Microphone"))
        let before = h.streams.audioBytes
        await h.speak(2)
        #expect(h.streams.audioBytes > before)
        await h.advance(NotesSession.switchedNoticeFor)
        h.fireTick()
        h.expectStatus(NotesStatus.listening)
        await h.stop()
        #expect(h.transcript == ["Segment 0."])
    }

    @Test func withNoInputLeftNotesWaitsAndANewDeviceResumes() async {
        let h = NotesHarness()
        await h.record()
        await h.speak(2)
        h.engine.changeDevice(replacement: false)
        await h.settle()
        #expect(h.recorder.state == .recording)
        h.expectStatus(NotesStatus.noMic)
        #expect(h.model.micNote == NotesStatus.noMic)
        let before = h.streams.audioBytes
        h.engine.changeDevice(replacement: true, name: "Studio Microphone")
        await h.settle()
        h.expectStatus(NotesStatus.switchedMic("Studio Microphone"))
        await h.speak(2)
        #expect(h.streams.audioBytes > before)
        await h.stop()
        #expect(h.transcript == ["Segment 0."])
    }

    @Test func digitalSilenceWarns() async {
        let h = NotesHarness()
        await h.record()
        await h.speak(2).mute(2)
        #expect(h.recorder.state == .recording)
        h.expectStatus(NotesStatus.micSilent)
        #expect(h.model.micNote == NotesStatus.micSilent)
        await h.speak(1)
        h.expectStatus(NotesStatus.listening)
        #expect(h.model.micNote == nil)
        await h.stop()
        #expect(h.recorder.state == .stopped)
    }

    /// The 15 min itself runs through the sink alone (`NotesCaptureSinkTests`); here a shorter limit, end to end.
    @Test func longDigitalSilencePauses() async {
        let h = NotesHarness(silencePause: 60)
        await h.record()
        await h.speak(2).mute(55)
        #expect(h.recorder.state == .recording)
        await h.mute(6)
        await h.until("paused") { h.recorder.state == .paused }
        #expect(!h.session.isCapturing && h.status.hasPrefix(NotesStatus.silencePause))
        #expect(!h.document.segments.isEmpty)
    }

    // MARK: sleep, quit, crash

    @Test func sleepPausesAndWakeResumes() async {
        let h = NotesHarness()
        await h.record()
        await segment(h)
        h.workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        await h.until("paused") { h.recorder.state == .paused }
        #expect(!h.session.isCapturing && h.status.hasPrefix(NotesStatus.sleptPause))
        h.streams.dropAll()
        await h.advance(300)
        h.workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        await h.until("recording") { h.recorder.state == .recording && h.session.isCapturing }
        await h.speak(2)
        await h.stop()
        #expect(h.gaps == 0 && h.transcript.count == 3)
    }

    @Test func wakeLeavesAPauseTheUserMadeAlone() async {
        let h = NotesHarness()
        await h.record()
        await h.speak(2)
        await h.session.pause()
        h.workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        h.workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        await h.settle()
        #expect(h.recorder.state == .paused)
        await h.stop()
    }

    /// The crash equivalent: the session never gets `stopForQuit`, and a relaunch (a second session on the same
    /// journal) offers what was journaled.
    @Test func aSessionDroppedWithoutQuitIsRecovered() async {
        let h = NotesHarness()
        await h.record()
        await segment(h)
        await h.typeAtEnd("\nmy note")
        await h.advance(NotesJournal.debounce.inSeconds)
        await h.session.journal.settle()
        let next = NotesHarness(journalDirectory: h.journalDirectory)
        #expect(next.session.checkRecovery())
        next.session.keepRecovered()
        await next.settle()
        #expect(next.document.text == h.document.text && next.text == h.document.text)
        #expect(next.text.contains("my note"))
        #expect(next.transcript == ["Segment 0."])
        #expect(next.recorder.state == .stopped && next.document.isDirty)
        await h.stop()
    }

    @Test func quitWhileFinishingLeavesTheJournalForTheNextLaunch() async {
        let h = NotesHarness()
        h.streams.script(1, SocketScript(stop: .stall))
        await h.record()
        await segment(h)
        let quit = Task { await h.session.stopForQuit(limit: .seconds(5)) }
        await h.until("finishing") { h.recorder.state == .stopping }
        await h.advance(5)
        await quit.value
        await h.session.journal.settle()
        #expect(!h.session.isActive)
        let next = NotesHarness(journalDirectory: h.journalDirectory)
        #expect(next.session.checkRecovery())
        #expect(next.session.offeredDocument?.text == h.document.text)
        #expect(next.session.offeredDocument?.segments.map(\.text) == ["Segment 0."])
    }
}

private extension StructuringStatus {
    var isFailure: Bool { if case .failed = self { true } else { false } }
}
