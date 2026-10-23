import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

/// SenseVoice in the picker (#84), against a fake `chirp-server setup` that keeps its selection in a file the way the
/// real helper keeps model-selection.json.
@MainActor @Suite(.serialized) struct LocalModelsEngineTests {
    private static func option(_ id: String, _ engine: String, ready: Bool, active: Bool) -> String {
        #"{"id":"\#(id)","kind":"speech","title":"\#(id)","repository":"o/\#(id)","revision":"a","size_bytes":1,"details":"","license":"","ready":\#(ready),"active":\#(active),"engine":"\#(engine)"}"#
    }

    /// `status` lists v2 (MLX, cached) and SenseVoice (not yet downloaded until `download` runs); `select` saves the
    /// choice; `download` reports the runtime install before byte progress.
    private func helper() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-engines-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("chirp-server")
        let catalog = { (sv: String, active: String) in
            #"{"event":"catalog","active_models":{"speech":"\#(active)","cleanup":""},"restart_required":\#(active == "parakeet-v2" ? "false" : "true"),"options":[\#(Self.option("parakeet-v2", "mlx", ready: true, active: active == "parakeet-v2")),\#(Self.option("sensevoice-small", "sensevoice", ready: sv == "true", active: active == "sensevoice-small"))]}"#
        }
        let script = """
        #!/bin/sh
        D="$(dirname "$0")"; SV=$(cat "$D/sv" 2>/dev/null || echo false); ACTIVE=$(cat "$D/active" 2>/dev/null || echo parakeet-v2)
        catalog() { case "$SV$ACTIVE" in \
          falseparakeet-v2) echo '\(catalog("false", "parakeet-v2"))';; trueparakeet-v2) echo '\(catalog("true", "parakeet-v2"))';; \
          *) echo '\(catalog("true", "sensevoice-small"))';; esac; }
        case " $* " in
        *" status "*) echo '{"event":"status","models":[],"correction_mode":"off","server_running":true}'; catalog ;;
        *" download "*) echo '{"event":"progress","model":"speech","phase":"preparing"}'
           echo '{"event":"progress","model":"speech","phase":"installing"}'; sleep 0.3
           echo '{"event":"progress","model":"speech","phase":"downloading","completed_bytes":5,"total_bytes":10}'
           echo true > "$D/sv"; echo '{"event":"complete","model":"speech"}' ;;
        *" select "*) shift 6; echo "$2" > "$D/active"; ACTIVE=$2
           echo '{"event":"progress","model":"speech","phase":"verifying"}'
           echo "{\\"event\\":\\"selected\\",\\"model\\":\\"speech\\",\\"choice\\":\\"$2\\"}"; catalog ;;
        *) exit 2 ;;
        esac
        """
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func settle(_ session: LocalSetupSession) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !session.isIdle, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(session.isIdle)
    }

    @Test func listsDownloadsSelectsAndSwitchesEnginesBothWays() async throws {
        let session = LocalSetupSession(host: .init(isLoopback: { true }, port: { 7899 }, executable: { [url = try helper()] in url },
                                                     correction: { false }, enableCorrection: {}))
        let view = LocalModelsView()
        var phases: [String] = []
        session.onChange = { state in view.apply(state); phases.append(state.models[.speech]?.phase ?? "") }
        session.run("status")
        try await settle(session)
        #expect(session.state.options.map(\.engine) == ["mlx", "sensevoice"])
        #expect(view.speechPicker.itemTitles.contains("SenseVoice · CPU"))
        #expect(view.speechPicker.selectedItem?.representedObject as? String == "parakeet-v2")

        session.pick(.speech, choice: "sensevoice-small")
        #expect(view.speech.title == "Download")
        session.download(.speech)
        try await settle(session)
        #expect(phases.contains("installing") && phases.contains("downloading"))
        #expect(session.state.option(.speech)?.ready == true && view.speech.title == "Use Model")

        session.download(.speech) // Use Model → select
        try await settle(session)
        #expect(session.state.activeModels["speech"] == "sensevoice-small")
        #expect(session.state.restartRequired)
        #expect(view.start.isEnabled && view.start.title == "Apply & Restart Server")
        #expect(view.speechPicker.selectedItem?.representedObject as? String == "sensevoice-small")

        session.pick(.speech, choice: "parakeet-v2")
        #expect(view.speech.title == "Use Model")
        session.download(.speech)
        try await settle(session)
        #expect(session.state.activeModels["speech"] == "parakeet-v2")
        #expect(view.speech.title == "Selected")
    }

    @Test func installingIsBusyAndExplainsTheRuntime() {
        var row = LocalModelProgress()
        row.phase = "installing"
        #expect(row.busy && !row.ready && row.fraction == nil)
        #expect(row.detail.contains("SenseVoice runtime"))
        let view = LocalModelsView()
        var state = LocalModelsState()
        state.models[.speech] = row
        view.apply(state)
        #expect(view.speech.title == "Pause" && !view.speechPicker.isEnabled && !view.start.isEnabled)
    }

    @Test func olderHelpersWithoutEnginesKeepAFlatPicker() throws {
        let json = #"{"event":"catalog","options":[{"id":"v2","kind":"speech","title":"English","repository":"o/v2","revision":"a","size_bytes":1,"details":"","license":"","ready":true,"active":true}]}"#
        var state = LocalModelsState()
        state.apply(try LocalSetupEvent.decode(Data(json.utf8)))
        #expect(state.options.first?.engine == nil && state.options.first?.engineSection == "Parakeet · MLX on Apple silicon")
        let view = LocalModelsView()
        view.apply(state)
        #expect(view.speechPicker.itemTitles == [state.options[0].label])
    }

    @Test func sectionsGroupAddedMlxModelsWithParakeetAndSkipHeadersOnSelection() {
        var state = LocalModelsState()
        state.options = [LocalModelOption(id: "v2", kind: .speech, title: "v2", repository: "o/v2", revision: "a", engine: "mlx"),
                         LocalModelOption(id: "sv", kind: .speech, title: "sv", repository: "o/sv", revision: "b", engine: "sensevoice"),
                         LocalModelOption(id: "added", kind: .speech, title: "added", repository: "o/a", revision: "c", engine: "mlx")]
        state.choices[.speech] = "sv"
        let view = LocalModelsView()
        view.apply(state)
        #expect(view.speechPicker.itemTitles == ["Parakeet · MLX on Apple silicon", "v2", "added", "SenseVoice · CPU", "sv"])
        #expect(view.speechPicker.selectedItem?.representedObject as? String == "sv")
        let before = view.speechPicker.itemArray.map(ObjectIdentifier.init)
        view.apply(state)
        #expect(view.speechPicker.itemArray.map(ObjectIdentifier.init) == before) // No rebuild while a popup may be open.
    }
}
