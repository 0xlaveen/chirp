import AppKit
import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

private let host = "my-mac.example-tailnet.ts.net"
private let pairURL = URL(string: "https://\(host)/chirp")!
private let servedJSON = TailscaleServeTests.serve(["/chirp": ["Proxy": "http://127.0.0.1:7821"]])
private let deviceToken = "test-only-device-token-Zq9_-k"
private let now = Date(timeIntervalSince1970: 1_792_000_000)
private func stamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

/// `chirp-server` as a table of answers; records every argument list it was run with.
private final class FakeServer: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: CommandResult] = [:]
    private var calls: [[String]] = []
    var installed = true
    var ran: [[String]] { lock.withLock { calls } }
    func answer(_ args: String, _ result: CommandResult) { lock.withLock { answers[args] = result } }
    func listing(_ devices: [[String: Any?]]) {
        let data = try! JSONSerialization.data(withJSONObject: ["devices": devices.map { $0.mapValues { $0 ?? NSNull() } }])
        answer("devices list --json", CommandResult(status: 0, output: data))
    }
    var run: CommandRunner {
        { [self] _, arguments, _ in
            lock.withLock {
                calls.append(arguments)
                return answers[arguments.joined(separator: " ")] ?? CommandResult(status: 1, error: "unexpected")
            }
        }
    }
    var cli: DeviceCLI { DeviceCLI(executable: { [self] in installed ? URL(fileURLWithPath: "/fake/chirp-server") : nil }, run: run) }
    static func minted(_ name: String) -> String { "pair --name \(name) --url \(pairURL.absoluteString)" }
    static let pairOutput = Data("chirp://pair?url=https%3A%2F%2F\(host)%2Fchirp&token=\(deviceToken)\n█▀▀▀█ QR art ▀▀▀█\n".utf8)
}

/// An in-memory device store with the server's rules (unique names, ids), so flows and the list can be driven end to end.
private final class FakeStore: DeviceStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var devices: [PairedDevice] = []
    private(set) var minted: [String] = []
    var failure: DevicesError?
    init(_ devices: [PairedDevice] = []) { self.devices = devices }
    var current: [PairedDevice] { lock.withLock { devices } }

    func list() async throws(DevicesError) -> [PairedDevice] {
        if let failure { throw failure }
        return current
    }

    func revoke(id: String) async throws(DevicesError) {
        if let failure { throw failure }
        let found: Bool = lock.withLock {
            defer { devices.removeAll { $0.id == id } }
            return devices.contains { $0.id == id }
        }
        if !found { throw .rejected("No paired device has that name or id") }
    }

    func mint(name: String, serverURL: URL) async throws(DevicesError) -> PairingLink {
        if let failure { throw failure }
        let taken: Bool = lock.withLock {
            if devices.contains(where: { $0.name.lowercased() == name.lowercased() }) { return true }
            minted.append(name)
            devices.append(PairedDevice(id: String(format: "%08x", minted.count), name: name, created: now))
            return false
        }
        if taken { throw .rejected("A device with that name is already paired; revoke it first") }
        return try! PairingLink(serverURL: serverURL, token: deviceToken)
    }
}

@Suite struct DeviceNameTests {
    @Test func followsTheServersRules() {
        #expect(DeviceName.clean("  Pixel 9 ") == "Pixel 9")
        #expect(DeviceName.clean("Akshay’s phone 📱") == "Akshay’s phone 📱")
        #expect(DeviceName.clean(String(repeating: "a", count: 64)) != nil)
        for bad in ["", "   ", String(repeating: "a", count: 65), "two\nlines", "tab\there", "bell\u{7}", "zero\u{200B}width"] {
            #expect(DeviceName.clean(bad) == nil, "\(bad.debugDescription)")
        }
    }

    @Test func suggestsTheMacsNameAndFitsIt() {
        #expect(DeviceName.suggested(macName: "Rex’s MacBook Pro") == "Rex’s MacBook Pro’s phone")
        #expect(DeviceName.suggested(macName: nil) == "My phone" && DeviceName.suggested(macName: "  ") == "My phone")
        let long = DeviceName.suggested(macName: String(repeating: "m", count: 100))
        #expect(DeviceName.clean(long) == long)
    }
}

