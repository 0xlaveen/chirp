import AppKit
import ChirpCore
import ChirpUI

/// Process and pipe are configured before the reader starts. Cancellation uses
/// Process's thread-safe signal API; only the reader consumes stdout.
private final class SetupProcess: @unchecked Sendable {
    let process = Process()
    let output = Pipe()
}

@MainActor
final class LocalModelsWindowController: NSObject {
    var onServerChanged: (() -> Void)?
    private var state = LocalModelsState()
    private var window: NSWindow?
    private var view: LocalModelsView?
    private var jobs: [String: (id: UUID, child: SetupProcess)] = [:]

    func stop() {
        for job in jobs.values where job.child.process.isRunning { job.child.process.interrupt() }
    }

    func show() {
        guard settings.serverConfig().isLoopback else { return }
        if window == nil {
            let v = LocalModelsView()
            v.speech.target = self; v.speech.action = #selector(speechPressed)
            v.cleanup.target = self; v.cleanup.action = #selector(cleanupPressed)
            v.start.target = self; v.start.action = #selector(startPressed)
            v.correction.target = self; v.correction.action = #selector(correctionPressed(_:))
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: LocalModelsView.size),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Chirp Models"; w.contentView = v; w.isReleasedWhenClosed = false; w.center()
            view = v; window = w
        }
        refresh()
        run("status")
        NSApp.activate(); window?.makeKeyAndOrderFront(nil)
    }

    private func refresh() {
        state.correctionEnabled = settings.correction
        view?.apply(state)
    }

    @objc private func speechPressed() { download(.speech) }
    @objc private func cleanupPressed() { download(.cleanup) }
    @objc private func startPressed() {
        state.starting = true; state.message = "Starting the local speech server…"; refresh()
        run("start")
    }
    @objc private func correctionPressed(_ sender: NSButton) {
        settings.correction = sender.state == .on
        refresh()
    }

    private func download(_ model: LocalModel) {
        let key = model.rawValue
        if let child = jobs[key]?.child, child.process.isRunning {
            state.models[model]?.phase = "cancelling"; refresh()
            child.process.interrupt() // HF keeps partial files for the next attempt.
            return
        }
        state.models[model]?.phase = "preparing"
        state.models[model]?.message = nil
        refresh()
        run("download", model: model)
    }

    private func executable() -> URL? {
        if let path = ProcessInfo.processInfo.environment["CHIRP_SERVER_EXECUTABLE"],
           path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = ["/run/current-system/sw/bin/chirp-server", home.appendingPathComponent(".local/bin/chirp-server").path,
                          home.appendingPathComponent(".local/share/chirp/src/server/.venv/bin/chirp-server").path,
                          home.appendingPathComponent("Documents/Programming/chirp/server/.venv/bin/chirp-server").path]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/chirp-server" }
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    private func run(_ action: String, model: LocalModel? = nil) {
        guard settings.serverConfig().isLoopback else { return }
        let key = model?.rawValue ?? action
        guard jobs[key] == nil else { return }
        if action != "status" { state.errorMessage = nil }
        guard let executable = executable() else {
            state.message = "Install chirp-server to set up models on this Mac."
            state.starting = false
            if let model { state.models[model]?.phase = "error"; state.models[model]?.message = state.message }
            refresh(); return
        }
        let child = SetupProcess()
        let id = UUID()
        child.process.executableURL = executable
        let port = settings.serverConfig().baseURL.port ?? 7821
        child.process.arguments = ["--port", String(port), "setup", action] + (model.map { ["--model", $0.rawValue] } ?? [])
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        child.process.environment = environment
        child.process.standardOutput = child.output
        child.process.standardError = FileHandle.nullDevice
        child.process.standardInput = FileHandle.nullDevice
        do { try child.process.run() } catch {
            state.message = "Could not launch local setup. Reinstall chirp-server and retry."
            state.errorMessage = state.message
            if let model { state.models[model]?.phase = "error"; state.models[model]?.message = state.message }
            state.starting = false; refresh(); return
        }
        jobs[key] = (id, child)
        Task.detached(priority: .utility) { [weak self, child] in
            var buffer = Data()
            var sawEvent = false
            do {
                while let data = try child.output.fileHandleForReading.read(upToCount: 4096), !data.isEmpty {
                    buffer.append(data)
                    guard buffer.count <= 256 * 1024 else { child.process.terminate(); break }
                    while let newline = buffer.firstIndex(of: 10) {
                        let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                        if let event = try? LocalSetupEvent.decode(line) {
                            sawEvent = true
                            await self?.receive(event, key: key, id: id)
                        }
                    }
                }
            } catch { if child.process.isRunning { child.process.terminate() } }
            child.process.waitUntilExit()
            await self?.finished(key: key, id: id, action: action, model: model,
                                 code: child.process.terminationStatus, sawEvent: sawEvent,
                                 interrupted: child.process.terminationReason == .uncaughtSignal && child.process.terminationStatus == 2)
        }
        // Read-only discovery and startup must not leave a permanently spinning UI.
        if action != "download" {
            Task { [weak self, child] in
                try? await Task.sleep(for: .seconds(action == "start" ? 80 : 15))
                guard self?.jobs[key]?.id == id, child.process.isRunning else { return }
                child.process.terminate()
            }
        }
    }

    private func receive(_ event: LocalSetupEvent, key: String, id: UUID) {
        guard jobs[key]?.id == id else { return }
        if let model = event.model, state.models[model]?.phase == "cancelling", event.event == "progress" { return }
        state.apply(event); refresh()
    }

    private func finished(key: String, id: UUID, action: String, model: LocalModel?, code: Int32, sawEvent: Bool, interrupted: Bool) {
        guard jobs[key]?.id == id else { return }
        jobs.removeValue(forKey: key)
        if action == "start" { state.starting = false }
        if !sawEvent {
            state.message = "Update chirp-server to use in-app model setup, then retry."
        }
        if let model, !state.models[model, default: .init()].ready {
            if code == 130 || interrupted { state.models[model]?.phase = "cancelled" }
            else if state.models[model]?.phase != "error" {
                state.models[model]?.phase = "error"
                state.models[model]?.message = sawEvent ? "Download stopped. Retry to continue." : state.message
            }
        }
        refresh()
        if action != "status" { onServerChanged?(); run("status") }
    }
}
