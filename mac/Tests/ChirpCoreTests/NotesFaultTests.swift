import AppKit
import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

/// The fault matrix (#66, docs/research/live-notes-ux.md §3): one end-to-end test per fault, through `NotesHarness`.
/// Tests named `…Today` pin what happens now; the disabled ones describe the behaviour #62 adds, and that issue
/// enables them. The crash rows run against the recovery journal (#61).
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

    // MARK: sockets

    @Test func aSocketDropMidSegmentLeavesAGapAndRecordingContinuesToday() async {
        let h = NotesHarness()
        h.streams.script(0, SocketScript(dropAfterBytes: 5 * 32_000))
        await h.record()
        await h.speak(8)
        await h.until("gap") { h.gaps == 1 }
        #expect(h.recorder.state == .recording && h.session.isCapturing)
        await h.speak(13).pause(1)
        await h.stop()
        #expect(h.transcript.first == "⚠︎" && h.transcript.dropFirst().allSatisfy { $0.hasPrefix("Segment") })
        #expect(h.streams.started >= 2)
        h.expectStatus(NotesStatus.stopped).expectEditorInSync()
    }

    @Test(.disabled("#62: segments are retried from buffered audio, so a drop leaves no gap"))
    func aSocketDropMidSegmentLeavesNoGap() async {
        let h = NotesHarness()
        h.streams.script(0, SocketScript(dropAfterBytes: 5 * 32_000))
        await h.record()
        await h.speak(8)
        await h.stop()
        #expect(h.gaps == 0 && !h.transcript.isEmpty)
    }

    @Test func aSocketThatNeverGetsReadyLeavesAGapToday() async {
        let h = NotesHarness()
        h.streams.script(1, SocketScript(start: .stall))
        await h.record()
        await segment(h)
        await h.advance(StreamLimits().readyDeadline.inSeconds)
        await h.until("gap") { h.gaps == 1 }
        #expect(h.recorder.state == .recording)
        await h.speak(2)
        await h.stop()
        #expect(h.transcript == ["Segment 0.", "⚠︎", "Segment 2."])
    }

    @Test func aDropWhileFinalizingLeavesAGapToday() async {
        let h = NotesHarness()
        h.streams.script(0, SocketScript(stop: .drop))
        await h.record()
        await h.speak(13).pause(1)
        await h.until("gap") { h.gaps == 1 }
        await h.speak(2)
        await h.stop()
        #expect(h.transcript == ["⚠︎", "Segment 1."])
        #expect(h.recorder.state == .stopped)
    }

    @Test func aFinalThatNeverComesTimesOutIntoAGapToday() async {
        let h = NotesHarness()
        h.streams.script(0, SocketScript(stop: .stall))
        await h.record()
        await h.speak(13).pause(1).speak(2)
        await h.advance(NotesRecorder.finalTimeout)
        await h.until("gap") { h.gaps == 1 }
        await h.stop()
        #expect(h.transcript == ["⚠︎", "Segment 1."])
    }

    @Test func aBusySocketIsAGapAndThreeInARowStopToday() async {
        let h = NotesHarness()
        for i in 1...3 { h.streams.script(i, SocketScript(stop: .error("busy"))) }
        await h.record()
        // Sockets 1–3 fail on their final; the third failure lands when socket 3 is cut.
        for _ in 0..<4 { await segment(h) }
        await h.until("stopped") { isError(h) }
        #expect(h.status.hasPrefix("Notes stopped:"))
        #expect(h.transcript.first == "Segment 0." && h.gaps >= 3)
    }

    // MARK: server outages

    @Test(arguments: [10.0, 60, 600])
    func aServerOutageStopsAfterThreeFailuresToday(seconds: Double) async {
        let h = NotesHarness()
        await h.record()
        await segment(h)
        h.streams.down = true
        h.streams.dropAll()
        await h.until("stopped") { isError(h) }
        await h.advance(seconds)
        h.streams.down = false
        #expect(h.status == "Notes stopped: Server unreachable")
        #expect(h.transcript.first == "Segment 0." && h.gaps == 3)
        #expect(!h.session.isCapturing)
        h.expectEditorInSync()
    }

    @Test(.disabled("#62: audio is buffered while the server is down and sent when it is back"), arguments: [10.0, 60])
    func aShortServerOutageCatchesUp(seconds: Double) async {
        let h = NotesHarness()
        await h.record()
        await segment(h)
        h.streams.down = true
        h.streams.dropAll()
        await h.speak(seconds)
        h.streams.down = false
        await h.advance(30)
        await h.stop()
        #expect(h.gaps == 0 && h.recorder.state == .stopped)
    }

    @Test(.disabled("#62: past the buffer cap, one gap and the recording goes on"))
    func aLongServerOutageLeavesOneGap() async {
        let h = NotesHarness()
        await h.record()
        await segment(h)
        h.streams.down = true
        h.streams.dropAll()
        for _ in 0..<20 { await h.speak(29).pause(1) }
        h.streams.down = false
        await h.advance(30)
        await h.stop()
        #expect(h.gaps == 1 && h.recorder.state == .stopped)
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

    @Test(.disabled("#62: a lost device falls back to the default input"))
    func aLostDeviceFallsBackToTheDefaultInput() async {
        let h = NotesHarness()
        await h.record()
        await h.speak(2)
        h.engine.changeDevice(replacement: false)
        await h.settle()
        #expect(h.recorder.state == .recording)
    }

    @Test(.disabled("#62: digital silence warns instead of stopping"))
    func digitalSilenceWarns() async {
        let h = NotesHarness()
        await h.record()
        await h.speak(2).mute(3)
        #expect(h.recorder.state == .recording)
        #expect(h.status != NotesStatus.listening)
    }

    @Test(.disabled("#62: 15 minutes of digital silence pauses the recording"))
    func longDigitalSilencePauses() async {
        let h = NotesHarness()
        await h.record()
        await h.speak(2).mute(15 * 60)
        #expect(h.recorder.state != .recording && !h.session.isCapturing)
    }

    // MARK: sleep, quit, crash

    /// Sleep looks like every socket dying at once and the clock jumping; nothing observes it yet.
    @Test func sleepAndWakeLeaveAGapAndRecordingContinuesToday() async {
        let h = NotesHarness()
        await h.record()
        await segment(h)
        h.streams.dropAll()
        await h.advance(300)
        await h.until("gap") { h.gaps == 1 }
        #expect(h.recorder.state == .recording && h.session.isCapturing)
        await h.speak(2)
        await h.stop()
        #expect(h.transcript == ["Segment 0.", "⚠︎", "Segment 2."])
    }

    @Test(.disabled("#62: sleep pauses the recording and wake resumes it"))
    func sleepPausesAndWakeResumes() async {
        let h = NotesHarness()
        await h.record()
        await segment(h)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        h.streams.dropAll()
        await h.advance(300)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await h.speak(2)
        await h.stop()
        #expect(h.gaps == 0)
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
