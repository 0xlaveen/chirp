import Foundation

/// The file operations the login-item agent needs, so tests inject an in-memory filesystem and never touch the real
/// ~/Library.
public protocol LaunchAgentFileSystem: Sendable {
    func exists(_ url: URL) -> Bool
    /// Writes `data`, creating the parent directory when it is missing.
    func write(_ data: Data, to url: URL) throws
    func remove(_ url: URL) throws
}

/// Launch at login as a per-user LaunchAgent. `SMAppService.mainApp` refuses a self-signed app in ~/Applications, so
/// the agent is a plain plist that runs `/usr/bin/open -a <app>` at login. It is created and removed only when the
/// user flips the toggle; its presence is the state.
public struct LaunchAgent: Sendable {
    public static let label = "dev.chirp.mac"

    public let appPath: String
    public let launchAgentsDirectory: URL
    private let fileSystem: any LaunchAgentFileSystem

    public init(appPath: String, launchAgentsDirectory: URL, fileSystem: any LaunchAgentFileSystem) {
        self.appPath = appPath
        self.launchAgentsDirectory = launchAgentsDirectory
        self.fileSystem = fileSystem
    }

    public var plistURL: URL { launchAgentsDirectory.appendingPathComponent("\(Self.label).plist") }

    public var isEnabled: Bool { fileSystem.exists(plistURL) }

    /// Writes the agent when `on`, deletes it otherwise. Turning it off when it is already off is not an error.
    public func setEnabled(_ on: Bool) throws {
        if on {
            try fileSystem.write(Data(Self.plist(appPath: appPath).utf8), to: plistURL)
        } else if isEnabled {
            try fileSystem.remove(plistURL)
        }
    }

    /// Flips the state and returns the new one.
    @discardableResult
    public func toggle() throws -> Bool {
        let next = !isEnabled
        try setEnabled(next)
        return next
    }

    /// The plist text, rendered by hand so the output is deterministic (and readable in a diff).
    public static func plist(appPath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/bin/open</string>
                <string>-a</string>
                <string>\(escape(appPath))</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
        </dict>
        </plist>

        """
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
