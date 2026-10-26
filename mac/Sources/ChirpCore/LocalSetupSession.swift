#if os(macOS)
import Foundation

/// Process and pipe are configured before the reader starts. Cancellation uses
/// Process's thread-safe signal API; only the reader consumes stdout.
private final class SetupProcess: @unchecked Sendable {
    let process = Process()
    let output = Pipe()
    /// Whatever the helper has written so far; nil at EOF or on a read error. `FileHandle.read(upToCount:)` waits for
    /// the full count on a pipe (delaying progress lines) and `availableData` raises on errors.
    func chunk() -> Data? {
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = bytes.withUnsafeMutableBytes { read(output.fileHandleForReading.fileDescriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            return count > 0 ? Data(bytes[..<count]) : nil
        }
    }
}

/// Runs `chirp-server setup <action>` jobs and folds their JSON lines into `LocalModelsState`. Every failure (no helper,
/// a launch error, a stale helper that prints no events, garbled output, a timeout) ends in an error state, never a trap.
@MainActor
public final class LocalSetupSession {
    public struct Host {
        public var isLoopback: () -> Bool
        public var port: () -> Int
        public var executable: () -> URL?
        public var correction: () -> Bool
        public var enableCorrection: () -> Void
        public var timeout: (String) -> Duration
        public init(isLoopback: @escaping () -> Bool, port: @escaping () -> Int, executable: @escaping () -> URL?,
                    correction: @escaping () -> Bool, enableCorrection: @escaping () -> Void,
                    timeout: @escaping (String) -> Duration = LocalSetupSession.timeout) {
            self.isLoopback = isLoopback; self.port = port; self.executable = executable
            self.correction = correction; self.enableCorrection = enableCorrection; self.timeout = timeout
        }
    }

    public nonisolated static let maxLine = 256 * 1024
    public nonisolated static func timeout(_ action: String) -> Duration {
        switch action { case "start": .seconds(80); case "select": .seconds(120); case "refresh": .seconds(300); case "add": .seconds(60); default: .seconds(15) }
    }

    public private(set) var state = LocalModelsState()
    public var onChange: ((LocalModelsState) -> Void)?
    public var onServerChanged: (() -> Void)?
    public var isIdle: Bool { jobs.isEmpty }
    private let host: Host
    private var jobs: [String: (id: UUID, child: SetupProcess)] = [:]

    public init(host: Host) { self.host = host }

    public func stop() {
        for job in jobs.values where job.child.process.isRunning { job.child.process.interrupt() }
    }

    public func refresh() {
        state.correctionEnabled = host.correction()
        onChange?(state)
    }

    public func pick(_ model: LocalModel, choice: String) { state.pick(model, choice: choice); refresh() }
    public func checkUpdates() { run("refresh") }
    public func add(_ repository: String, model: LocalModel) { run("add", model: model, repository: repository) }
    public func start() {
        state.starting = true; state.message = "Starting Chirp on this Mac…"; refresh()
        run("start")
    }

    public func download(_ model: LocalModel) {
        let key = model.rawValue
        if let child = jobs[key]?.child, child.process.isRunning {
            state.models[model]?.phase = "cancelling"; refresh()
            child.process.interrupt() // HF keeps partial files for the next attempt.
            return
        }
        if state.option(model)?.ready == true {
            state.models[model]?.phase = "verifying"
            refresh(); run("select", model: model); return
        }
        state.models[model]?.phase = "preparing"
        state.models[model]?.message = nil
        refresh()
        run("download", model: model)
    }

    public func run(_ action: String, model: LocalModel? = nil, repository: String? = nil) {
        guard host.isLoopback() else {
            return fail("Choose This Mac as your server to manage local models.", model: model, error: false)
        }
        let key = ["download", "select"].contains(action) ? model?.rawValue ?? action : action
        guard jobs[key] == nil else { return }
        if action != "status" { state.errorMessage = nil }
        guard let executable = host.executable() else {
            return fail("Install chirp-server to set up models on this Mac.", model: model, error: false)
        }
        let child = SetupProcess()
        let id = UUID()
        child.process.executableURL = executable
        var arguments = ["--port", String(host.port()), "setup", action] + (model.map { ["--model", $0.rawValue] } ?? [])
        if ["download", "select"].contains(action), let model, let choice = state.choices[model] { arguments += ["--choice", choice] }
        if let repository { arguments += ["--repository", repository] }
        child.process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        child.process.environment = environment
        child.process.standardOutput = child.output
        child.process.standardError = FileHandle.nullDevice
        child.process.standardInput = FileHandle.nullDevice
        do { try child.process.run() } catch {
            return fail("Could not launch local setup. Reinstall chirp-server and retry.", model: model, error: true)
        }
        jobs[key] = (id, child)
        if ["refresh", "add"].contains(action) { state.catalogBusy = true; refresh() }
        // Blocking reads and waitUntilExit stay off the shared concurrency pool; the main queue keeps events in order.
        DispatchQueue.global(qos: .utility).async { [weak self, child] in
            var buffer = Data()
            var sawEvent = false
            while let data = child.chunk() {
                buffer.append(data)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                    if let event = try? LocalSetupEvent.decode(line) {
                        sawEvent = true
                        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.receive(event, key: key, id: id) } }
                    }
                }
                guard buffer.count <= Self.maxLine else { break }
            }
            if child.process.isRunning { child.process.terminate() }
            child.process.waitUntilExit()
            let code = child.process.terminationStatus, saw = sawEvent
            let interrupted = child.process.terminationReason == .uncaughtSignal && code == 2
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.finished(key: key, id: id, action: action, model: model, code: code, sawEvent: saw, interrupted: interrupted)
                }
            }
        }
        // Read-only discovery and startup must not leave a permanently spinning UI.
        if action != "download" {
            let timeout = host.timeout(action)
            Task { [weak self, child] in
                try? await Task.sleep(for: timeout)
                guard self?.jobs[key]?.id == id, child.process.isRunning else { return }
                child.process.terminate()
            }
        }
    }

    private func fail(_ message: String, model: LocalModel?, error: Bool) {
        state.message = message
        if error { state.errorMessage = message }
        state.starting = false
        if let model { state.models[model]?.phase = "error"; state.models[model]?.message = message }
        refresh()
    }

    private func receive(_ event: LocalSetupEvent, key: String, id: UUID) {
        guard jobs[key]?.id == id else { return }
        if let model = event.model, state.models[model]?.phase == "cancelling", event.event == "progress" { return }
        if event.event == "started", event.enableCorrection == true { host.enableCorrection() }
        state.apply(event); refresh()
    }

    private func finished(key: String, id: UUID, action: String, model: LocalModel?, code: Int32, sawEvent: Bool, interrupted: Bool) {
        guard jobs[key]?.id == id else { return }
        jobs.removeValue(forKey: key)
        state.finish(action, model: model, code: code, sawEvent: sawEvent, interrupted: interrupted)
        refresh()
        if action != "status" { onServerChanged?(); run("status") }
    }
}
#endif
