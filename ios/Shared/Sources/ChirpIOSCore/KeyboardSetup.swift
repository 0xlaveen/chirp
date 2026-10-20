import Foundation

/// Content-free evidence that Chirp Keyboard has opened with Full Access, so the app can show which setup
/// steps are done. The keyboard can only reach the App Group with Full Access, so a recorded date proves
/// both "added" and "Full Access on". It holds one timestamp: no text, context, host or identifiers.
public final class KeyboardSetupStore: Sendable {
    private struct Marker: Codable { var fullAccessSeenAt: Date }
    private let files: ProtectedFiles
    public init(root: URL) throws { files = try ProtectedFiles(root: root.appendingPathComponent("keyboard", isDirectory: true)) }
    public func recordFullAccess(now: Date = Date()) throws {
        try files.transaction { try files.save(Marker(fullAccessSeenAt: now), "setup.json", max: 1024) }
    }
    public func fullAccessSeenAt() throws -> Date? {
        try files.transaction { try files.load(Marker.self, "setup.json", max: 1024)?.fullAccessSeenAt }
    }
}
