import AppKit
import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

private let clock = Date(timeIntervalSince1970: 1_792_000_000)   // 2026-10-14 17:46:40 UTC
private let en = Locale(identifier: "en_US")
private let utc = TimeZone(identifier: "UTC")!
/// macOS writes "5:45 PM" with a narrow no-break space before the PM.
private func plain(_ text: String?) -> String? { text?.replacingOccurrences(of: "\u{202F}", with: " ") }

private let pixel = ActivitySource.device(id: "9f3a1c52", name: "Pixel 9", revoked: false)
private let ipad = ActivitySource.device(id: "04be77d1", name: "iPad", revoked: false)
private func isPixel(_ s: ActivitySource) -> Bool { if case .device(let id, _, _) = s { id == "9f3a1c52" } else { false } }
private func isShared(_ s: ActivitySource) -> Bool { s == .shared }
private func isLocal(_ s: ActivitySource) -> Bool { s == .local }

private func event(_ ago: TimeInterval, _ source: ActivitySource, _ kind: ActivityKind = .dictation, client: String? = "android",
                   audio: Int? = 4_000, ms: Int = 1_000, _ outcome: ActivityOutcome = .ok) -> ActivityEvent {
    ActivityEvent(at: clock.addingTimeInterval(-ago), source: source, client: client, kind: kind, durationMS: ms, audioMS: audio, outcome: outcome)
}

private let fixture = """
{
  "started": "2026-10-14T09:12:00Z",
  "keep": true,
  "retention": {"max_events": 5000, "max_age_days": 30},
  "active": [
    {"source": {"kind": "device", "id": "9f3a1c52", "name": "Pixel 9", "revoked": false},
     "client": "android", "kind": "dictation", "profile": "default", "since": "2026-10-14T17:46:37Z"}
  ],
  "events": [
    {"at": "2026-10-14T17:44:40Z", "source": {"kind": "shared"}, "client": "ios", "kind": "notes_segment", "profile": "live_notes",
     "corrected": true, "duration_ms": 2310, "audio_ms": 41800, "outcome": "ok"},
    {"at": "2026-10-14T17:40:00Z", "source": {"kind": "local"}, "client": "mac", "kind": "hologram", "duration_ms": 5, "audio_ms": null,
     "outcome": "melted", "extra": [1, 2]},
    {"at": "not a date", "source": {"kind": "local"}, "kind": "dictation", "duration_ms": 5, "outcome": "ok"},
    {"at": "2026-10-14T17:30:00Z", "source": {"kind": "drone"}, "kind": "notes_edit", "duration_ms": 9, "outcome": "preempted"}
  ],
  "refused": [
    {"reason": "unknown_token", "count": 3, "last": "2026-10-14T17:41:40Z"},
    {"reason": "revoked", "device": {"id": "11aa22bb", "name": "Old Pixel"}, "count": 2, "last": "2026-10-14T16:46:40Z"},
    {"reason": "no_token", "count": 1, "last": "later"}
  ],
  "future_field": {"anything": true}
}
"""

@Suite struct DeviceActivityDecodingTests {
    private func decoded() throws -> DeviceActivity { try DeviceActivityClient.decode(Data(fixture.utf8)) }

    @Test func readsTheDocumentedShape() throws {
        let a = try decoded()
        #expect(a.keep && a.maxEvents == 5000 && a.maxAgeDays == 30)
        #expect(a.started == clock.addingTimeInterval(-(8 * 3_600 + 34 * 60 + 40)))
        #expect(a.active == [ActiveRequest(source: pixel, client: "android", kind: .dictation, profile: "default", since: clock.addingTimeInterval(-3))])
        let first = a.events[0]
        #expect(first.source == .shared && first.client == "ios" && first.kind == .notesSegment && first.corrected == true)
        #expect(first.durationMS == 2310 && first.audioMS == 41_800 && first.outcome == .ok && first.profile == "live_notes")
    }

