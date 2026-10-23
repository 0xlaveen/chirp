import Foundation
import Testing
@testable import ChirpIOSCore

/// Ported from Android's SessionTimingsTest (#73).
struct SessionTimingsTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ ms: Int) -> Date { start.addingTimeInterval(Double(ms) / 1000) }

    @Test func recordsEveryPhaseOnceOnOneClock() throws {
        var timer = SessionTimer(now: start)
        timer.ready(at(300)); timer.ready(at(900))
        timer.partial(at(700)); timer.stopped(at(5_000)); timer.polishing(at(5_200))
        let finished = timer.finish(.final, source: .keyboard, network: .wifi, now: at(5_900))
        let entry = try #require(finished)
        #expect(entry.readyMs == 300 && entry.firstPartialMs == 700)
        #expect(entry.stopFinalMs == 900 && entry.polishMs == 700 && entry.audioMs == 5_000)
        #expect(entry.source == .keyboard && entry.network == .wifi && entry.segments == 1)
        let again = timer.finish(.cancelled, source: .keyboard, network: .wifi, now: at(6_000))
        #expect(again == nil, "One entry per dictation")
    }

    @Test func failuresKeepTheirCodeButNoFinishTimes() throws {
        var timer = SessionTimer(now: start)
        timer.ready(at(200)); timer.stopped(at(3_000)); timer.rolledOver()
        let finished = timer.finish(.kept, error: .unreachable, source: .app, network: .cellular, now: at(4_000))
        let entry = try #require(finished)
        #expect(entry.error == .unreachable && entry.stopFinalMs == nil && entry.polishMs == nil)
        #expect(entry.firstPartialMs == nil && entry.audioMs == 3_000 && entry.segments == 2)
    }

    @Test func logKeepsTheLast50AcrossReloadsAndClears() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-timings-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = try TimingLog(root: root)
        for i in 0..<60 { try log.record(SessionTiming(time: at(i), outcome: .final, source: .app, network: .wifi, audioMs: i)) }
        let reloaded = try TimingLog(root: root).entries()
        #expect(reloaded.count == 50 && reloaded.first?.audioMs == 10 && reloaded.last?.audioMs == 59)
        try log.clear()
        #expect(try log.entries().isEmpty)
    }

    @Test func storedEntriesAreNumbersAndFixedWordsOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-timings-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = try TimingLog(root: root)
        try log.record(SessionTiming(time: start, outcome: .failed, error: .notFound, source: .companion, network: .none, readyMs: 12, audioMs: 34))
        let data = try #require(try Data(contentsOf: root.appendingPathComponent("timings/timings.json")))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let allowed: Set<String> = ["time", "outcome", "error", "source", "network", "readyMs", "firstPartialMs",
                                    "stopFinalMs", "polishMs", "audioMs", "segments"]
        #expect(Set(json[0].keys).isSubset(of: allowed))
        for value in json[0].values { #expect(value is NSNumber || ["failed", "notFound", "companion", "none"].contains(value as? String)) }
    }

    @Test func summaryUsesNearestRankPercentiles() {
        #expect(TimingSummary.text([]) == "No dictations recorded")
        let entries = (1...10).map {
            SessionTiming(time: at($0), outcome: $0 == 10 ? .kept : .final, error: $0 == 10 ? .busy : nil, source: .keyboard,
                          network: .wifi, readyMs: $0 * 100, audioMs: $0 * 1_000, segments: $0 == 1 ? 3 : 1)
        }
        let text = TimingSummary.text(entries)
        #expect(text.contains("Last 10 of up to 50 dictations"))
        #expect(text.contains("ready  p50 500 ms · p90 900 ms · n=10"))
        #expect(text.contains("audio  p50 5.0 s · p90 9.0 s · n=10"))
        #expect(text.contains("first partial  –"))
        #expect(text.contains("Outcomes: final 9 · kept 1") && text.contains("Errors: busy 1"))
        #expect(text.contains("Network: wifi 10") && text.contains("Long dictations: 1"))
    }
}
