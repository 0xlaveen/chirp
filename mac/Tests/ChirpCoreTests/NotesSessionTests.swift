import AVFoundation
import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

/// `NotesSession`, the glue the app's Live Notes runs on: the start order, the microphone's failures, Stop, quit and
/// the tick, with the system edges faked by `NotesHarness`.
@MainActor
@Suite(.serialized) struct NotesSessionTests {
    struct Boom: Error {}

    @Test func recordsTwoSegmentsIntoTheEditorAndStops() async {
        let h = NotesHarness()
        await h.record()
        #expect(h.edges.sounds == [.start])
        h.expectStatus(NotesStatus.listening)
        await h.speak(13).pause(1).speak(3)
        await h.until("first final") { h.document.segments.count == 1 }
        await h.stop()
        #expect(h.transcript == ["Segment 0.", "Segment 1."])
        #expect(h.recorder.state == .stopped)
        h.expectStatus(NotesStatus.stopped).expectEditorInSync()
        #expect(h.text.contains("- Segment 0.") && h.text.contains("- Segment 1."))
        #expect(h.edges.sounds == [.start, .stop])
        #expect(!h.session.isCapturing && !h.engine.isTapped)
        #expect(h.streams.bytesBySocket.keys.sorted() == [0, 1])
        #expect(h.edges.announcements.contains("Notes: \(NotesStatus.listening)"))
    }

    @Test func theTickRunsOnlyWhileActive() async {
        let h = NotesHarness()
        #expect(h.edges.tick == nil)
        await h.record()
        await h.speak(2)
        #expect(h.edges.tick != nil)
        h.fireTick()
        #expect(h.model.elapsed == h.recorder.elapsed && h.model.elapsed >= 2)
        await h.stop()
        #expect(h.edges.tick == nil)
    }

    @Test func aDeniedMicrophoneIsAnErrorAndOpensSettings() async {
        let h = NotesHarness()
        h.edges.micGranted = false
        await h.record(waitForMic: false)
        await h.until("error") { if case .error = h.model.state { true } else { false } }
        h.expectStatus("Microphone access denied — enable it in System Settings")
        #expect(h.edges.settingsOpened == 1)
        #expect(!h.engine.isTapped && h.streams.audioBytes == 0)
    }

    @Test func noInputDeviceIsAnError() async {
        let h = NotesHarness()
        h.engine.changeDevice(replacement: false)
        await h.record(waitForMic: false)
        await h.until("error") { if case .error = h.model.state { true } else { false } }
        h.expectStatus("No microphone input device")
        #expect(!h.engine.isTapped)
    }

    @Test func aMicrophoneThatWillNotStartIsAnError() async {
        let h = NotesHarness()
        h.engine.startError = Boom()
        await h.record(waitForMic: false)
        await h.until("error") { if case .error = h.model.state { true } else { false } }
        h.expectStatus("Could not start the microphone")
        #expect(!h.engine.isTapped)
    }

    @Test func losingTheInputDeviceStopsAndKeepsTheNotes() async {
        let h = NotesHarness()
        await h.record()
        await h.speak(13).pause(1).speak(2)
        await h.until("first final") { h.document.segments.count == 1 }
        h.engine.changeDevice(replacement: false)
        await h.until("error") { if case .error = h.model.state { true } else { false } }
        h.expectStatus("The microphone stopped — check the input device").expectEditorInSync()
        #expect(h.transcript == ["Segment 0.", "Segment 1."])
        #expect(!h.session.isCapturing)
    }

    @Test func aNewInputDeviceKeepsRecording() async {
        let h = NotesHarness()
        await h.record()
        await h.speak(2)
        let before = h.streams.audioBytes
        h.engine.changeDevice(replacement: true)
        await h.speak(2)
        #expect(h.recorder.state == .recording && h.session.isCapturing)
        #expect(h.streams.audioBytes > before)
        await h.stop()
        #expect(h.transcript == ["Segment 0."])
    }

    @Test func digitalSilenceStopsWithNoMicrophoneSignal() async {
        let h = NotesHarness()
        await h.record()
        await h.speak(13).pause(1).speak(1)
        await h.mute(2)
        await h.until("error") { if case .error = h.model.state { true } else { false } }
        h.expectStatus("No microphone signal")
        #expect(h.transcript == ["Segment 0.", "Segment 1."])
    }

    @Test func aDenialThatArrivesWhileFinishingIsNotAnError() async {
        let h = NotesHarness()
        h.edges.holdMic = true
        h.streams.script(0, SocketScript(stop: .stall))
        await h.record(waitForMic: false)
        await h.until("ready") { h.recorder.state == .recording && h.edges.micPromptWaiting }
        let stopping = Task { await h.session.stop() }
        await h.until("finishing") { h.recorder.state == .stopping }
        h.edges.answerMicrophone(false)
        await h.settle()
        #expect(h.recorder.state == .stopping)
        h.expectStatus(NotesStatus.finishing)
        await h.advance(NotesRecorder.finalTimeout)
        await stopping.value
        await h.settle()
        #expect(h.recorder.state == .stopped)
        #expect(h.edges.settingsOpened == 1 && !h.engine.isTapped)
    }

    @Test func quitWhileFinishingCancelsAfterTheLimitAndKeepsTheDocument() async {
        let h = NotesHarness()
        h.streams.script(1, SocketScript(stop: .stall))
        await h.record()
        await h.speak(13).pause(1).speak(2)
        await h.until("first final") { h.document.segments.count == 1 }
        let stopping = Task { await h.session.stop() }
        await h.until("finishing") { h.recorder.state == .stopping }
        let quit = Task { await h.session.stopForQuit(limit: .seconds(5)) }
        await h.settle()
        #expect(h.session.isActive)
        await h.advance(5)
        await quit.value
        await stopping.value
        #expect(!h.session.isActive)
        #expect(h.transcript == ["Segment 0."])
        #expect(h.recorder.state == .stopped)
        h.expectEditorInSync()
    }

    @Test func quitWhileRecordingFinishesGracefully() async {
        let h = NotesHarness()
        await h.record()
        await h.speak(3)
        await h.session.stopForQuit(limit: .seconds(5))
        #expect(h.transcript == ["Segment 0."] && h.recorder.state == .stopped)
        #expect(!h.engine.isTapped)
    }

    @Test func recordWhileDictatingBeepsAndDoesNothing() async {
        let h = NotesHarness()
        h.session.isDictating = { true }
        await h.record(waitForMic: false)
        #expect(h.edges.beeps == 1 && h.recorder.state == .idle && h.streams.attempts == 0)
    }

    @Test func thePausedGateRefusesToStartAndPausingStopsGracefully() async {
        let h = NotesHarness()
        await h.record()
        await h.speak(2)
        h.session.setRunning(false)
        await h.until("stopped") { h.recorder.state == .stopped }
        #expect(h.transcript == ["Segment 0."])
        await h.record(waitForMic: false)
        #expect(h.recorder.state == .stopped && h.streams.started == 1)
    }

    @Test func theFirstSocketRefusedNamesTheServer() async {
        let h = NotesHarness()
        h.streams.down = true
        await h.record(waitForMic: false)
        await h.until("error") { if case .error = h.model.state { true } else { false } }
        h.expectStatus("Server unreachable at 127.0.0.1")
        #expect(!h.engine.isTapped)
    }
}
