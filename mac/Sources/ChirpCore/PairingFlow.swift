import Foundation

/// Where "Pair a Phone…" is: checking, a reason it cannot pair yet (with what to do), or ready with the link.
public enum PairingStep: Equatable, Sendable {
    case checking
    /// Chirp uses a server on another machine (its host): pair from there.
    case remoteServer(String)
    case noTailscale
    /// Tailscale is installed but not running or not logged in.
    case tailscaleOff
    /// `/chirp` is not on the tailnet yet: the exact command, run only when the user agrees.
    case notServed(command: String)
    case publishing(command: String)
    case publishFailed(command: String, reason: String)
    /// `/chirp` already proxies to something else (its target); Chirp leaves it alone.
    case conflict(String)
    case funnel
    case failed(String)
    case noToken
    /// The link and the tailnet URL it points at.
    case ready(PairingLink)
}

/// What a CLI run printed. `status` is -1 when it was stopped at its deadline.
public struct CommandResult: Sendable {
    public var status: Int32
    public var output: Data
    public var error: String
    public init(status: Int32, output: Data = Data(), error: String = "") {
        self.status = status
        self.output = output
        self.error = error
    }
}

public typealias CommandRunner = @Sendable (_ executable: URL, _ arguments: [String], _ timeout: Duration) async -> CommandResult

/// Pair a Phone: find Tailscale and this Mac's MagicDNS name, check that `/chirp` is served (tailnet only), offer the
/// command when it is not, and make the link. It only ever runs `status`, `serve status` and, from `publish()`, the one
/// `serve --set-path /chirp` command it showed. Nothing here is logged.
@MainActor
public final class PairingFlow {
    public private(set) var step: PairingStep = .checking { didSet { if step != oldValue { onChange?() } } }
    public var onChange: (() -> Void)?
    private let serverURL: () -> URL
    private let cli: () -> URL?
    private let run: CommandRunner
    private let links: PairingLinkMaker
    private var generation = 0

    public init(serverURL: @escaping () -> URL, cli: @escaping () -> URL? = { TailscaleServe.findCLI() },
                run: @escaping CommandRunner, links: PairingLinkMaker = SharedTokenPairing()) {
        self.serverURL = serverURL
        self.cli = cli
        self.run = run
        self.links = links
    }

    /// The loopback port of this Mac's server, or nil when Chirp points elsewhere.
    static func localPort(_ url: URL) -> Int? {
        guard ServerConfig(baseURL: url).isLoopback else { return nil }
        return url.port ?? (url.scheme == "https" ? 443 : 80)
    }

    public func check() async {
        generation += 1
        let g = generation
        step = .checking
        let url = serverURL()
        guard let port = Self.localPort(url) else { step = .remoteServer(ServerConfig(baseURL: url).host); return }
        guard let cli = cli() else { step = .noTailscale; return }
        let status = await run(cli, ["status", "--json"], .seconds(10))
        guard g == generation else { return }
        guard let host = TailscaleServe.dnsName(statusJSON: status.output) else { step = .tailscaleOff; return }
        let serve = await run(cli, ["serve", "status", "--json"], .seconds(10))
        guard g == generation else { return }
        switch TailscaleServe.status(serveJSON: serve.output, host: host, port: port) {
        case .served:
            do {
                let link = try await links.link(serverURL: TailscaleServe.pairingURL(host: host))
                guard g == generation else { return }
                step = .ready(link)
            } catch PairingError.noToken {
                if g == generation { step = .noToken }
            } catch {
                if g == generation { step = .failed("Couldn’t make the pairing link.") }
            }
        case .notServed: step = .notServed(command: TailscaleServe.publishCommand(port: port))
        case .conflict(let target): step = .conflict(target)
        case .funnel: step = .funnel
        case .unreadable: step = .failed(Self.reason(serve, fallback: "Tailscale’s serve status could not be read."))
        }
    }

    /// Runs the shown command (the user agreed to it), then checks again.
    public func publish() async {
        let command: String
        switch step {
        case .notServed(let c), .publishFailed(let c, _): command = c
        default: return
        }
        guard let port = Self.localPort(serverURL()), let cli = cli(),
              command == TailscaleServe.publishCommand(port: port) else { await check(); return }
        generation += 1
        let g = generation
        step = .publishing(command: command)
        let result = await run(cli, TailscaleServe.publishArguments(port: port), .seconds(20))
        guard g == generation else { return }
        if result.status != 0 {
            step = .publishFailed(command: command, reason: Self.reason(result, fallback: "Tailscale did not finish in time."))
            return
        }
        await check()
    }

    /// Forgets the link (the window hid or closed); a late answer from a check still running is dropped.
    public func reset() {
        generation += 1
        step = .checking
    }

    /// The CLI's own words for a failure, last few lines (it names what to enable in the admin console).
    static func reason(_ r: CommandResult, fallback: String) -> String {
        let text = [r.error, String(decoding: r.output, as: UTF8.self)].joined(separator: "\n")
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Warning: client version") }
        return lines.isEmpty ? fallback : lines.suffix(4).joined(separator: "\n")
    }
}

/// The pairing code's lifetime: counts down a second at a time, then expires once. `sleep` is injected for tests.
@MainActor
public final class PairingTimer {
    public static let lifetime = 120
    public private(set) var remaining = 0
    public var isRunning: Bool { task != nil }
    public var onTick: ((Int) -> Void)?
    public var onExpire: (() -> Void)?
    private let sleep: @Sendable (Duration) async -> Void
    private var task: Task<Void, Never>?

    public init(sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    public func start(seconds: Int = PairingTimer.lifetime) {
        cancel()
        remaining = seconds
        onTick?(remaining)
        task = Task { @MainActor [weak self, sleep] in
            while let self, self.remaining > 0 {
                await sleep(.seconds(1))
                guard !Task.isCancelled else { return }
                self.remaining -= 1
                self.onTick?(self.remaining)
            }
            guard !Task.isCancelled, let self else { return }
            self.task = nil
            self.onExpire?()
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
    }

    /// "1:05".
    public static func text(_ seconds: Int) -> String { "\(seconds / 60):\(String(format: "%02d", seconds % 60))" }
}