@Suite struct DeviceCLITests {
    @Test func listsDevicesFromTheServersJSON() async throws {
        let server = FakeServer()
        server.listing([
            ["id": "9f3a1c52", "name": "Pixel 9", "created": "2026-10-05T10:00:00Z", "last_seen": "2026-10-14T17:46:00Z", "revoked": nil],
            ["id": "04be77d1", "name": "iPad", "created": "2026-09-01T08:30:00Z", "last_seen": nil, "revoked": nil],
        ])
        let devices = try await server.cli.list()
        #expect(devices.map(\.name) == ["Pixel 9", "iPad"] && devices.map(\.id) == ["9f3a1c52", "04be77d1"])
        #expect(devices[0].created == ISO8601DateFormatter().date(from: "2026-10-05T10:00:00Z"))
        #expect(devices[0].lastSeen == ISO8601DateFormatter().date(from: "2026-10-14T17:46:00Z") && devices[1].lastSeen == nil)
        #expect(server.ran == [["devices", "list", "--json"]])
    }

    @Test func revokesByIDOnly() async throws {
        let server = FakeServer()
        server.answer("devices revoke 9f3a1c52", CommandResult(status: 0, output: Data("Revoked Pixel 9 (9f3a1c52)\n".utf8)))
        try await server.cli.revoke(id: "9f3a1c52")
        #expect(server.ran == [["devices", "revoke", "9f3a1c52"]])
        server.answer("devices revoke gone", CommandResult(status: 1, error: "No paired device has that name or id\n"))
        await #expect(throws: DevicesError.rejected("No paired device has that name or id")) { try await server.cli.revoke(id: "gone") }
    }

    @Test func mintsATokenAndBuildsTheLinkFromTheFirstLine() async throws {
        let server = FakeServer()
        server.answer(FakeServer.minted("Pixel 9"), CommandResult(status: 0, output: FakeServer.pairOutput, error: "Paired Pixel 9 (9f3a1c52); revoke with: chirp-server devices revoke 9f3a1c52\n"))
        let link = try await server.cli.mint(name: "Pixel 9", serverURL: pairURL)
        #expect(link == (try PairingLink(serverURL: pairURL, token: deviceToken)))
        #expect(link.uri == "chirp://pair?url=https%3A%2F%2F\(host)%2Fchirp&token=\(deviceToken)")
    }

    @Test func aServerWithoutDeviceTokensIsOutdated() async {
        let server = FakeServer()
        server.answer("devices list --json", CommandResult(status: 2, error: "chirp-server: error: argument command: invalid choice: 'devices'\n"))
        server.answer(FakeServer.minted("Pixel 9"), CommandResult(status: 2, error: "error: unrecognized arguments: --name Pixel 9\n"))
        await #expect(throws: DevicesError.outdated) { try await server.cli.list() }
        await #expect(throws: DevicesError.outdated) { try await server.cli.mint(name: "Pixel 9", serverURL: pairURL) }
    }

    @Test func theServersOwnRefusalIsShownAndNothingElseIs() async {
        let server = FakeServer()
        server.answer(FakeServer.minted("Pixel 9"), CommandResult(status: 1, error: "A device with that name is already paired; revoke it first\n"))
        await #expect(throws: DevicesError.rejected("A device with that name is already paired; revoke it first")) {
            try await server.cli.mint(name: "Pixel 9", serverURL: pairURL)
        }
        // A crash, a timeout, a launch failure or a trace is never echoed.
        for result in [CommandResult(status: 1, error: String(repeating: "x", count: 500)), CommandResult(status: -1), CommandResult(status: 127, error: "Couldn’t run it"), CommandResult(status: 3, error: "boom")] {
            server.answer("devices list --json", result)
            await #expect(throws: DevicesError.failed) { try await server.cli.list() }
        }
    }

    @Test func garbledOutputFailsWithoutLeakingIt() async {
        let server = FakeServer()
        server.answer("devices list --json", CommandResult(status: 0, output: Data("not json".utf8)))
        server.answer("devices list --json ", CommandResult(status: 0))
        await #expect(throws: DevicesError.failed) { try await server.cli.list() }
        server.answer(FakeServer.minted("Pixel 9"), CommandResult(status: 0, output: Data("some banner\n".utf8)))
        await #expect(throws: DevicesError.failed) { try await server.cli.mint(name: "Pixel 9", serverURL: pairURL) }
        server.answer(FakeServer.minted("Pixel 9"), CommandResult(status: 0, output: Data("chirp://pair?url=x\n".utf8)))
        await #expect(throws: DevicesError.failed) { try await server.cli.mint(name: "Pixel 9", serverURL: pairURL) }
    }

    @Test func noServerMeansNothingRuns() async {
        let server = FakeServer()
        server.installed = false
        await #expect(throws: DevicesError.noServer) { try await server.cli.list() }
        await #expect(throws: DevicesError.noServer) { try await server.cli.revoke(id: "9f3a1c52") }
        await #expect(throws: DevicesError.noServer) { try await server.cli.mint(name: "x", serverURL: pairURL) }
        #expect(server.ran.isEmpty)
    }

    @Test func theTokenNeverReachesAnErrorOrADump() async throws {
        let server = FakeServer()
        server.answer(FakeServer.minted("Pixel 9"), CommandResult(status: 0, output: FakeServer.pairOutput))
        let link = try await server.cli.mint(name: "Pixel 9", serverURL: pairURL)
        #expect(!"\(link)".contains(deviceToken) && !String(reflecting: link).contains(deviceToken))
        for e in [DevicesError.noServer, .outdated, .failed] { #expect(!e.message.contains(deviceToken)) }
    }
}

