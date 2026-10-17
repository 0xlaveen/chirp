import Foundation

/// What a process invocation asks for. Only a bare launch starts the UI, which onboards and requests TCC grants.
public enum LaunchMode: Equatable, Sendable {
    case app
    case selftest
    /// Draw the UI to PNGs in a directory and exit, without starting the app (no onboarding, no TCC prompt).
    case renderSnapshots(directory: String)
    case usage(exitCode: Int32)

    public static let usageText = """
        usage: ChirpMac                         launch the menu-bar app
               ChirpMac --selftest <audio> [--url URL] [--token-file PATH] [--expect WORD] [--fast]
               ChirpMac --render-snapshots <dir>   draw the HUD, Settings and menu to PNGs (light and dark)
        """

    /// `arguments` excludes the executable path. Launch Services may pass `-psn_*`; it is not a CLI flag.
    public static func parse(_ arguments: [String]) -> LaunchMode {
        if arguments.contains("--selftest") { return .selftest }
        if let i = arguments.firstIndex(of: "--render-snapshots") {
            guard i + 1 < arguments.count, !arguments[i + 1].hasPrefix("-") else { return .usage(exitCode: 64) }
            return .renderSnapshots(directory: arguments[i + 1])
        }
        guard let flag = arguments.first(where: { $0.hasPrefix("-") && !$0.hasPrefix("-psn_") }) else {
            return arguments.isEmpty || arguments.allSatisfy({ $0.hasPrefix("-psn_") }) ? .app : .usage(exitCode: 64)
        }
        return .usage(exitCode: flag == "--help" || flag == "-h" ? 0 : 64)
    }
}

/// First-run permission walkthrough. Marks itself done only once both prompts have completed,
/// so an interrupted first launch onboards again.
@MainActor
public struct Onboarding {
    public var isDone: () -> Bool
    public var markDone: () -> Void
    public var requestMicrophone: () async -> Bool
    public var accessibilityGranted: () -> Bool
    public var promptAccessibility: () -> Void

    public init(isDone: @escaping () -> Bool, markDone: @escaping () -> Void,
                requestMicrophone: @escaping () async -> Bool, accessibilityGranted: @escaping () -> Bool,
                promptAccessibility: @escaping () -> Void) {
        self.isDone = isDone
        self.markDone = markDone
        self.requestMicrophone = requestMicrophone
        self.accessibilityGranted = accessibilityGranted
        self.promptAccessibility = promptAccessibility
    }

    /// Returns false when onboarding had already run.
    @discardableResult
    public func runIfNeeded() async -> Bool {
        guard !isDone() else { return false }
        _ = await requestMicrophone()
        if Task.isCancelled { return true }
        if !accessibilityGranted() { promptAccessibility() }
        markDone()
        return true
    }
}
