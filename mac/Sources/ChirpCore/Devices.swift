import Foundation

/// One paired phone as `chirp-server devices list --json` reports it. The token itself is never here: the server keeps
/// only a digest.
public struct PairedDevice: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var created: Date
    public var lastSeen: Date?

    public init(id: String, name: String, created: Date, lastSeen: Date? = nil) {
        self.id = id
        self.name = name
        self.created = created
        self.lastSeen = lastSeen
    }
}

public enum DevicesError: Error, Equatable, Sendable {
    /// No `chirp-server` found on this Mac.
    case noServer
    /// The installed `chirp-server` has no per-device tokens yet.
    case outdated
    /// The name was refused (empty, too long, already paired): the server's own one-line reason.
    case rejected(String)
    case failed

    public var message: String {
        switch self {
        case .noServer: "Chirp couldn’t find chirp-server on this Mac."
        case .outdated: "This Mac’s chirp-server is too old for per-device tokens. Update it, then try again."
        case .rejected(let reason): reason
        case .failed: "chirp-server didn’t answer as expected."
        }
    }
}

/// What the pairing window and Settings → Devices need from the server's device store. The real one runs
/// `chirp-server`; tests inject a fake. Nothing here is logged.
public protocol DeviceStoring: Sendable {
    func list() async throws(DevicesError) -> [PairedDevice]
    func revoke(id: String) async throws(DevicesError)
    /// Mints a token for a new device named `name` and returns the link that carries it to `serverURL`.
    func mint(name: String, serverURL: URL) async throws(DevicesError) -> PairingLink
}

/// The same name rules as the server (1–64 printable characters), so a bad name is caught before anything runs.
public enum DeviceName {
    public static let maxLength = 64

    public static func clean(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...maxLength).contains(name.count) else { return nil }
        let unprintable: Set<Unicode.GeneralCategory> = [.control, .format, .surrogate, .privateUse, .unassigned]
        return name.unicodeScalars.contains { unprintable.contains($0.properties.generalCategory) } ? nil : name
    }

    public static let rule = "Use 1–\(maxLength) printable characters."

    /// "<Mac>’s phone", cut to fit.
    public static func suggested(macName: String?) -> String {
        let mac = macName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return clean(mac.isEmpty ? "My phone" : String("\(mac)’s phone".prefix(maxLength))) ?? "My phone"
    }
}

/// `chirp-server pair --name`, `devices list --json` and `devices revoke`, run from the bundled server environment. The
/// server's own device store does the work (the same `devices.json` and format), so there is no new endpoint and the
/// running server picks up a revoke on its next request.
public struct DeviceCLI: DeviceStoring {
    private let executable: @Sendable () -> URL?
    private let run: CommandRunner

    public init(executable: @escaping @Sendable () -> URL?, run: @escaping CommandRunner) {
        self.executable = executable
        self.run = run
    }

    private func result(_ arguments: [String]) async throws(DevicesError) -> CommandResult {
        guard let executable = executable() else { throw .noServer }
        let r = await run(executable, arguments, .seconds(20))
        guard r.status != 0 else { return r }
        // argparse refuses an unknown subcommand or option with status 2; the server's own refusals exit 1 with a line.
        if r.status == 2 { throw .outdated }
        let line = r.error.split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        throw r.status == 1 && !line.isEmpty && line.count <= 160 ? .rejected(line) : .failed
    }

    public func list() async throws(DevicesError) -> [PairedDevice] {
        let r = try await result(["devices", "list", "--json"])
        guard let listing = try? JSONDecoder().decode(Listing.self, from: r.output) else { throw .failed }
        return try listing.devices.map { entry throws(DevicesError) in
            guard let created = Self.date(entry.created) else { throw DevicesError.failed }
            return PairedDevice(id: entry.id, name: entry.name, created: created, lastSeen: entry.last_seen.flatMap(Self.date))
        }
    }

    public func revoke(id: String) async throws(DevicesError) {
        _ = try await result(["devices", "revoke", id])
    }

    public func mint(name: String, serverURL: URL) async throws(DevicesError) -> PairingLink {
        let r = try await result(["pair", "--name", name, "--url", serverURL.absoluteString])
        // The first stdout line is the link; the terminal QR code follows.
        let line = String(decoding: r.output, as: UTF8.self).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        guard line.hasPrefix("chirp://pair?"), let parts = URLComponents(string: line),
              let token = parts.queryItems?.first(where: { $0.name == "token" })?.value,
              let link = try? PairingLink(serverURL: serverURL, token: token) else { throw .failed }
        return link
    }

    private struct Listing: Decodable {
        struct Entry: Decodable { var id: String; var name: String; var created: String; var last_seen: String? }
        var devices: [Entry]
    }

    /// The server's UTC stamps, `2026-10-24T09:30:00Z`.
    static func date(_ stamp: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: stamp)
    }
}