@MainActor
@Suite struct DevicePairingFlowTests {
    private func tailscale(served: Bool = true) -> (run: CommandRunner, ran: () -> [[String]]) {
        let box = CallLog()
        let output = served ? servedJSON : Data("{}".utf8)
        let status = TailscaleServeTests.json(["BackendState": "Running", "Self": ["DNSName": "\(host)."]])
        let run: CommandRunner = { _, arguments, _ in
            box.add(arguments)
            switch arguments.first {
            case "status": return CommandResult(status: 0, output: status)
            case "serve" where arguments.contains("--set-path"): return CommandResult(status: 0)
            default: return CommandResult(status: 0, output: box.count > 4 ? servedJSON : output)
            }
        }
        return (run, { box.all })
    }

    private func flow(_ store: FakeStore, served: Bool = true) -> (PairingFlow, () -> [[String]]) {
        let cli = tailscale(served: served)
        let flow = PairingFlow(serverURL: { URL(string: "http://127.0.0.1:7821")! }, cli: { URL(fileURLWithPath: "/fake/tailscale") }, run: cli.run,
                               deviceLinks: { DeviceTokenPairing(name: $0, store: store) }, suggestedName: { "Rex’s phone" })
        return (flow, cli.ran)
    }

    @Test func asksForANameBeforeAnythingElse() async {
        let store = FakeStore()
        let (f, ran) = flow(store)
        await f.begin()
        #expect(f.step == .naming(suggested: "Rex’s phone", problem: nil))
        #expect(ran().isEmpty && store.minted.isEmpty)
    }

    @Test func aNamedPairingMintsOneDeviceAndShowsItsLink() async throws {
        let store = FakeStore()
        let (f, _) = flow(store)
        await f.begin()
        await f.pair(named: "  Pixel 9 ")
        #expect(f.step == .ready(try PairingLink(serverURL: pairURL, token: deviceToken)))
        #expect(store.minted == ["Pixel 9"] && store.current.map(\.name) == ["Pixel 9"])
        // Checking again (Check Again, or after publishing) reuses the link instead of minting another phone.
        await f.check()
        #expect(store.minted == ["Pixel 9"])
    }

    @Test func nothingIsMintedUntilTailscaleServesChirp() async {
        let store = FakeStore()
        let (f, _) = flow(store, served: false)
        await f.begin()
        await f.pair(named: "Pixel 9")
        guard case .notServed = f.step else { Issue.record("\(f.step)"); return }
        #expect(store.minted.isEmpty)
        await f.publish()
        #expect(store.minted == ["Pixel 9"])
        guard case .ready = f.step else { Issue.record("\(f.step)"); return }
    }

    @Test func aBadNameGoesBackToTheNameWithoutRunningAnything() async {
        let store = FakeStore()
        let (f, ran) = flow(store)
        await f.begin()
        await f.pair(named: "   ")
        #expect(f.step == .naming(suggested: "   ", problem: DeviceName.rule))
        #expect(ran().isEmpty && store.minted.isEmpty)
    }

    @Test func aNameAlreadyPairedComesBackAsksAgainWithTheServersReason() async {
        let store = FakeStore([PairedDevice(id: "9f3a1c52", name: "Pixel 9", created: now)])
        let (f, _) = flow(store)
        await f.begin()
        await f.pair(named: "Pixel 9")
        #expect(f.step == .naming(suggested: "Pixel 9", problem: "A device with that name is already paired; revoke it first"))
        #expect(store.current.count == 1)
    }

