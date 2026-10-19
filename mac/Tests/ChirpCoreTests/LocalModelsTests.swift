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
    private func catalogEvent() throws -> LocalSetupEvent {
        let json = #"{"event":"catalog","active_models":{"speech":"v2","cleanup":""},"restart_required":false,"options":[{"id":"v2","kind":"speech","title":"English","repository":"mlx-community/parakeet-v2","revision":"aaaaaaa","size_bytes":2400000000,"details":"English","license":"cc-by-4.0","ready":true,"active":true},{"id":"v3","kind":"speech","title":"Multilingual","repository":"mlx-community/parakeet-v3","revision":"bbbbbbb","size_bytes":2500000000,"details":"25 languages","license":"cc-by-4.0","ready":false,"active":false},{"id":"qwen","kind":"cleanup","title":"Qwen","repository":"mlx-community/qwen","revision":"ccccccc","size_bytes":2200000000,"details":"Correction","license":"apache-2.0","ready":true,"active":false}]}"#
        return try LocalSetupEvent.decode(Data(json.utf8))
    }

    @Test func catalogChoicesDoNotApplyOrEnableCorrectionAutomatically() throws {
        var state = LocalModelsState()
        state.apply(try catalogEvent())
        #expect(state.choices[.speech] == "v2")
        #expect(state.choices[.cleanup] == "qwen")
        #expect(!state.correctionEnabled && !state.restartRequired)
        state.pick(.speech, choice: "v3")
        #expect(state.activeModels["speech"] == "v2")
        #expect(state.models[.speech]?.ready == false)
        state.apply(try LocalSetupEvent.decode(Data(#"{"event":"progress","model":"speech","phase":"downloading","completed_bytes":30,"total_bytes":100}"#.utf8)))
        state.apply(try catalogEvent())
        #expect(state.choices[.speech] == "v3")
        #expect(state.models[.speech]?.fraction == 0.3)
        #expect(!state.restartRequired)
    }

    @MainActor @Test func pickerOffersCachedModelWithoutChangingTheRunningServer() throws {
        let view = LocalModelsView()
        var state = LocalModelsState()
        state.apply(try catalogEvent())
        state.serverRunning = true
        view.apply(state)
        #expect(view.speechPicker.numberOfItems == 2)
        #expect(view.cleanupPicker.numberOfItems == 1)
        #expect(view.speech.title == "Selected" && !view.speech.isEnabled)
        #expect(view.cleanup.title == "Use Model" && view.cleanup.isEnabled)
        #expect(!view.start.isEnabled)
        state.apply(try LocalSetupEvent.decode(Data(#"{"event":"selected","model":"cleanup","choice":"qwen"}"#.utf8)))
        view.apply(state)
        #expect(view.start.isEnabled && view.start.title == "Apply & Restart Server")
        state.models[.cleanup]?.phase = "verifying"
        view.apply(state)
        #expect(!view.start.isEnabled && !view.cleanupPicker.isEnabled)
        #expect(view.cleanup.title == "Checking…")
    }

    @Test func cachedFilesDoNotHideAFailedModelLoad() throws {
        var state = LocalModelsState()
        state.apply(try catalogEvent())
        state.apply(try LocalSetupEvent.decode(Data(#"{"event":"error","model":"cleanup","message":"Model did not load. Previous selection kept."}"#.utf8)))
        state.apply(try catalogEvent())
        #expect(state.models[.cleanup]?.phase == "error")
        #expect(state.models[.cleanup]?.detail.contains("Previous selection kept") == true)
        #expect(state.option(.cleanup)?.ready == true)  // Retry verifies cached files again.
    }

}
