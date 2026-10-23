import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

/// `LocalSetupSession` against fake `chirp-server setup` scripts: every stale, broken or hostile helper ends in an
/// error state in the window (#77: a stale helper used to abort the app with an exclusivity violation).
@MainActor @Suite(.serialized) struct LocalSetupSessionTests {
    private static let status = #"{"event":"status","models":[{"id":"speech","title":"Parakeet","ready":false},{"id":"cleanup","title":"Qwen","ready":false}],"correction_mode":"managed","server_running":false}"#
    private static let catalog = #"{"event":"catalog","active_models":{"speech":"v2"},"restart_required":false,"options":[{"id":"v2","kind":"speech","title":"English","repository":"o/v2","revision":"a","size_bytes":1,"details":"","license":"","ready":true,"active":false},{"id":"v3","kind":"speech","title":"Multi","repository":"o/v3","revision":"b","size_bytes":1,"details":"","license":"","ready":false,"active":false}]}"#

    /// A fake helper: `status` answers like a current server unless `status` is given; any other action runs `body`.
    private func helper(_ body: String, status: String? = nil) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("chirp-server")
        let script = """
        #!/bin/sh
        case " $* " in
        *" setup status "*) \(status ?? "echo '\(Self.status)'; echo '\(Self.catalog)'") ;;
        *) \(body) ;;
        esac
        """
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func session(_ executable: URL?, loopback: Bool = true, timeout: Duration = .seconds(10)) -> LocalSetupSession {
        LocalSetupSession(host: .init(isLoopback: { loopback }, port: { 7899 }, executable: { executable },
                                      correction: { false }, enableCorrection: {}, timeout: { _ in timeout }))
    }

    /// Generous like the recorder suites: the snapshot renderer holds the main actor for seconds in a full run.
    private func settle(_ session: LocalSetupSession) async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        while !session.isIdle {
            #expect(ContinuousClock.now < deadline, "setup job never finished"); if ContinuousClock.now >= deadline { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func staleHelperThatPrintsNothingFailsTheDownloadInsteadOfCrashing() async throws {
        // An older chirp-server: argparse rejects `setup`/`--choice` on stderr and exits 2, no JSON at all.
        let s = session(try helper("echo 'usage: chirp-server' >&2; exit 2", status: "exit 2"))
        s.download(.speech)
        try await settle(s)
        #expect(s.state.models[.speech]?.phase == "error")
        #expect(s.state.models[.speech]?.message == "Update chirp-server to use in-app model setup, then retry.")
        #expect(s.state.message == "Update chirp-server to use in-app model setup, then retry.")
        #expect(s.state.errorMessage == s.state.message)
    }

    @Test func staleHelperFailsUseModelAndRestartWithoutCrashing() async throws {
        let s = session(try helper("exit 1"))
        s.run("status")
        try await settle(s)
        s.pick(.speech, choice: "v3")
        s.pick(.speech, choice: "v2")
        #expect(s.state.option(.speech)?.ready == true)
        s.download(.speech) // ready → "select" (Use Model)
        #expect(s.state.models[.speech]?.phase == "verifying")
        try await settle(s)
        #expect(s.state.models[.speech]?.phase == "error") // stays failed though the files are cached; Retry verifies again
        s.start()
        try await settle(s)
        #expect(!s.state.starting)
    }

    @Test func missingHelperFailsEveryActionInPlace() {
        let s = session(nil)
        s.download(.cleanup)
        #expect(s.state.models[.cleanup]?.phase == "error")
        #expect(s.state.models[.cleanup]?.message == "Install chirp-server to set up models on this Mac.")
        s.start()
        #expect(!s.state.starting && s.isIdle)
        s.checkUpdates(); s.add("owner/model", model: .speech)
        #expect(!s.state.catalogBusy && s.isIdle)
    }

    @Test func remoteServerAndUnlaunchableHelperFailInPlace() throws {
        let remote = session(try helper("exit 0"), loopback: false)
        remote.download(.speech)
        #expect(remote.state.models[.speech]?.phase == "error")
        #expect(remote.state.message == "Choose This Mac as your server to manage local models.")
        let notExecutable = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-missing-\(UUID().uuidString)")
        let broken = session(notExecutable)
        broken.download(.speech)
        #expect(broken.state.models[.speech]?.phase == "error")
        #expect(broken.state.errorMessage == "Could not launch local setup. Reinstall chirp-server and retry.")
        #expect(broken.isIdle)
    }

