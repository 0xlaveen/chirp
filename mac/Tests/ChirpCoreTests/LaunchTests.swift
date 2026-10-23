import Testing
@testable import ChirpCore

@Suite struct LaunchModeTests {
    @Test func bareLaunchStartsTheApp() {
        #expect(LaunchMode.parse([]) == .app)
        #expect(LaunchMode.parse(["-psn_0_12345"]) == .app)
    }

    @Test func localModelsLaunchIsExplicit() {
        #expect(LaunchMode.parse(["--models"]) == .app)
        #expect(LaunchMode.parse(["-psn_0_1", "--models"]) == .app)
        #expect(LaunchMode.parse(["--models", "--bogus"]) == .usage(exitCode: 64))
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
        #expect(LaunchMode.parse(["--render-snapshots", "/tmp/out", "--curated"]) == .renderSnapshots(directory: "/tmp/out", curated: true))
        #expect(LaunchMode.parse(["--render-snapshots", "/tmp/out"]) != .renderSnapshots(directory: "/tmp/out", curated: true))
        #expect(LaunchMode.parse(["-psn_0_1", "--render-snapshots", "out"]) == .renderSnapshots(directory: "out"))
        #expect(LaunchMode.parse(["--render-snapshots"]) == .usage(exitCode: 64))
        #expect(LaunchMode.parse(["--render-snapshots", "--selftest"]) == .selftest)
        #expect(LaunchMode.parse(["--render-snapshots", "--fast"]) == .usage(exitCode: 64))
    }

    @Test func selftestIsRecognisedAnywhere() {
        #expect(LaunchMode.parse(["--selftest", "a.wav"]) == .selftest)
        #expect(LaunchMode.parse(["--fast", "--selftest", "a.wav"]) == .selftest)
    }

    @Test func notesSelftestIsItsOwnModeAndNeverLaunchesUI() {
        #expect(LaunchMode.parse(["--notes-selftest", "a.wav"]) == .notesSelftest)
        #expect(LaunchMode.parse(["--fast", "--notes-selftest", "a.wav", "--fault", "drop@30"]) == .notesSelftest)
        #expect(LaunchMode.usageText.contains("--notes-selftest"))
    }

    @Test func aFaultPlanParsesDropsAndOutages() throws {
        let plan = try #require(NotesFaultPlan.parse("drop@30, down@60-90"))
        #expect(plan.faults == [.drop(at: 30), .down(from: 60, to: 90)])
        #expect(!plan.isDown(at: 59.9) && plan.isDown(at: 60) && plan.isDown(at: 89.9) && !plan.isDown(at: 90))
        #expect(plan.drops(opened: 0, now: 30) && !plan.drops(opened: 0, now: 29.9))
        #expect(!plan.drops(opened: 30, now: 45))          // a socket opened after the drop keeps going
        #expect(plan.drops(opened: 45, now: 60))           // the outage loses the open socket too
        for bad in ["", "drop", "drop@", "drop@-1", "down@90-60", "down@60", "stall@3"] {
            #expect(NotesFaultPlan.parse(bad) == nil, "\(bad)")
        }
    }
}