    @Test func anOutdatedServerSaysSoAndTryAgainMintsAgain() async {
        let store = FakeStore()
        store.failure = .outdated
        let (f, _) = flow(store)
        await f.begin()
        await f.pair(named: "Pixel 9")
        #expect(f.step == .cannotMint(DevicesError.outdated.message))
        #expect(PairingPresentation(f.step).action == "Try Again")
        store.failure = nil
        await f.check()
        guard case .ready = f.step else { Issue.record("\(f.step)"); return }
        #expect(store.minted == ["Pixel 9"])
    }

    @Test func eachNewPairingAsksAgainAndMintsAgain() async {
        let store = FakeStore()
        let (f, _) = flow(store)
        await f.begin()
        await f.pair(named: "Pixel 9")
        f.reset()
        await f.begin()
        #expect(f.step == .naming(suggested: "Rex’s phone", problem: nil))
        await f.pair(named: "iPad")
        #expect(store.minted == ["Pixel 9", "iPad"])
    }

    @Test func withoutDeviceTokensItStillUsesTheSharedToken() async throws {
        let cli = tailscale()
        let f = PairingFlow(serverURL: { URL(string: "http://127.0.0.1:7821")! }, cli: { URL(fileURLWithPath: "/fake/tailscale") }, run: cli.run,
                            links: DeviceTokenPairing(name: "x", store: FakeStore()))
        await f.begin()
        guard case .ready = f.step else { Issue.record("\(f.step)"); return }
    }
}

private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    func add(_ a: [String]) { lock.withLock { calls.append(a) } }
    var all: [[String]] { lock.withLock { calls } }
    var count: Int { lock.withLock { calls.count } }
}

@MainActor
@Suite struct DevicesModelTests {
    private let pixel = PairedDevice(id: "9f3a1c52", name: "Pixel 9", created: now, lastSeen: nil)
    private let ipad = PairedDevice(id: "04be77d1", name: "iPad", created: now, lastSeen: now)

    @Test func listsWhatTheServerHas() async {
        let m = DevicesModel(store: FakeStore([pixel, ipad]))
        #expect(m.phase == .loading)
        await m.refresh()
        #expect(m.phase == .loaded([pixel, ipad]))
    }

    @Test func revokingTakesEffectAndTheListFollowsWithoutARestart() async {
        let store = FakeStore([pixel, ipad])
        let m = DevicesModel(store: store)
        await m.refresh()
        await m.revoke(pixel)
        #expect(m.phase == .loaded([ipad]) && m.problem == nil && m.revoking == nil)
        #expect(store.current == [ipad])
    }

    @Test func aFailedRevokeSaysWhyAndKeepsTheDevice() async {
        let store = FakeStore([pixel])
        let m = DevicesModel(store: store)
        await m.refresh()
        store.failure = .failed
        await m.revoke(pixel)
        #expect(m.problem == DevicesError.failed.message && m.revoking == nil)
        // The list could not be reloaded either, so it says that rather than showing a stale list.
        #expect(m.phase == .unavailable(DevicesError.failed.message))
        store.failure = nil
        await m.refresh()
        #expect(m.phase == .loaded([pixel]))
    }

    @Test func anOutdatedServerAndARemoteServerSayWhatToDo() async {
        let store = FakeStore()
        store.failure = .outdated
        let m = DevicesModel(store: store)
        await m.refresh()
        #expect(m.phase == .unavailable(DevicesError.outdated.message))
        let remote = DevicesModel(store: store, remoteHost: { "studio.example-tailnet.ts.net" })
        await remote.refresh()
        #expect(remote.phase == .remote("studio.example-tailnet.ts.net"))
    }

    @Test func changesAreAnnounced() async {
        let m = DevicesModel(store: FakeStore([pixel]))
        var changes = 0
        m.onChange = { changes += 1 }
        await m.refresh()
        #expect(changes == 1)
        await m.refresh()
        #expect(changes == 1)
    }
}

@MainActor
@Suite struct DevicesViewTests {
    private let pixel = PairedDevice(id: "9f3a1c52", name: "Pixel 9", created: now.addingTimeInterval(-9 * 86_400), lastSeen: now.addingTimeInterval(-40))
    private let ipad = PairedDevice(id: "04be77d1", name: "iPad", created: now.addingTimeInterval(-40 * 86_400), lastSeen: now.addingTimeInterval(-3 * 3_600))
    private let fresh = PairedDevice(id: "c81d20aa", name: "Fresh", created: now)
    private let en = Locale(identifier: "en_US")
    private let utc = TimeZone(identifier: "UTC")!

