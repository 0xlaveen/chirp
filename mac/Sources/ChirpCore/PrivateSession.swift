import Foundation

/// Process-local privacy, never written to preferences. Turning it on also cancels an existing edit watcher.
@MainActor
public final class PrivateSession {
    public static let duration: TimeInterval = 3600
    public static let help = "Skips dictation history and learning from edits. Ends on screen lock, after 1 hour, or when Chirp quits."
    private var expiresAt: TimeInterval?
    private let now: () -> TimeInterval
    public var onChange: (() -> Void)?
    public init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { self.now = now }
    public var isActive: Bool { expireIfNeeded(); return expiresAt != nil }
    public func setEnabled(_ enabled: Bool) {
        expiresAt = enabled ? now() + Self.duration : nil
        onChange?()
    }
    public func screenLocked() { if expiresAt != nil { setEnabled(false) } }
    public func expireIfNeeded() {
        if let expiresAt, now() >= expiresAt { setEnabled(false) }
    }
}
