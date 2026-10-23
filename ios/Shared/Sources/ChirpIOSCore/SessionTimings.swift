import Foundation

/// Content-free timings of recent dictations, ported from Android (#73). Numbers and fixed enums only: no text,
/// audio, URLs, hosts, tokens or device identifiers. Durations are milliseconds.
public struct SessionTiming: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable, CaseIterable { case final, empty, kept, failed, cancelled }
    public enum Source: String, Codable, Sendable { case app, keyboard, companion }
    public enum Network: String, Codable, Sendable, CaseIterable { case wifi, cellular, wired, other, none }
    public var time: Date
    public var outcome: Outcome
    public var error: DiagnosticCode?
    public var source: Source
    public var network: Network
    public var readyMs: Int?
    public var firstPartialMs: Int?
    public var stopFinalMs: Int?
    public var polishMs: Int?
    public var audioMs: Int
    /// Long dictation: how many utterances this dictation used.
    public var segments: Int
    public init(time: Date, outcome: Outcome, error: DiagnosticCode? = nil, source: Source, network: Network,
                readyMs: Int? = nil, firstPartialMs: Int? = nil, stopFinalMs: Int? = nil, polishMs: Int? = nil,
                audioMs: Int, segments: Int = 1) {
        self.time = time; self.outcome = outcome; self.error = error; self.source = source; self.network = network
        self.readyMs = readyMs; self.firstPartialMs = firstPartialMs; self.stopFinalMs = stopFinalMs
        self.polishMs = polishMs; self.audioMs = audioMs; self.segments = segments
    }
}

/// Measures one dictation on a single clock; `finish` produces its entry exactly once.
public struct SessionTimer: Sendable {
    private let began: Date
    private var readyAt: Date?, firstPartialAt: Date?, stopAt: Date?, polishAt: Date?
    private var done = false
    public private(set) var segments = 1
    public init(now: Date) { began = now }
    public mutating func ready(_ now: Date) { if readyAt == nil { readyAt = now } }
    public mutating func partial(_ now: Date) { if firstPartialAt == nil { firstPartialAt = now } }
    public mutating func stopped(_ now: Date) { if stopAt == nil { stopAt = now } }
    public mutating func polishing(_ now: Date) { if polishAt == nil { polishAt = now } }
    public mutating func rolledOver() { segments += 1 }
    public mutating func finish(_ outcome: SessionTiming.Outcome, error: DiagnosticCode? = nil, source: SessionTiming.Source,
                                network: SessionTiming.Network, now: Date) -> SessionTiming? {
        guard !done else { return nil }
        done = true
        func ms(_ from: Date?, _ to: Date?) -> Int? {
            guard let from, let to else { return nil }
            return max(0, min(Int((to.timeIntervalSince(from) * 1000).rounded()), 86_400_000))
        }
        let completed = outcome == .final || outcome == .empty
        return SessionTiming(time: now, outcome: outcome, error: error, source: source, network: network,
                             readyMs: ms(began, readyAt), firstPartialMs: ms(began, firstPartialAt),
                             stopFinalMs: completed ? ms(stopAt, now) : nil, polishMs: completed ? ms(polishAt, now) : nil,
                             audioMs: ms(began, stopAt ?? now) ?? 0, segments: segments)
    }
}

/// The last `maximum` dictations in a protected file. Never synced; Clear removes them all.
public final class TimingLog: Sendable {
    public static let maximum = 50
    private let files: ProtectedFiles
    public init(root: URL) throws { files = try ProtectedFiles(root: root.appendingPathComponent("timings", isDirectory: true)) }
    public func record(_ entry: SessionTiming) throws {
        try files.transaction {
            let current = (try? files.load([SessionTiming].self, "timings.json", max: 262_144)) ?? []
            try files.save(Array((current + [entry]).suffix(Self.maximum)), "timings.json", max: 262_144)
        }
    }
    public func entries() throws -> [SessionTiming] {
        try files.transaction { (try? files.load([SessionTiming].self, "timings.json", max: 262_144)) ?? [] }
    }
    public func clear() throws { try files.transaction { try files.remove("timings.json") } }
}

public enum TimingSummary {
    /// Plain lines for Diagnostics: nearest-rank p50/p90 per phase, then outcome, error and network counts.
    public static func text(_ entries: [SessionTiming]) -> String {
        guard !entries.isEmpty else { return "No dictations recorded" }
        func row(_ label: String, _ values: [Int], seconds: Bool = false) -> String {
            guard !values.isEmpty else { return "\(label)  –" }
            let sorted = values.sorted()
            func rank(_ p: Double) -> Int { sorted[max(0, min(sorted.count - 1, Int((p * Double(sorted.count)).rounded(.up)) - 1))] }
            func show(_ v: Int) -> String { seconds ? String(format: "%.1f s", Double(v) / 1000) : "\(v) ms" }
            return "\(label)  p50 \(show(rank(0.5))) · p90 \(show(rank(0.9))) · n=\(values.count)"
        }
        func counts<T: RawRepresentable>(_ values: [T]) -> String where T.RawValue == String {
            Dictionary(grouping: values, by: \.rawValue).sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.count)" }.joined(separator: " · ")
        }
        var lines = ["Last \(entries.count) of up to \(TimingLog.maximum) dictations",
                     row("ready", entries.compactMap(\.readyMs)),
                     row("first partial", entries.compactMap(\.firstPartialMs)),
                     row("stop → final", entries.compactMap(\.stopFinalMs)),
                     row("polishing", entries.compactMap(\.polishMs)),
                     row("audio", entries.map(\.audioMs), seconds: true),
                     "Outcomes: " + counts(entries.map(\.outcome))]
        let errors = entries.compactMap(\.error)
        if !errors.isEmpty { lines.append("Errors: " + counts(errors)) }
        lines.append("Network: " + counts(entries.map(\.network)))
        let long = entries.filter { $0.segments > 1 }.count
        if long > 0 { lines.append("Long dictations: \(long)") }
        return lines.joined(separator: "\n")
    }
}