    @Test func garbledAndUnknownLinesAreIgnored() async throws {
        let lines = [#"{"event":"progress","model":"speech","phase":"downloading","completed_bytes":5,"total_bytes":10}"#,
                     "not json", #"{"event":"progress","model":"onnx"}"#, #"{"model":"speech"}"#, "\u{1}\u{2}{{{",
                     #"{"event":"progress","model":"speech","phase":"downloading","completed_bytes":-5,"total_bytes":-1}"#,
                     #"{"event":"mystery"}"#, #"{"event":"error","model":null}"#, #"{"event":"complete","model":"speech"}"#]
        let s = session(try helper(lines.map { "printf '%s\\n' '\($0)'" }.joined(separator: "; ") + "; printf '{\"event\":'"))
        s.download(.speech)
        try await settle(s)
        #expect(s.state.models[.speech]?.phase == "complete")
        let view = LocalModelsView(); view.apply(s.state)
    }

    @Test func sensevoiceErrorLandsOnTheModelRow() async throws {
        let error = #"{"event":"error","model":"speech","message":"SenseVoice is configured."}"#
        let s = session(try helper("echo '\(error)'; exit 1"))
        s.start()
        try await settle(s)
        #expect(!s.state.starting)
        #expect(s.state.models[.speech]?.phase == "error")
    }

    @Test func overlongLineAndHungHelperAreStopped() async throws {
        let flood = session(try helper("head -c 400000 /dev/zero | tr '\\0' 'a'; sleep 30"))
        flood.download(.speech)
        try await settle(flood)
        #expect(flood.state.models[.speech]?.phase == "error")
        let hung = session(try helper("sleep 30", status: "sleep 30"), timeout: .milliseconds(200))
        hung.run("status")
        try await settle(hung)
        #expect(hung.state.message == "Update chirp-server to use in-app model setup, then retry.")
    }

    @Test func pausingADownloadMarksItCancelled() async throws {
        let progress = #"{"event":"progress","model":"cleanup","phase":"downloading","completed_bytes":1,"total_bytes":10}"#
        let s = session(try helper("echo '\(progress)'; trap 'exit 130' INT; while :; do sleep 0.05; done"))
        s.download(.cleanup)
        let deadline = ContinuousClock.now + .seconds(30) // a 4 KB-blocking read would never deliver it before EOF
        while s.state.models[.cleanup]?.phase != "downloading", ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(s.state.models[.cleanup]?.phase == "downloading")
        s.download(.cleanup) // Pause
        #expect(s.state.models[.cleanup]?.phase == "cancelling")
        try await settle(s)
        #expect(s.state.models[.cleanup]?.phase == "cancelled")
    }

    @Test func finishNeverTrapsOnAnyActionOrModel() {
        for action in ["status", "refresh", "add", "download", "select", "start", "bogus"] {
            for model in [nil] + LocalModel.allCases.map(Optional.some) {
                for sawEvent in [false, true] {
                    var state = LocalModelsState()
                    state.models = [:]
                    state.finish(action, model: model, code: 1, sawEvent: sawEvent, interrupted: false)
                    if ["download", "select"].contains(action), let model { #expect(state.models[model]?.phase == "error") }
                }
            }
        }
    }

    @Test func duplicateOptionTitlesDoNotBreakThePicker() throws {
        var state = LocalModelsState()
        state.options = [LocalModelOption(id: "a", kind: .speech, title: "Same", repository: "o/a", revision: "1"),
                         LocalModelOption(id: "b", kind: .speech, title: "Same", repository: "o/b", revision: "2")]
        state.choices[.speech] = "b"
        let view = LocalModelsView()
        view.apply(state); view.apply(state)
        #expect(view.speechPicker.numberOfItems == 2)
        #expect(view.speechPicker.selectedItem?.representedObject as? String == "b")
    }
}
