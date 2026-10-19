import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

@Suite struct LocalModelsTests {
    @Test func byteProgressUsesHelperCountsAndDoesNotBecomeReadyAt100Percent() throws {
        var state = LocalModelsState()
        let data = Data(#"{"event":"progress","model":"speech","phase":"downloading","completed_bytes":50,"total_bytes":100}"#.utf8)
        state.apply(try LocalSetupEvent.decode(data))
        #expect(state.models[.speech]?.fraction == 0.5)
        #expect(state.models[.speech]?.detail.hasPrefix("50%") == true)
        #expect(state.models[.speech]?.ready == false)
        state.apply(try LocalSetupEvent.decode(Data(#"{"event":"complete","model":"speech"}"#.utf8)))
        #expect(state.models[.speech]?.ready == true)
    }

    @Test func unknownTotalIsIndeterminateAndCountsAreClamped() {
        var row = LocalModelProgress()
        row.phase = "preparing"
        #expect(row.fraction == nil)
        row.total = 10; row.completed = 20
        #expect(row.fraction == 1)
        row.completed = -10
        #expect(row.fraction == 0)
    }

    @Test func statusDoesNotEraseAnActiveDownloadAndQwenStaysIndependent() throws {
        var state = LocalModelsState()
        state.models[.cleanup]?.phase = "downloading"
        let json = #"{"event":"status","models":[{"id":"speech","title":"Parakeet","ready":true},{"id":"cleanup","title":"Qwen","ready":false}],"correction_mode":"managed","server_running":false}"#
        state.apply(try LocalSetupEvent.decode(Data(json.utf8)))
        #expect(state.models[.speech]?.ready == true)
        #expect(state.models[.cleanup]?.busy == true)
        #expect(state.correctionMode == "managed")
    }

    @Test func cancellationAndErrorsCanBeRetriedWithoutClaimingReadiness() throws {
        var state = LocalModelsState()
        for event in [#"{"event":"cancelled","model":"cleanup"}"#,
                      #"{"event":"error","model":"cleanup","message":"Retry download"}"#] {
            state.apply(try LocalSetupEvent.decode(Data(event.utf8)))
            #expect(state.models[.cleanup]?.ready == false)
            #expect(state.models[.cleanup]?.busy == false)
        }
        #expect(state.models[.cleanup]?.detail == "Retry download")
        state.apply(try LocalSetupEvent.decode(Data(#"{"event":"status","models":[{"id":"cleanup","title":"Qwen","ready":false}]}"#.utf8)))
        #expect(state.models[.cleanup]?.detail == "Retry download")
    }

    @MainActor @Test func localOnboardingOffersModelSetupAndRemoteKeepsDiagnostics() {
        let view = OnboardingView(icon: nil)
        var state = OnboardingState(step: .server)
        state.localModelsAvailable = true
        view.apply(state)
        #expect(!view.fix.isHidden && view.fix.title == "Set Up Models…")
        state.localModelsAvailable = false
        state.checks.server = .unreachable(host: "remote.example")
        view.apply(state)
        #expect(view.fix.title == "Copy Fix Command")
    }

    @MainActor @Test func viewShowsPauseAndResumeAndGatesServerOnSpeechReadiness() {
        let view = LocalModelsView()
        var state = LocalModelsState()
        state.models[.speech]?.phase = "downloading"
        state.models[.speech]?.total = 100
        state.models[.speech]?.completed = 40
        view.apply(state)
        #expect(view.speech.title == "Pause")
        #expect(!view.start.isEnabled)
        state.models[.speech]?.phase = "complete"
        state.models[.cleanup]?.phase = "cancelled"
        view.apply(state)
        #expect(view.speech.title == "Downloaded")
        #expect(view.cleanup.title == "Resume")
        #expect(view.start.isEnabled)
        #expect(!view.correction.isEnabled)
        state.correctionMode = "managed"
        state.correctionEnabled = true
        view.apply(state)
        #expect(view.correction.isEnabled && view.correction.state == .on)
    }
}
