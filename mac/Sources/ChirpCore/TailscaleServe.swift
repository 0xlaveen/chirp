import Foundation

/// Reading the Tailscale CLI's JSON: this Mac's MagicDNS name and whether `/chirp` is served on the tailnet. Chirp only
/// ever adds a tailnet-only `/chirp` path; it never turns on Funnel and never serves where Funnel is on.
public enum TailscaleServe {
    public static let path = "/chirp"

    /// Where the CLI lives: the app bundle's binary (which is the CLI too), then PATH installs (Homebrew, the app's
    /// `/usr/local/bin` shim, nix-darwin). An app opened from Finder has no shell PATH, so these are checked by hand.
    public static let candidates = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale",
        "/run/current-system/sw/bin/tailscale",
    ]

    public static func findCLI(isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> URL? {
        candidates.first(where: isExecutable).map { URL(fileURLWithPath: $0) }
    }

    /// `tailscale status --json`: this Mac's MagicDNS name (no trailing dot) when Tailscale is running and logged in.
    public static func dnsName(statusJSON: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data(from: statusJSON)) as? [String: Any],
              root["BackendState"] as? String == "Running",
              let me = root["Self"] as? [String: Any], let name = me["DNSName"] as? String else { return nil }
        let host = name.hasSuffix(".") ? String(name.dropLast()) : name
        return host.isEmpty ? nil : host.lowercased()
    }

    public enum Status: Equatable, Sendable {
        /// `/chirp` proxies to this Mac's server, tailnet only.
        case served
        case notServed
        /// `/chirp` is taken by something else (its proxy target).
        case conflict(String)
        /// Funnel is on for this host's HTTPS port, so `/chirp` would be on the public internet.
        case funnel
        case unreadable
    }

    /// `tailscale serve status --json` for `host`'s HTTPS port, against the server on loopback `port`. Foreground
    /// `tailscale serve` sessions are read too, since they serve while they run.
    public static func status(serveJSON: Data, host: String, port: Int) -> Status {
        guard let root = try? JSONSerialization.jsonObject(with: data(from: serveJSON)) as? [String: Any] else { return .unreadable }
        let configs = [root] + ((root["Foreground"] as? [String: Any])?.values.compactMap { $0 as? [String: Any] } ?? [])
        let key = "\(host.lowercased()):443"
        if configs.contains(where: { ($0["AllowFunnel"] as? [String: Any])?.contains { $0.key.lowercased() == key && $0.value as? Bool == true } == true }) {
            return .funnel
        }
        for config in configs {
            guard let web = config["Web"] as? [String: Any],
                  let site = web.first(where: { $0.key.lowercased() == key })?.value as? [String: Any],
                  let handlers = site["Handlers"] as? [String: Any],
                  let handler = (handlers[path] ?? handlers[path + "/"]) as? [String: Any] else { continue }
            let proxy = handler["Proxy"] as? String ?? ""
            return isLoopback(proxy, port: port) ? .served : .conflict(proxy.isEmpty ? "another handler" : proxy)
        }
        return .notServed
    }

    /// The tailnet URL a phone pairs with.
    public static func pairingURL(host: String) -> URL { URL(string: "https://\(host)\(path)")! }

    /// The arguments that publish `/chirp` on the tailnet (Serve, never Funnel), and how they read as a command.
    public static func publishArguments(port: Int) -> [String] { ["serve", "--bg", "--set-path", path, "http://127.0.0.1:\(port)"] }
    public static func publishCommand(port: Int) -> String { (["tailscale"] + publishArguments(port: port)).joined(separator: " ") }
    public static let undoCommand = "tailscale serve --set-path \(path) off"

    private static func isLoopback(_ proxy: String, port: Int) -> Bool {
        let target = proxy.contains("://") ? proxy : "http://" + proxy
        guard let url = URL(string: target), ["http", "https"].contains(url.scheme ?? "") else { return false }
        return ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "") && url.port == port
    }

    /// The CLI may print a version warning before the JSON; start at the first brace.
    private static func data(from raw: Data) -> Data {
        guard let i = raw.firstIndex(of: UInt8(ascii: "{")) else { return raw }
        return Data(raw[i...])
    }
}
