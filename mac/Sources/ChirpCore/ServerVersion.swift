import Foundation

/// What this app needs from a server: the API level and capabilities it was built against.
public struct ServerRequirement: Equatable, Sendable {
    public var api: Int
    public var capabilities: [String]

    public init(api: Int, capabilities: [String]) {
        self.api = api
        self.capabilities = capabilities
    }

    public static let current = ServerRequirement(api: 2, capabilities: ["notes_structure", "notes_correction", "notes_reorganize"])

    /// True when authenticated health shows a server older than the app. An unauthenticated answer (no engine) says
    /// nothing, so it is never "out of date"; a server that predates `api` is.
    public func isOutdated(_ health: Health?) -> Bool {
        guard let health, health.ok, health.engine != nil else { return false }
        guard let api = health.api, api >= self.api else { return true }
        return !Set(capabilities).isSubset(of: Set(health.capabilities ?? []))
    }
}

/// The process on the server port, as `lsof`, `launchctl list` and `ps` describe it.
public struct ServerProcess: Equatable, Sendable {
    public static let managedLabel = "dev.chirp.server"

    public var pid: Int
    /// The launchd job running it; nil for one started by hand.
    public var label: String?
    public var elapsed: TimeInterval?
    public var command: String?

    public init(pid: Int, label: String? = nil, elapsed: TimeInterval? = nil, command: String? = nil) {
        self.pid = pid
        self.label = label
        self.elapsed = elapsed
        self.command = command
    }

    /// The LaunchAgent Chirp installs and the app restarts.
    public var isManaged: Bool { label == Self.managedLabel }

    /// Label of the job whose PID is `pid` in `launchctl list` output (`PID\tStatus\tLabel` rows).
    public static func label(ofPID pid: Int, inLaunchctlList listing: String) -> String? {
        for line in listing.split(separator: "\n") {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            if columns.count >= 3, Int(columns[0]) == pid { return String(columns[2]) }
        }
        return nil
    }

    /// Seconds from `ps -o etimes=` ("172800" or "  42").
    public static func elapsed(fromEtimes text: String) -> TimeInterval? {
        Int(text.trimmingCharacters(in: .whitespacesAndNewlines)).map(TimeInterval.init)
    }

    /// The server directory from the command line (`…/server/.venv/bin/python -m chirp_server`), with `home` as ~.
    /// Found by the venv marker, not the first word: the managed install's path contains a space.
    public func source(home: String) -> String? {
        guard let command, command.hasPrefix("/"), let marker = command.range(of: "/.venv/bin/") else { return nil }
        let path = String(command[..<marker.lowerBound])
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// What the user can do about an out-of-date server.
public enum ServerFix: Equatable, Sendable {
    /// Restart the LaunchAgent the app manages, so it runs the code on disk now.
    case restart
    /// Stop the other server and start the managed one.
    case useManaged

    public var buttonTitle: String {
        switch self {
        case .restart: "Restart server"
        case .useManaged: "Use Chirp’s managed server instead"
        }
    }
}

/// One message for every place the server's age shows up: the menu, Settings → Server and the Notes banner.
public struct ServerNotice: Equatable, Sendable {
    public var message: String
    public var fix: ServerFix?

    /// "Oct 19", "~/…/chirp": where it came from, for the sentence.
    public static func origin(startedAt: Date?, source: String?, timeZone: TimeZone = .current) -> String? {
        var parts: [String] = []
        if let startedAt {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = "MMM d"
            parts.append("started " + formatter.string(from: startedAt))
        }
        if let source { parts.append("from " + shorten(source)) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// `~/Documents/Programming/chirp/server` → `~/…/chirp`: the checkout's name is what tells two copies apart.
    public static func shorten(_ source: String) -> String {
        var parts = source.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.last == "server" { parts.removeLast() }
        guard parts.count > 2 else { return (source.hasPrefix("/") ? "/" : "") + parts.joined(separator: "/") }
        return (parts[0] == "~" ? "~/…/" : "/…/") + parts[parts.count - 1]
    }

    /// Nil unless `requirement` says the running server is older than the app.
    /// - Parameters:
    ///   - local: the server is on this Mac, so the app can restart it; a remote one is only named.
    ///   - process: the listener on the port, when it could be found.
    public static func make(health: Health?, process: ServerProcess?, local: Bool, host: String,
                            requirement: ServerRequirement = .current, now: Date = Date(), home: String = NSHomeDirectory(),
                            uid: UInt32 = getuid(), timeZone: TimeZone = .current) -> ServerNotice? {
        guard let health, requirement.isOutdated(health) else { return nil }
        guard local else {
            return ServerNotice(message: "The Chirp server at \(host) is out of date. Update and restart chirp-server there.", fix: nil)
        }
        let startedAt = health.startedAt.map { Date(timeIntervalSince1970: $0) } ?? process?.elapsed.map { now.addingTimeInterval(-$0) }
        let origin = origin(startedAt: startedAt, source: health.source ?? process?.source(home: home), timeZone: timeZone)
        let head = "This Mac’s Chirp server is out of date" + (origin.map { " (\($0))" } ?? "") + "."
        guard let process else { return ServerNotice(message: head, fix: .restart) }
        if process.isManaged { return ServerNotice(message: head, fix: .restart) }
        if let label = process.label {
            return ServerNotice(message: head + " It runs as the LaunchAgent \(label), which Chirp does not manage. Stop it with: launchctl bootout gui/\(uid)/\(label)", fix: nil)
        }
        return ServerNotice(message: head + " It was not started by Chirp.", fix: .useManaged)
    }

    /// The server's state for the menu and the Settings status row.
    public static let statusText = "Out of date"
}
