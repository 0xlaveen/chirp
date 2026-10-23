import ChirpCore
import ChirpIOSCore
import Foundation
import Testing
@testable import ChirpIOS

extension SessionCoordinatorTests {
    @Test func everyDictationLeavesOneContentFreeTiming() async throws {
        let f = try await fixture(); defer { f.clean() }
        try await f.model.begin(source: .keyboard)
        try await ready(f)
        f.transport.push(#"{"type":"partial","seq":1,"text":"secret words","stable":""}"#)
        try await eventually { f.model.text == "secret words" }
        f.model.stopDictation()
        f.transport.push(#"{"type":"final","text":"Secret words."}"#)
        try await eventually { f.model.phase == .finished }
        f.model.cancelDictation() // after the final: nothing more is recorded for it
        let entries = try f.stores.timings.entries()
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.outcome == .final && entry.source == .keyboard && entry.error == nil && entry.segments == 1)
        #expect(entry.readyMs != nil && entry.firstPartialMs != nil && entry.stopFinalMs != nil)
        #expect(f.model.timingSummary.contains("Last 1 of up to 50 dictations"))
        #expect(!f.model.timingSummary.contains("secret") && !f.model.diagnosticText.lowercased().contains("secret"))
        f.model.clearTimings()
        #expect(try f.stores.timings.entries().isEmpty && f.model.timingSummary == "No dictations recorded")
    }

    @Test func aCancelledDictationIsCounted() async throws {
        let f = try await fixture(); defer { f.clean() }
        try await f.model.begin()
        try await ready(f)
        f.model.cancelDictation()
        #expect(try f.stores.timings.entries().map(\.outcome) == [.cancelled])
    }

    @Test func aLongDictationCountsItsSegments() async throws {
        let f = try await fixture(); defer { f.clean() }
        try await rolled(f)
        f.model.stopDictation()
        push(f, 0, #"{"type":"final","text":"One."}"#)
        push(f, 1, #"{"type":"final","text":"Two."}"#)
        try await eventually { f.model.phase == .finished }
        let entries = try f.stores.timings.entries()
        #expect(entries.map(\.outcome) == [.final])
        #expect(entries.last?.segments == 2 && entries.last?.source == .keyboard)
    }
}
