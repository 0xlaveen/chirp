import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

@Suite struct ServerVersionTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let home = "/Users/test"
    private let now = Date(timeIntervalSince1970: 1_792_500_000) // 2026-10-20
    private let oct19 = 1_792_400_000.0

    private var current: Health {
        Health(engine: "parakeet", ready: true, notesStructure: true, notesCorrection: true, notesReorganize: true,
               version: "0.1.0", commit: "abc123", api: ServerRequirement.current.api,
               capabilities: ServerRequirement.current.capabilities, startedAt: oct19, source: "~/Documents/Programming/chirp/server")
    }
    /// A server from before health carried a version: authenticated, but no `api`.
    private var old: Health { Health(engine: "parakeet", ready: true, notesStructure: nil) }

    private func notice(_ health: Health?, process: ServerProcess? = nil, local: Bool = true) -> ServerNotice? {
        ServerNotice.make(health: health, process: process, local: local, host: "mac.example", now: now, home: home, uid: 501, timeZone: utc)
    }

    // MARK: the comparison

    @Test func aCurrentServerIsNotOutOfDate() {
        #expect(!ServerRequirement.current.isOutdated(current))
    }

    @Test func aServerWithoutAnAPILevelIsOutOfDate() {
        #expect(ServerRequirement.current.isOutdated(old))
    }

    @Test func aLowerAPILevelOrMissingCapabilityIsOutOfDate() {
        var lower = current; lower.api = ServerRequirement.current.api - 1
        #expect(ServerRequirement.current.isOutdated(lower))
        var missing = current; missing.capabilities = ["notes_structure"]
        #expect(ServerRequirement.current.isOutdated(missing))
        var newer = current; newer.api = ServerRequirement.current.api + 3; newer.capabilities! += ["something_new"]
        #expect(!ServerRequirement.current.isOutdated(newer))
    }

    @Test func healthThatSaysNothingIsNeverOutOfDate() {
        #expect(!ServerRequirement.current.isOutdated(nil))
        #expect(!ServerRequirement.current.isOutdated(Health(ok: true))) // unauthenticated liveness: no engine
    }

    @Test func healthDecodesTheBuildFields() throws {
        let json = #"{"ok":true,"engine":"parakeet","version":"0.1.0","commit":"abc","api":2,"capabilities":["notes_structure"],"started_at":1792400000,"source":"~/x/server","pid":9}"#
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let health = try decoder.decode(Health.self, from: Data(json.utf8))
        #expect(health.api == 2 && health.commit == "abc" && health.startedAt == 1_792_400_000 && health.source == "~/x/server")
        #expect(health.capabilities == ["notes_structure"])
    }

    // MARK: the three states

    @Test func currentGivesNoNotice() {
        #expect(notice(current, process: ServerProcess(pid: 1, label: ServerProcess.managedLabel)) == nil)
    }

    @Test func managedAndOldOffersARestartAndSaysWhereItCameFrom() {
        let n = notice(old, process: ServerProcess(pid: 7, label: "dev.chirp.server", elapsed: 3 * 86400,
                                                    command: "/Users/test/Documents/Programming/chirp/server/.venv/bin/python -m chirp_server"))
        #expect(n?.fix == .restart)
        #expect(n?.message == "This Mac’s Chirp server is out of date (started Oct 17 from ~/…/chirp).")
    }

    @Test func anUnmanagedProcessOffersTheManagedServerInstead() {
        let n = notice(old, process: ServerProcess(pid: 8, label: nil, elapsed: 86400, command: "/tmp/venv/bin/python -m chirp_server"))
        #expect(n?.fix == .useManaged)
        #expect(n?.message.contains("was not started by Chirp") == true)
        #expect(n?.message.hasPrefix("This Mac’s Chirp server is out of date (started Oct 19") == true)
    }

    @Test func anotherLaunchAgentIsNamedAndOnlyExplained() {
        let n = notice(old, process: ServerProcess(pid: 9, label: "org.example.chirp"))
        #expect(n?.fix == nil)
        #expect(n?.message.contains("LaunchAgent org.example.chirp") == true)
        #expect(n?.message.contains("launchctl bootout gui/501/org.example.chirp") == true)
    }

    @Test func aServerThatReportsItsOwnStartAndFolderNeedsNoProbe() {
        var h = old; h.startedAt = oct19; h.source = "~/Documents/Programming/chirp/server"
        #expect(notice(h)?.message == "This Mac’s Chirp server is out of date (started Oct 19 from ~/…/chirp).")
        #expect(notice(h)?.fix == .restart)
    }

    @Test func aRemoteServerIsNamedButNotRestarted() {
        let n = notice(old, local: false)
        #expect(n?.fix == nil)
        #expect(n?.message.contains("mac.example") == true)
    }

    // MARK: parsing

    @Test func launchctlListGivesTheLabelForAPID() {
        let listing = "PID\tStatus\tLabel\n4242\t0\tdev.chirp.server\n-\t0\tcom.example.idle\n17\t0\torg.example.chirp\n"
        #expect(ServerProcess.label(ofPID: 4242, inLaunchctlList: listing) == "dev.chirp.server")
        #expect(ServerProcess.label(ofPID: 17, inLaunchctlList: listing) == "org.example.chirp")
        #expect(ServerProcess.label(ofPID: 5, inLaunchctlList: listing) == nil)
    }

    @Test func etimesAndCommandGiveAgeAndSource() {
        #expect(ServerProcess.elapsed(fromEtimes: "  172800\n") == 172_800)
        #expect(ServerProcess.elapsed(fromEtimes: "x") == nil)
        let p = ServerProcess(pid: 1, command: "/Users/test/Library/Application Support/Chirp/server/.venv/bin/python -m chirp_server")
        #expect(p.source(home: home) == "~/Library/Application Support/Chirp/server")
        let q = ServerProcess(pid: 1, command: "/Users/test/code/chirp/server/.venv/bin/python -m chirp_server --port 7821")
        #expect(q.source(home: home) == "~/code/chirp/server")
        #expect(ServerProcess(pid: 1, command: "/usr/bin/python3 other.py").source(home: home) == nil)
    }

    @Test func sourcesAreShortenedToTheCheckoutName() {
        #expect(ServerNotice.shorten("~/Documents/Programming/chirp/server") == "~/…/chirp")
        #expect(ServerNotice.shorten("~/chirp/server") == "~/chirp")
        #expect(ServerNotice.shorten("/opt/chirp/server") == "/opt/chirp")
        #expect(ServerNotice.shorten("/a/b/c/chirp/server") == "/…/chirp")
    }

    // MARK: where it shows

    @Test func theMenuAndSettingsSayOutOfDateWithTheFixAsARow() {
        let n = notice(old, process: ServerProcess(pid: 7, label: "dev.chirp.server"))
        #expect(MenuContent.serverStatus(health: old, healthError: nil, notice: n).text == "Out of date")
        #expect(MenuContent.serverStatus(health: current, healthError: nil, notice: nil).text == "parakeet")
        var m = MenuInputs(); m.health = old; m.serverNotice = n
        #expect(MenuContent.statusLine(m).text == "Server out of date")
        #expect(MenuContent.entries(m).first { $0.action == .fixServer }?.title == "Restart server")
        m.serverNotice = nil
        #expect(MenuContent.entries(m).contains { $0.action == .fixServer } == false)
        #expect(MenuContent.statusLine(m).text != "Server out of date")
        // No button when there is nothing the app can do (another LaunchAgent, a remote server).
        m.serverNotice = notice(old, process: ServerProcess(pid: 9, label: "org.example.chirp"))
        #expect(MenuContent.entries(m).contains { $0.action == .fixServer } == false)
        #expect(MenuContent.statusLine(m).text == "Server out of date")
    }

    @MainActor @Test func theNotesBannerNamesTheServerAndOffersTheFix() {
        let model = NotesModel()
        model.structuring = .off(.unsupported)
        #expect(model.explanation?.contains("newer Chirp server") == true) // no notice yet: the generic hint
        #expect(model.serverFix == nil)
        model.serverNotice = notice(old, process: ServerProcess(pid: 7, label: "dev.chirp.server"))
        #expect(model.explanation?.contains("out of date") == true)
        #expect(model.explanation?.contains("transcript keeps working") == true)
        #expect(model.serverFix == .restart)
        model.serverFixMessage = "Restarting the server…"
        #expect(model.explanation?.contains("Restarting the server…") == true)
    }
}