/// Mints one device token per pairing: the `PairingLinkMaker` that replaces the shared token in the QR code.
public struct DeviceTokenPairing: PairingLinkMaker {
    public let name: String
    private let store: any DeviceStoring

    public init(name: String, store: any DeviceStoring) {
        self.name = name
        self.store = store
    }

    public func link(serverURL: URL) async throws -> PairingLink {
        try await store.mint(name: name, serverURL: serverURL)
    }
}

/// What Settings → Devices shows.
public enum DevicesPhase: Equatable, Sendable {
    case loading
    case loaded([PairedDevice])
    /// Chirp uses a server on another machine (its host): its devices are managed there.
    case remote(String)
    case unavailable(String)
}

/// What Settings → Devices shows of the server's activity: nothing (remote server, no owner token, refused), a one-line
/// "update the server" note, or the activity itself.
public enum ActivityPhase: Equatable, Sendable {
    case hidden
    case outdated
    case shown(DeviceActivity)

    public var activity: DeviceActivity? {
        if case .shown(let activity) = self { activity } else { nil }
    }
}

/// The Devices tab's list. Revoking runs the CLI, then reloads the list from it, so what shows is what the server has.
/// Activity (who used the server, when) comes from the server's owner-only endpoint, only while the server is on this Mac.
@MainActor
public final class DevicesModel {
    public private(set) var phase: DevicesPhase = .loading { didSet { if phase != oldValue { onChange?() } } }
    /// The device whose revoke is running, and the last revoke's problem.
    public private(set) var revoking: String? { didSet { if revoking != oldValue { onChange?() } } }
    public private(set) var problem: String? { didSet { if problem != oldValue { onChange?() } } }
    public private(set) var activity: ActivityPhase = .hidden { didSet { if activity != oldValue { onChange?() } } }
    /// Why the last "Keep device activity" change did not apply.
    public private(set) var keepProblem: String? { didSet { if keepProblem != oldValue { onChange?() } } }
    public var onChange: (() -> Void)?
    private let store: any DeviceStoring
    private let activityServer: @MainActor () -> (any DeviceActivityFetching)?
    private let remoteHost: () -> String?
    private var generation = 0
    private var activityGeneration = 0

    /// `remoteHost` is the server's host when Chirp points at another machine, else nil. `activity` gives the client for the
    /// server as it is now (the URL can change); without one there is no activity part at all.
    public init(store: any DeviceStoring, remoteHost: @escaping () -> String? = { nil },
                activity: @escaping @MainActor () -> (any DeviceActivityFetching)? = { nil }) {
        self.store = store
        self.remoteHost = remoteHost
        self.activityServer = activity
    }

    public func refresh() async {
        generation += 1
        let g = generation
        if let host = remoteHost() {
            phase = .remote(host)
            activity = .hidden
            return
        }
        do {
            let devices = try await store.list()
            guard g == generation else { return }
            phase = .loaded(devices)
        } catch {
            guard g == generation else { return }
            phase = .unavailable(error.message)
        }
        await refreshActivity()
    }

    /// Asks the server for its activity again (the poll, and after a change of the switch). A remote server, a missing
    /// owner token or a refusal hides it; a failed request keeps what was shown.
    public func refreshActivity() async {
        activityGeneration += 1
        let g = activityGeneration
        guard let activityServer = activityServer(), remoteHost() == nil else { activity = .hidden; return }
        do {
            let fetched = try await activityServer.fetch()
            guard g == activityGeneration else { return }
            activity = .shown(fetched)
        } catch {
            guard g == activityGeneration else { return }
            switch error {
            case .outdated: activity = .outdated
            case .hidden: activity = .hidden
            case .failed: break
            }
        }
    }

    /// "Keep device activity": off stops recording and deletes the stored list.
    public func setKeepActivity(_ keep: Bool) async {
        guard let activityServer = activityServer() else { return }
        keepProblem = nil
        do { try await activityServer.setKeep(keep) } catch { keepProblem = ActivityText.keepFailure(error) }
        await refreshActivity()
    }

    public func revoke(_ device: PairedDevice) async {
        guard revoking == nil else { return }
        revoking = device.id
        problem = nil
        do { try await store.revoke(id: device.id) } catch { problem = error.message }
        revoking = nil
        await refresh()
    }
}

/// Rotating the shared token is done where the server runs: it reads the token once at start, so the file is replaced and
/// the server restarted. Chirp shows the commands instead of restarting a server it did not start.
public enum SharedTokenRotation {
    public static let warning = "Every phone paired with the shared token stops working until you pair it again, and so does any script that uses it. Phones paired with their own token are not affected. This Mac’s Chirp reads the new token by itself."

    public static var commands: String {
        """
        # Chirp: replace the shared token (phones paired with their own token keep working)
        rm ~/.config/chirp/token
        # Restart chirp-server: it creates a new token when it starts.
        launchctl kickstart -k gui/$(id -u)/dev.chirp.server
        # No launchd service? Stop chirp-server and start it again yourself.
        """
    }
}
