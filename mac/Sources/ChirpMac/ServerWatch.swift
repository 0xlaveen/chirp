import AppKit
import ChirpCore

/// Notices a Chirp server older than the app, and fixes it on request: one `ServerNotice` for the menu, Settings and
/// the Notes banner, and the one action behind their buttons.
@MainActor
final class ServerWatch {
    private(set) var notice: ServerNotice?
    /// What the last fix said, or "Restarting…" while it runs.
    private(set) var message: String?
    var busy: Bool { working }
    var onChange: (() -> Void)?
    /// Fires after a fix finished, so the app can re-check health at once.
    var onFixed: (() -> Void)?
    private var working = false

    func update(health: Health?) async {
        let config = settings.serverConfig()
        let old = (notice, message)
        if !ServerRequirement.current.isOutdated(health) {
            notice = nil
            if !working { message = nil }
        } else {
            let port = config.baseURL.port ?? 7821
            let process = config.isLoopback ? await Task.detached { Self.probe(port: port) }.value : nil
            notice = ServerNotice.make(health: health, process: process, local: config.isLoopback, host: config.host)
        }
        if old.0 != notice || old.1 != message { onChange?() }
    }

    /// Runs the fix behind the button: restart the managed server, or replace the other one after a confirmation.
    func fix() {
        guard !working, let fix = notice?.fix else { return }
        if fix == .useManaged, !Self.confirmReplace() { return }
        let port = settings.serverConfig().baseURL.port ?? 7821
        guard let executable = Self.executable() else {
            message = "Install chirp-server (scripts/install-mac.sh), then restart the server."
            onChange?(); return
        }
        working = true
        message = "Restarting the server…"
        onChange?()
        let action = fix == .restart ? "restart" : "replace"
        Task {
            let result = await Task.detached { Self.runSetup(executable, port: port, action: action) }.value
            working = false
            message = result
            onChange?()
            onFixed?()
        }
    }

    // MARK: processes

    private nonisolated static func probe(port: Int) -> ServerProcess? {
        guard let pid = output("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]).split(separator: "\n").first.flatMap({ Int($0) }) else { return nil }
        let label = ServerProcess.label(ofPID: pid, inLaunchctlList: output("/bin/launchctl", ["list"]))
        let fields = output("/bin/ps", ["-o", "etimes=,command=", "-p", String(pid)]).trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", maxSplits: 1).map(String.init)
        return ServerProcess(pid: pid, label: label, elapsed: fields.first.flatMap(ServerProcess.elapsed(fromEtimes:)),
                             command: fields.count > 1 ? fields[1] : nil)
    }

    private nonisolated static func output(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// `chirp-server --port N setup restart|replace`: its JSON events end with `restarted` or an `error` and a message.
    private nonisolated static func runSetup(_ executable: URL, port: Int, action: String) -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--port", String(port), "setup", action]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "Could not run chirp-server. Reinstall it with scripts/install-mac.sh." }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let events = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { try? LocalSetupEvent.decode(Data($0.utf8)) }
        switch events.last {
        case let event? where event.event == "restarted": return "Server restarted."
        case let event? where event.event == "error": return event.message ?? "Could not restart the server."
        default: return "This chirp-server cannot restart itself yet. Run scripts/install-mac.sh to update it."
        }
    }

    private nonisolated static func executable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let path = environment["CHIRP_SERVER_EXECUTABLE"], path.hasPrefix("/") { candidates.append(path) }
        candidates += [home.appendingPathComponent("Library/Application Support/Chirp/server/.venv/bin/chirp-server").path,
                       "/run/current-system/sw/bin/chirp-server", home.appendingPathComponent(".local/bin/chirp-server").path,
                       home.appendingPathComponent(".local/share/chirp/src/server/.venv/bin/chirp-server").path]
        candidates += (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/chirp-server" }
        guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        return URL(fileURLWithPath: found)
    }

    private static func confirmReplace() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Stop the other Chirp server?"
        alert.informativeText = "Chirp will stop the server that is using this port and start its own managed server instead. Dictation pauses for a few seconds."
        alert.addButton(withTitle: "Use Chirp’s Server")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