    private func buttons(_ view: NSView) -> [NSButton] {
        view.subviews.flatMap { sub in (sub as? NSButton).map { [$0] } ?? buttons(sub) }
    }

    @Test func sayWhenAPhoneWasPairedAndSeen() {
        #expect(DevicesText.detail(pixel, now: now, locale: en, timeZone: utc) == "Paired Oct 5, 2026 · seen just now")
        // The relative wording ("3h ago", "3 hr. ago") is the system's and differs between macOS versions.
        let later = DevicesText.detail(ipad, now: now, locale: en, timeZone: utc)
        #expect(later.hasPrefix("Paired Sep 4, 2026 · seen 3") && later.hasSuffix("ago"), "\(later)")
        #expect(DevicesText.detail(fresh, now: now, locale: en, timeZone: utc) == "Paired Oct 14, 2026 · not used yet")
    }

    @Test func eachPhoneGetsARevokeButtonThatAsksTheOwner() {
        let view = DevicesView()
        var asked: [String] = []
        view.onRevoke = { asked.append($0.id) }
        view.apply(.loaded([pixel, ipad]), revoking: nil, problem: nil, now: now, locale: en, timeZone: utc)
        let revokes = buttons(view)
        #expect(revokes.map(\.title) == ["Revoke…", "Revoke…"] && revokes.allSatisfy(\.isEnabled))
        #expect(revokes.map { $0.accessibilityLabel() } == ["Revoke Pixel 9", "Revoke iPad"])
        revokes[1].performClick(nil)
        #expect(asked == ["04be77d1"])
    }

    @Test func whileOneRevokesTheOthersWait() {
        let view = DevicesView()
        view.apply(.loaded([pixel, ipad]), revoking: pixel.id, problem: nil, now: now, locale: en, timeZone: utc)
        #expect(buttons(view).map(\.title) == ["Revoking…", "Revoke…"] && buttons(view).allSatisfy { !$0.isEnabled })
    }

    @Test func emptyLoadingAndErrorStatesHaveNoButtons() {
        let view = DevicesView()
        var resized = 0
        view.onResize = { resized += 1 }
        for phase in [DevicesPhase.loading, .loaded([]), .unavailable("x"), .remote("host")] { view.apply(phase, revoking: nil, problem: nil) }
        #expect(buttons(view).isEmpty && resized == 4 && view.devices.isEmpty)
    }

    @Test func theTabListsTheNoteAboutTheSharedToken() {
        #expect(DevicesText.sharedNote.contains("shared token") && DevicesText.rotateHelp.contains("pair again"))
        #expect(DevicesText.revokeTitle(pixel) == "Revoke “Pixel 9”?")
    }

    @Test func rotatingExplainsAndNeverContainsASecret() {
        #expect(SharedTokenRotation.warning.contains("pair"))
        #expect(SharedTokenRotation.commands.contains("rm ~/.config/chirp/token") && SharedTokenRotation.commands.contains("dev.chirp.server"))
    }
}

@MainActor
@Suite struct PairingNameViewTests {
    @Test func theNameStepShowsAFieldAndContinue() {
        let p = PairingPresentation(.naming(suggested: "Rex’s phone", problem: nil))
        #expect(p.asksName == "Rex’s phone" && p.action == "Continue" && p.tone == .normal && !p.showsCode)
        let refused = PairingPresentation(.naming(suggested: "Pixel 9", problem: "A device with that name is already paired; revoke it first"))
        #expect(refused.tone == .warning && refused.detail.hasPrefix("A device with that name"))
        #expect(PairingPresentation(.checking).asksName == nil && PairingPresentation(.cannotMint("x")).asksName == nil)
    }

    @Test func theFieldStartsFromTheSuggestionAndKeepsWhatWasTyped() {
        let view = PairingView()
        view.apply(.naming(suggested: "Rex’s phone", problem: nil))
        #expect(!view.nameField.isHidden && view.nameField.stringValue == "Rex’s phone")
        view.nameField.stringValue = "Pixel 9"
        // The window refreshes on focus changes; that must not overwrite the name being typed.
        view.apply(.naming(suggested: "Rex’s phone", problem: nil), concealed: true)
        #expect(view.nameField.stringValue == "Pixel 9")
        view.apply(.checking)
        #expect(view.nameField.isHidden)
        view.forget()
        #expect(view.nameField.stringValue.isEmpty)
    }
}
