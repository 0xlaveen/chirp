import Testing
@testable import ChirpCore

@Suite struct LaunchModeTests {
    @Test func bareLaunchStartsTheApp() {
        #expect(LaunchMode.parse([]) == .app)
        #expect(LaunchMode.parse(["-psn_0_12345"]) == .app)
    }

    @Test func anyCLIFlagPrintsUsageAndNeverLaunchesUI() {
        #expect(LaunchMode.parse(["--help"]) == .usage(exitCode: 0))
        #expect(LaunchMode.parse(["-h"]) == .usage(exitCode: 0))
        #expect(LaunchMode.parse(["--version"]) == .usage(exitCode: 64))
        #expect(LaunchMode.parse(["--bogus", "x"]) == .usage(exitCode: 64))
        #expect(LaunchMode.parse(["-psn_0_1", "--help"]) == .usage(exitCode: 0))
        #expect(LaunchMode.parse(["stray-positional"]) == .usage(exitCode: 64))
    }

    @Test func renderSnapshotsNeedsADirectoryAndNeverLaunchesUI() {
        #expect(LaunchMode.parse(["--render-snapshots", "/tmp/out"]) == .renderSnapshots(directory: "/tmp/out"))
        #expect(LaunchMode.parse(["-psn_0_1", "--render-snapshots", "out"]) == .renderSnapshots(directory: "out"))
        #expect(LaunchMode.parse(["--render-snapshots"]) == .usage(exitCode: 64))
        #expect(LaunchMode.parse(["--render-snapshots", "--selftest"]) == .selftest)
        #expect(LaunchMode.parse(["--render-snapshots", "--fast"]) == .usage(exitCode: 64))
    }

    @Test func selftestIsRecognisedAnywhere() {
        #expect(LaunchMode.parse(["--selftest", "a.wav"]) == .selftest)
        #expect(LaunchMode.parse(["--fast", "--selftest", "a.wav"]) == .selftest)
    }
}
