import Foundation

/// The faults `--notes-selftest --fault` injects on the client, by audio time: `drop@30` loses the open socket at 30 s,
/// `down@60-90` loses it at 60 s and refuses every new one until 90 s (a server restart or a network outage).
public struct NotesFaultPlan: Equatable, Sendable {
    public enum Fault: Equatable, Sendable {
        case drop(at: TimeInterval)
        case down(from: TimeInterval, to: TimeInterval)

        /// When the open socket is lost.
        public var start: TimeInterval {
            switch self {
            case .drop(let t): t
            case .down(let from, _): from
            }
        }
    }

    public var faults: [Fault]

    public init(_ faults: [Fault] = []) { self.faults = faults }

    public static let syntax = "drop@SECONDS | down@FROM-TO, comma-separated (audio seconds)"

    /// `drop@30,down@60-90`; nil for anything else.
    public static func parse(_ text: String) -> NotesFaultPlan? {
        var faults: [Fault] = []
        for item in text.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            let parts = item.split(separator: "@", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            switch parts[0] {
            case "drop":
                guard let t = Double(parts[1]), t >= 0 else { return nil }
                faults.append(.drop(at: t))
            case "down":
                let range = parts[1].split(separator: "-", maxSplits: 1).compactMap { Double($0) }
                guard range.count == 2, range[0] >= 0, range[1] > range[0] else { return nil }
                faults.append(.down(from: range[0], to: range[1]))
            default: return nil
            }
        }
        return faults.isEmpty ? nil : NotesFaultPlan(faults)
    }

    /// New connections are refused at audio time `t`.
    public func isDown(at t: TimeInterval) -> Bool {
        faults.contains { if case .down(let from, let to) = $0 { from <= t && t < to } else { false } }
    }

    /// A socket opened at `opened` is lost by audio time `now`.
    public func drops(opened: TimeInterval, now: TimeInterval) -> Bool {
        faults.contains { opened < $0.start && $0.start <= now }
    }
}
