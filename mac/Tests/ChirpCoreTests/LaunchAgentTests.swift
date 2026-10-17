import Foundation
import Testing
@testable import ChirpCore

/// An in-memory filesystem: the tests never touch the real ~/Library.
private final class MemoryFileSystem: LaunchAgentFileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [URL: Data] = [:]
    private(set) var operations: [String] = []
    var failWrites = false

    func exists(_ url: URL) -> Bool { lock.withLock { files[url] != nil } }
    func data(_ url: URL) -> Data? { lock.withLock { files[url] } }
    func write(_ data: Data, to url: URL) throws {
        try lock.withLock {
            if failWrites { throw CocoaError(.fileWriteNoPermission) }
            operations.append("write \(url.lastPathComponent)")
            files[url] = data
        }
    }
    func remove(_ url: URL) throws {
        try lock.withLock {
            guard files.removeValue(forKey: url) != nil else { throw CocoaError(.fileNoSuchFile) }
            operations.append("remove \(url.lastPathComponent)")
        }
    }
}

@Suite struct LaunchAgentTests {
    private let directory = URL(fileURLWithPath: "/fake-home/Library/LaunchAgents", isDirectory: true)
    private let app = "/Users/me/Applications/Chirp.app"

    private func agent(_ fs: MemoryFileSystem, app: String? = nil) -> LaunchAgent {
        LaunchAgent(appPath: app ?? self.app, launchAgentsDirectory: directory, fileSystem: fs)
    }

    @Test func plistRunsOpenOnTheAppAtLoad() throws {
        let plist = try #require(PropertyListSerialization.propertyList(
            from: Data(LaunchAgent.plist(appPath: app).utf8), format: nil) as? [String: Any])
        #expect(plist["Label"] as? String == "dev.chirp.mac")
        #expect(plist["ProgramArguments"] as? [String] == ["/usr/bin/open", "-a", app])
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(Set(plist.keys) == ["Label", "ProgramArguments", "RunAtLoad"])
    }

    @Test func plistRenderingIsDeterministicAndEscapesThePath() throws {
        #expect(LaunchAgent.plist(appPath: app) == LaunchAgent.plist(appPath: app))
        let odd = "/Users/a&b/<Apps>/Chirp.app"
        let parsed = try #require(PropertyListSerialization.propertyList(
            from: Data(LaunchAgent.plist(appPath: odd).utf8), format: nil) as? [String: Any])
        #expect((parsed["ProgramArguments"] as? [String])?.last == odd)
    }

    @Test func theAgentLivesInLaunchAgentsUnderItsLabel() {
        #expect(agent(MemoryFileSystem()).plistURL.path == "/fake-home/Library/LaunchAgents/dev.chirp.mac.plist")
    }

    @Test func startsOffAndTouchesNothingUntilToggled() {
        let fs = MemoryFileSystem()
        #expect(!agent(fs).isEnabled)
        #expect(fs.operations.isEmpty)
    }

    @Test func togglingWritesThenRemovesTheAgent() throws {
        let fs = MemoryFileSystem()
        let a = agent(fs)
        #expect(try a.toggle() == true)
        #expect(a.isEnabled)
        #expect(fs.data(a.plistURL).flatMap { String(data: $0, encoding: .utf8) } == LaunchAgent.plist(appPath: app))
        #expect(try a.toggle() == false)
        #expect(!a.isEnabled && !fs.exists(a.plistURL))
        #expect(fs.operations == ["write dev.chirp.mac.plist", "remove dev.chirp.mac.plist"])
    }

    @Test func turningOffWhenAlreadyOffIsANoOp() throws {
        let fs = MemoryFileSystem()
        try agent(fs).setEnabled(false)
        #expect(fs.operations.isEmpty)
    }

    @Test func enablingAgainRewritesThePathAfterTheAppMoved() throws {
        let fs = MemoryFileSystem()
        try agent(fs, app: "/old/Chirp.app").setEnabled(true)
        try agent(fs, app: "/new/Chirp.app").setEnabled(true)
        #expect(fs.data(agent(fs).plistURL).flatMap { String(data: $0, encoding: .utf8) }?.contains("/new/Chirp.app") == true)
    }

    @Test func aFailedWriteLeavesTheStateOffAndThrows() {
        let fs = MemoryFileSystem()
        fs.failWrites = true
        let a = agent(fs)
        #expect(throws: CocoaError.self) { try a.toggle() }
        #expect(!a.isEnabled)
    }
}