    @Test func unknownKindsOutcomesAndSourcesAreKept() throws {
        let a = try decoded()
        #expect(a.events[1].kind == .other("hologram") && a.events[1].outcome == .other("melted") && a.events[1].audioMS == nil)
        #expect(a.events[2].source == .other("drone") && a.events[2].kind == .notesEdit && a.events[2].outcome == .preempted)
    }

    @Test func aRowThisClientCannotReadIsSkippedNotTheList() throws {
        let a = try decoded()
        #expect(a.events.count == 3)   // the one with a broken date is gone
        #expect(a.refused.count == 2)
        #expect(a.refused[1].reason == .revoked && a.refused[1].deviceID == "11aa22bb" && a.refused[1].deviceName == "Old Pixel")
        #expect(a.refused[0].reason == .unknownToken && a.refused[0].count == 3)
    }

    @Test func missingOptionalPartsGetDefaults() throws {
        let a = try DeviceActivityClient.decode(Data(#"{"started":"2026-10-14T09:12:00Z"}"#.utf8))
        #expect(a.keep && a.isEmpty && a.maxEvents == 5000)
        #expect(throws: (any Error).self) { try DeviceActivityClient.decode(Data(#"{"started":"soon"}"#.utf8)) }
        #expect(throws: (any Error).self) { try DeviceActivityClient.decode(Data("[]".utf8)) }
    }

    @Test func offMeansKeepFalse() throws {
        let a = try DeviceActivityClient.decode(Data(#"{"started":"2026-10-14T09:12:00Z","keep":false,"events":[],"active":[],"refused":[]}"#.utf8))
        #expect(!a.keep && a.isEmpty)
    }
}

private final class ActivityFake: URLProtocol, @unchecked Sendable {
    struct Seen { var method: String; var url: String; var auth: String?; var body: Data? }
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var fails = false
    nonisolated(unsafe) static var seen: [Seen] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 256)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            body = data
        }
        Self.seen.append(Seen(method: request.httpMethod ?? "GET", url: request.url?.absoluteString ?? "",
                              auth: request.value(forHTTPHeaderField: "Authorization"), body: body))
        if Self.fails {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func reset(status: Int = 200, body: String = fixture, fails: Bool = false) -> URLSession {
        Self.status = status
        Self.body = Data(body.utf8)
        Self.fails = fails
        Self.seen = []
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [ActivityFake.self]
        return URLSession(configuration: c)
    }
}

/// These share one stub, so they run one at a time.
@Suite(.serialized) struct DeviceActivityClientTests {
    private func tokenFile(_ contents: String? = "owner-secret\n") throws -> String {
        let path = NSTemporaryDirectory() + "chirp-owner-token-\(UUID().uuidString)"
        if let contents { try contents.write(toFile: path, atomically: true, encoding: .utf8) }
        return path
    }

    private func client(_ session: URLSession, token: String?, base: String = "http://127.0.0.1:7821/chirp") throws -> DeviceActivityClient {
        DeviceActivityClient(baseURL: URL(string: base)!, ownerTokenPath: try tokenFile(token), session: session)
    }

    @Test func fetchSendsTheOwnerTokenToTheActivityPath() async throws {
        let session = ActivityFake.reset()
        let a = try await client(session, token: "owner-secret\n").fetch()
        #expect(a.events.count == 3)
        let seen = try #require(ActivityFake.seen.first)
        #expect(seen.method == "GET" && seen.url == "http://127.0.0.1:7821/chirp/v1/devices/activity" && seen.auth == "Bearer owner-secret")
    }

    @Test func theSharedTokenIsNeverSent() async throws {
        let session = ActivityFake.reset()
        _ = try await client(session, token: "owner-secret").fetch()
        #expect(ActivityFake.seen.allSatisfy { $0.auth == "Bearer owner-secret" })
    }

    @Test func refusalsHideAndAnOldServerSaysSo() async throws {
        for status in [401, 403] {
            let session = ActivityFake.reset(status: status, body: "{}")
            await #expect(throws: ActivityError.hidden) { try await client(session, token: "t").fetch() }
        }
        let old = ActivityFake.reset(status: 404, body: "{}")
        await #expect(throws: ActivityError.outdated) { try await client(old, token: "t").fetch() }
        let broken = ActivityFake.reset(status: 500, body: "{}")
        await #expect(throws: ActivityError.failed) { try await client(broken, token: "t").fetch() }
        let junk = ActivityFake.reset(status: 200, body: "not json")
        await #expect(throws: ActivityError.failed) { try await client(junk, token: "t").fetch() }
        let dead = ActivityFake.reset(fails: true)
        await #expect(throws: ActivityError.failed) { try await client(dead, token: "t").fetch() }
    }

    @Test func noOwnerTokenMeansHiddenWithoutAskingTheServer() async throws {
        let session = ActivityFake.reset()
        await #expect(throws: ActivityError.hidden) { try await client(session, token: nil).fetch() }
        await #expect(throws: ActivityError.hidden) { try await client(session, token: "  \n").fetch() }
        await #expect(throws: ActivityError.hidden) { try await client(session, token: nil).setKeep(false) }
        #expect(ActivityFake.seen.isEmpty)
    }

    @Test func switchingItOffPutsExactlyKeepFalse() async throws {
        let session = ActivityFake.reset(body: #"{"keep":false}"#)
        try await client(session, token: "owner-secret").setKeep(false)
        try await client(session, token: "owner-secret").setKeep(true)
        #expect(ActivityFake.seen.map(\.method) == ["PUT", "PUT"])
        #expect(ActivityFake.seen.map(\.url) == Array(repeating: "http://127.0.0.1:7821/chirp/v1/devices/activity/settings", count: 2))
        #expect(ActivityFake.seen.map { String(decoding: $0.body ?? Data(), as: UTF8.self) } == [#"{"keep":false}"#, #"{"keep":true}"#])
    }

    @Test func theOwnerTokenFileSitsBesideTheSharedOne() {
        #expect(ServerConfig.defaultOwnerTokenPath.hasSuffix("/.config/chirp/owner-token"))
        #expect(ServerConfig.defaultOwnerTokenPath.dropLast("owner-token".count) == ServerConfig.defaultTokenPath.dropLast("token".count))
    }
}

@Suite struct ActivityTextTests {
    @Test func kindsAndOutcomesHaveNames() {
        let kinds: [ActivityKind] = [.dictation, .notesSegment, .transcribe, .notesStructure, .notesReorganize, .notesEdit, .speakerModel, .other("x")]
        #expect(kinds.map(ActivityText.kindName) == ["Dictation", "Notes", "Transcribe", "Notes clean-up", "Organize", "Voice edit", "Speaker model", "Other"])
        #expect(ActivityText.outcomeName(.ok) == "OK" && ActivityText.outcomeName(.timeout) == "Timed out")
        #expect(ActivityText.outcomeName(.other("too_long")) == "Too Long" && ActivityText.outcomeName(.rejected) == "Clean-up rejected")
    }

    @Test func sourcesReadAsPeopleWouldSayThem() {
        #expect(ActivityText.sourceName(pixel) == "Pixel 9")
        #expect(ActivityText.sourceName(.device(id: "x", name: "Old Pixel", revoked: true)) == "Old Pixel (revoked)")
        #expect(ActivityText.sourceName(.device(id: "x", name: nil, revoked: false)) == "Unknown device")
        #expect(ActivityText.sourceName(.local) == "This Mac" && ActivityText.sourceName(.shared) == "Shared token")
        #expect(ActivityText.sourceName(.shared, client: "ios") == "Shared token · iOS")
    }

    @Test func lengthsAreInWholeSeconds() {
        #expect(ActivityText.length(4_000) == "4 seconds" && ActivityText.length(1_000) == "1 second" && ActivityText.length(61_000) == "1 min 1 s")
        #expect(ActivityText.length(nil) == "—")
        // An audio request shows the audio's length; the others how long they took.
        #expect(ActivityText.length(of: event(0, pixel, audio: 9_800, ms: 100)) == "10 seconds")
        #expect(ActivityText.length(of: event(0, pixel, .notesStructure, audio: nil, ms: 6_200)) == "6 seconds")
    }

    @Test func inUseNowAndLast() {
        let running = ActiveRequest(source: pixel, kind: .dictation, since: clock)
        #expect(ActivityText.inUse(running) == "In use now · Dictation")
        let events = (0..<12).map { event(Double($0) * 60 + 180, pixel, .notesStructure) } + [event(100, ipad)]
        let last = ActivityText.last(events, source: isPixel, now: clock, locale: en, timeZone: utc)
        #expect(last?.hasPrefix("Last: Notes clean-up ") == true && last?.hasSuffix(" · 12 requests today") == true)
        #expect(ActivityText.last(events, source: isShared, now: clock, locale: en, timeZone: utc) == nil)
        #expect(ActivityText.last([event(100, pixel)], source: isPixel, now: clock, locale: en, timeZone: utc)?.hasSuffix(" · 1 request today") == true)
    }

    @Test func todayIsTheLocalCalendarDay() {
        // 17:46 UTC is already the next morning in Auckland (UTC+13 in October), so earlier UTC events are "yesterday" there.
        let auckland = TimeZone(identifier: "Pacific/Auckland")!
        let events = [event(60, pixel), event(3 * 3_600, pixel), event(8 * 3_600, pixel), event(20 * 3_600, pixel)]
        #expect(ActivityText.requestsToday(events, source: isPixel, now: clock, timeZone: utc) == 3)
        #expect(ActivityText.requestsToday(events, source: isPixel, now: clock, timeZone: auckland) == 2)
    }

    @Test func aRunningRequestWinsOverTheLastOne() {
        let activity = DeviceActivity(started: clock, active: [ActiveRequest(source: pixel, kind: .notesSegment, since: clock)], events: [event(60, pixel)])
        #expect(ActivityText.line(activity, source: isPixel, now: clock, locale: en, timeZone: utc) == "In use now · Notes")
        #expect(ActivityText.line(activity, source: isLocal, now: clock, locale: en, timeZone: utc) == nil)
    }

    @Test func refusalsAreCountedInWords() {
        func line(_ r: Refusal) -> String { ActivityText.refusal(r, now: clock, locale: en) }
        let unknown = line(Refusal(reason: .unknownToken, count: 3, last: clock.addingTimeInterval(-300)))
        #expect(unknown.hasPrefix("3 refused requests with an unknown token · last "))
        #expect(line(Refusal(reason: .unknownToken, count: 1, last: clock)).hasPrefix("1 refused request with an unknown token"))
        #expect(line(Refusal(reason: .noToken, count: 2, last: clock)).hasPrefix("2 refused requests with no token"))
        let revoked = line(Refusal(reason: .revoked, deviceID: "x", deviceName: "Old Pixel", count: 2, last: clock.addingTimeInterval(-3_600)))
        #expect(revoked.hasPrefix("Old Pixel (revoked) tried 2 times · last "))
        #expect(line(Refusal(reason: .revoked, deviceName: "Old Pixel", count: 1, last: clock)).hasPrefix("Old Pixel (revoked) tried once"))
    }

    @Test func theFooterSaysWhatIsKeptAndNeverWhatWasSaid() {
        let a = DeviceActivity(started: Date(timeIntervalSince1970: 1_792_000_000 - 8 * 3_600 - 34 * 60), maxEvents: 5000, maxAgeDays: 30)
        let footer = ActivityText.footer(a, locale: en, timeZone: utc)
        #expect(plain(footer)?.hasPrefix("Since chirp-server started at 9:12 AM.") == true)
        #expect(footer.contains("30 days") && footer.contains("5,000") && footer.contains("on this Mac"))
        #expect(footer.hasSuffix("Never what was said or written."))
    }

    @Test func eachRowReadsAsOneSentence() {
        let e = event(3 * 3_600 + 60, pixel, .dictation, audio: 4_000)
        #expect(plain(ActivityText.spoken(e, now: clock, locale: en, timeZone: utc)) == "Pixel 9, Dictation, 4 seconds, OK, 2:45 PM")
    }

    @Test func timeColumnShowsTheDayWhenNotToday() {
        #expect(plain(ActivityText.when(clock.addingTimeInterval(-60), now: clock, locale: en, timeZone: utc)) == "5:45 PM")
        #expect(ActivityText.when(clock.addingTimeInterval(-86_400), now: clock, locale: en, timeZone: utc).hasPrefix("Oct 13, 2026"))
    }

    @Test func theFilterListsEachDeviceOnce() {
        let a = DeviceActivity(started: clock, active: [ActiveRequest(source: pixel, kind: .dictation, since: clock)],
                               events: [event(1, ipad), event(2, .device(id: "9f3a1c52", name: "Renamed", revoked: true)), event(3, .shared), event(4, .shared)])
        #expect(ActivityText.filterChoices(a).map(ActivityText.identity) == ["device:9f3a1c52", "device:04be77d1", "shared"])
    }

    @Test func clientsAreOnlyThoseOfTheSource() {
        let a = DeviceActivity(started: clock, events: [event(1, .shared, client: "ios"), event(2, .shared, client: "android"), event(3, .local, client: "mac"),
                                                       event(4, .shared, client: "ios")])
        #expect(ActivityText.clients(a, source: isShared) == ["iOS", "Android"])
        #expect(ActivityText.clients(a, source: isLocal) == ["Mac"])
    }

    @Test func keepFailuresAreOneSentence() {
        #expect(ActivityText.keepFailure(.outdated) == ActivityText.outdated && ActivityText.keepFailure(.failed).contains("nothing changed"))
    }
}

private final class FakeActivity: DeviceActivityFetching, @unchecked Sendable {
    var result: Result<DeviceActivity, ActivityError> = .success(DeviceActivity(started: clock))
    var fetches = 0
    var keeps: [Bool] = []
    var keepError: ActivityError?
    func fetch() async throws(ActivityError) -> DeviceActivity {
        fetches += 1
        return try result.get()
    }
    func setKeep(_ keep: Bool) async throws(ActivityError) {
        keeps.append(keep)
        if let keepError { throw keepError }
    }
}

private final class PhonesStore: DeviceStoring, @unchecked Sendable {
    var phones = [PairedDevice(id: "9f3a1c52", name: "Pixel 9", created: clock.addingTimeInterval(-9 * 86_400), lastSeen: clock.addingTimeInterval(-40))]
    func list() async throws(DevicesError) -> [PairedDevice] { phones }
    func revoke(id: String) async throws(DevicesError) {}
    func mint(name: String, serverURL: URL) async throws(DevicesError) -> PairingLink { throw .failed }
}

@MainActor @Suite struct DevicesActivityModelTests {
    private func model(_ fake: FakeActivity, remote: String? = nil) -> DevicesModel {
        DevicesModel(store: PhonesStore(), remoteHost: { remote }, activity: { fake })
    }

    @Test func aLocalServerShowsItsActivity() async {
        let fake = FakeActivity()
        fake.result = .success(DeviceActivity(started: clock, events: [event(5, pixel)]))
        let m = model(fake)
        await m.refresh()
        #expect(m.activity.activity?.events.count == 1 && fake.fetches == 1)
    }

    @Test func aRemoteServerNeverAsks() async {
        let fake = FakeActivity()
        let m = model(fake, remote: "studio.example.ts.net")
        await m.refresh()
        await m.refreshActivity()
        #expect(m.activity == .hidden && fake.fetches == 0)
    }

    @Test func refusedOrMissingTokenHidesAnOldServerAsksForAnUpdate() async {
        let fake = FakeActivity()
        let m = model(fake)
        fake.result = .failure(.hidden)
        await m.refresh()
        #expect(m.activity == .hidden)
        fake.result = .failure(.outdated)
        await m.refreshActivity()
        #expect(m.activity == .outdated)
        fake.result = .success(DeviceActivity(started: clock))
        await m.refreshActivity()
        #expect(m.activity.activity != nil)
        fake.result = .failure(.hidden)
        await m.refreshActivity()
        #expect(m.activity == .hidden)
    }

    @Test func aFailedPollKeepsWhatWasShown() async {
        let fake = FakeActivity()
        let m = model(fake)
        await m.refresh()
        let shown = m.activity
        fake.result = .failure(.failed)
        await m.refreshActivity()
        #expect(m.activity == shown && shown.activity != nil)
    }

    @Test func withoutAClientThereIsNoActivityPart() async {
        let m = DevicesModel(store: PhonesStore())
        await m.refresh()
        #expect(m.activity == .hidden)
    }

    @Test func theKeepSwitchAsksTheServerThenReloads() async {
        let fake = FakeActivity()
        let m = model(fake)
        await m.refresh()
        let before = fake.fetches
        await m.setKeepActivity(false)
        #expect(fake.keeps == [false] && fake.fetches == before + 1 && m.keepProblem == nil)
        fake.keepError = .hidden
        await m.setKeepActivity(true)
        #expect(m.keepProblem == ActivityText.keepFailure(.hidden))
        fake.keepError = nil
        await m.setKeepActivity(true)
        #expect(m.keepProblem == nil)
    }
}

@MainActor private final class FakeTimers {
    var started: [TimeInterval] = []
    var live = 0
    var ticks: [@MainActor () -> Void] = []
    var schedule: RepeatingSchedule {
        { [self] interval, tick in
            started.append(interval)
            live += 1
            ticks.append(tick)
            return { [self] in live -= 1 }
        }
    }
    func fire() { ticks.last?() }
}

@MainActor @Suite struct ActivityPollerTests {
    @Test func runsEveryFiveSecondsOnlyWhileTheTabOrTheSheetIsVisible() {
        let timers = FakeTimers()
        var refreshes = 0
        let poller = ActivityPoller(schedule: timers.schedule) { refreshes += 1 }
        #expect(!poller.isRunning && timers.live == 0)
        poller.tabVisible = true
        #expect(poller.isRunning && timers.live == 1 && timers.started == [5])
        timers.fire()
        timers.fire()
        #expect(refreshes == 2)
        poller.sheetVisible = true       // opening the sheet over the tab keeps the one timer
        #expect(timers.live == 1 && timers.started == [5])
        poller.tabVisible = false        // the sheet alone keeps it running
        #expect(poller.isRunning && timers.live == 1)
        poller.sheetVisible = false
        #expect(!poller.isRunning && timers.live == 0)
        poller.tabVisible = true
        poller.tabVisible = true
        #expect(timers.started == [5, 5] && timers.live == 1)
        poller.tabVisible = false
        #expect(timers.live == 0)
    }

    @Test func theIntervalIsFiveSeconds() { #expect(ActivityPolling.interval == 5) }
}

@MainActor @Suite struct DevicesViewActivityTests {
    private let phone = PairedDevice(id: "9f3a1c52", name: "Pixel 9", created: clock.addingTimeInterval(-9 * 86_400), lastSeen: clock.addingTimeInterval(-40))
    private let quiet = PairedDevice(id: "c81d20aa", name: "Quiet", created: clock)

    private func texts(_ view: NSView) -> [String] {
        view.subviews.flatMap { sub -> [String] in
            let own = (sub as? NSTextField).map { [$0.stringValue] } ?? []
            return own + texts(sub)
        }
    }

    private func buttons(_ view: NSView) -> [NSButton] {
        view.subviews.flatMap { sub in (sub as? NSButton).map { [$0] } ?? buttons(sub) }
    }

    private func apply(_ view: DevicesView, _ activity: ActivityPhase, phones: [PairedDevice]? = nil, keepProblem: String? = nil) {
        view.apply(.loaded(phones ?? [phone, quiet]), revoking: nil, problem: nil, activity: activity, keepProblem: keepProblem,
                   now: clock, locale: en, timeZone: utc)
    }

    private var busy: DeviceActivity {
        DeviceActivity(
            started: clock,
            active: [ActiveRequest(source: pixel, client: "android", kind: .dictation, since: clock.addingTimeInterval(-3))],
            events: [event(60, .local, client: "mac"), event(120, .shared, .notesSegment, client: "ios"), event(300, pixel)],
            refused: [Refusal(reason: .unknownToken, count: 3, last: clock.addingTimeInterval(-300)),
                      Refusal(reason: .revoked, deviceID: "11aa22bb", deviceName: "Old Pixel", count: 2, last: clock.addingTimeInterval(-3_600))])
    }

    @Test func phonesGetAnActivityLineAndQuietOnesNone() {
        let view = DevicesView()
        apply(view, .shown(busy))
        let all = texts(view)
        #expect(all.contains("● In use now · Dictation"))
        let quietAt = all.firstIndex(of: "Quiet")!
        #expect(all[quietAt + 1].hasPrefix("Paired ") && !all[quietAt + 2].hasPrefix("Last:") && !all[quietAt + 2].contains("In use"))
    }

    @Test func thisMacAndTheSharedTokenGetRowsWithoutRevoke() {
        let view = DevicesView()
        apply(view, .shown(busy))
        let all = texts(view)
        #expect(all.contains("This Mac") && all.contains("Shared token") && all.contains("via iOS"))
        #expect(buttons(view).filter { $0.title == "Revoke…" }.count == 2)   // the two phones only
        #expect(all.firstIndex(of: "This Mac")! < all.firstIndex(of: "Pixel 9")!)
        #expect(all.firstIndex(of: "Shared token")! < all.firstIndex(of: "Pixel 9")!)
    }

    @Test func noActivityMeansNoExtraRows() {
        let view = DevicesView()
        let activity = DeviceActivity(started: clock, events: [event(60, pixel)])
        apply(view, .shown(activity))
        #expect(!texts(view).contains("This Mac") && !texts(view).contains("Shared token"))
    }

    @Test func refusalsShowInOrangeOnlyWhenThereAreSome() {
        let view = DevicesView()
        apply(view, .shown(busy))
        let fields = view.subviews.compactMap { $0 as? NSTextField }
        let refusals = fields.filter { $0.stringValue.contains("refused") || $0.stringValue.contains("tried") }
        #expect(refusals.count == 2 && refusals.allSatisfy { $0.textColor == .systemOrange })
        #expect(refusals[1].stringValue.hasPrefix("Old Pixel (revoked) tried 2 times"))
        apply(view, .shown(DeviceActivity(started: clock, events: [event(60, pixel)])))
        #expect(!texts(view).contains { $0.contains("refused") })
    }

    @Test func theActivityButtonAndTheSwitchWork() {
        let view = DevicesView()
        var shown = 0
        var kept: [Bool] = []
        view.onShowActivity = { shown += 1 }
        view.onKeepActivity = { kept.append($0) }
        apply(view, .shown(busy))
        let show = buttons(view).first { $0.title == "Activity…" }
        let keep = buttons(view).first { $0.title == ActivityText.keepTitle }
        #expect(show != nil && keep != nil && keep?.state == .on)
        show?.performClick(nil)
        keep?.performClick(nil)
        #expect(shown == 1 && kept == [false])
    }

    @Test func switchedOffThereIsOnlyTheSwitchAndNoActivityLines() {
        let view = DevicesView()
        apply(view, .shown(DeviceActivity(started: clock, keep: false)))
        let all = texts(view)
        #expect(all.contains(ActivityText.keepOff) && !all.contains { $0.hasPrefix("Last:") || $0.contains("In use now") })
        #expect(buttons(view).first { $0.title == "Activity…" } == nil)
        #expect(buttons(view).first { $0.title == ActivityText.keepTitle }?.state == .off)
    }

    @Test func anOldServerGetsTheOneLineNote() {
        let view = DevicesView()
        apply(view, .outdated)
        #expect(texts(view).contains("Update chirp-server to see device activity."))
        #expect(buttons(view).first { $0.title == "Activity…" } == nil && buttons(view).first { $0.title == ActivityText.keepTitle } == nil)
    }

    @Test func hiddenActivityChangesNothing() {
        let plain = DevicesView()
        plain.apply(.loaded([phone, quiet]), revoking: nil, problem: nil, now: clock, locale: en, timeZone: utc)
        let hidden = DevicesView()
        apply(hidden, .hidden)
        #expect(texts(plain) == texts(hidden))
        let remote = DevicesView()
        remote.apply(.remote("studio.example.ts.net"), revoking: nil, problem: nil, activity: .shown(busy), now: clock, locale: en, timeZone: utc)
        #expect(!texts(remote).contains("This Mac") && buttons(remote).isEmpty)
    }

    @Test func aFailedChangeShowsItsReason() {
        let view = DevicesView()
        apply(view, .shown(busy), keepProblem: ActivityText.keepFailure(.failed))
        #expect(texts(view).contains(ActivityText.keepFailure(.failed)))
    }
}

@MainActor @Suite struct DeviceActivitySheetTests {
    private let activity = DeviceActivity(
        started: clock,
        events: [event(60, .local, client: "mac"), event(120, pixel, audio: 9_800), event(300, ipad, .notesStructure, audio: nil, ms: 6_200, .timeout),
                 event(400, pixel, audio: 2_000, .cancelled)])

    private func make() -> DeviceActivityView {
        let view = DeviceActivityView()
        view.apply(activity, now: clock, locale: en, timeZone: utc)
        return view
    }

    @Test func showsTheFiveColumnsNewestFirst() {
        let view = make()
        #expect(view.table.tableColumns.map(\.title) == ["Time", "Device", "What", "Length", "Result"])
        #expect(view.shownEvents.map(\.at) == activity.events.map(\.at))
        #expect(view.table.numberOfRows == 4)
    }

    @Test func theFilterListsEveryDeviceAndNarrowsTheRows() {
        let view = make()
        #expect(view.filter.itemTitles == ["All devices", "This Mac", "Pixel 9", "iPad"])
        view.filter.selectItem(at: 2)
        _ = view.filter.target?.perform(view.filter.action, with: view.filter)
        #expect(view.shownEvents.count == 2 && view.shownEvents.allSatisfy { ActivityText.identity($0.source) == "device:9f3a1c52" })
        view.select(deviceIdentity: nil)
        #expect(view.shownEvents.count == 4)
    }

    @Test func theFilterSurvivesARefreshWhileThatDeviceHasRequests() {
        let view = make()
        view.select(deviceIdentity: "device:04be77d1")
        view.apply(activity, now: clock, locale: en, timeZone: utc)
        #expect(view.shownEvents.count == 1 && view.filter.titleOfSelectedItem == "iPad")
        view.apply(DeviceActivity(started: clock, events: [event(1, .local)]), now: clock, locale: en, timeZone: utc)
        #expect(view.shownEvents.count == 1 && view.filter.titleOfSelectedItem == "All devices")
    }

    @Test func rowsReadAsOneSentenceToVoiceOver() {
        let view = make()
        let row = view.tableView(view.table, rowViewForRow: 1)
        #expect(plain(row?.accessibilityLabel()) == "Pixel 9, Dictation, 10 seconds, OK, 5:44 PM")
        #expect(plain(view.tableView(view.table, rowViewForRow: 2)?.accessibilityLabel()) == "iPad, Notes clean-up, 6 seconds, Timed out, 5:41 PM")
    }

    @Test func cellsShowTheColumnsText() throws {
        let view = make()
        func cell(_ column: Int, _ row: Int) -> String? {
            plain((view.tableView(view.table, viewFor: view.table.tableColumns[column], row: row) as? NSTextField)?.stringValue)
        }
        #expect((0..<5).map { cell($0, 2) } == ["5:41 PM", "iPad", "Notes clean-up", "6 seconds", "Timed out"])
        #expect((0..<5).map { cell($0, 0) } == ["5:45 PM", "This Mac", "Dictation", "4 seconds", "OK"])
    }

    @Test func footerAndEmptyState() {
        let view = make()
        #expect(ActivityText.footer(activity, locale: en, timeZone: utc).hasSuffix("Never what was said or written."))
        view.apply(DeviceActivity(started: clock), now: clock, locale: en, timeZone: utc)
        #expect(view.shownEvents.isEmpty && view.table.numberOfRows == 0)
    }

    @Test func doneCallsBack() {
        let view = make()
        var done = 0
        view.onDone = { done += 1 }
        view.doneButton.performClick(nil)
        #expect(done == 1)
    }
}
