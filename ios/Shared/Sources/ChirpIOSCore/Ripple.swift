import SwiftUI

/// The Pond motif: three concentric koi rings expanding out of the mic — *the* "Chirp is listening"
/// sign (the Dictate mic, the session capsule, the recording note row, the keyboard strip). A port of
/// the Mac's `ChirpUI/Ripple.swift` and Android's `ui/Ripple.kt`.
///
/// The input level drives the tempo: each ring scales 1 → 1.8 while its opacity goes 0.5 → 0,
/// staggered by a third, and the period shortens from 1.6 s at silence to 0.6 s at peak level —
/// speech makes the water ripple faster. Reduce Motion shows one static koi ring whose stroke
/// weight follows the level instead. Imports SwiftUI only, so the widget extension can compile it in.
public struct Ripple: View {
    /// The normalized input level, 0...1.
    var level: Double
    /// A fixed phase (0...1) for snapshots; nil runs on the clock.
    var phase: Double?
    /// Overrides the environment's Reduce Motion (snapshots); nil follows the system setting.
    var reduceMotion: Bool?
    /// The rings' colour: koiDecor, a large-shape-only token.
    var color: Color
    /// The static ring's colour (Reduce Motion).
    var staticColor: Color
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    /// Seconds per ring cycle at silence, and at peak level.
    nonisolated public static let periodAtSilence: Double = 1.6
    nonisolated public static let periodAtPeak: Double = 0.6

    public init(level: Double, phase: Double? = nil, reduceMotion: Bool? = nil,
                color: Color = Color.chirp.koiDecor, staticColor: Color = Color.chirp.koi) {
        self.level = level
        self.phase = phase
        self.reduceMotion = reduceMotion
        self.color = color
        self.staticColor = staticColor
    }

    /// The cycle length for a level: 1.6 s at silence, 0.6 s at peak, linear in between.
    nonisolated public static func period(level: Double) -> Double {
        periodAtSilence + (periodAtPeak - periodAtSilence) * min(max(level, 0), 1)
    }

    /// Where the ring cycle stands (0...1) at a moment in time.
    nonisolated public static func clockPhase(at date: Date, level: Double) -> Double {
        let period = period(level: level)
        return date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
    }

    public var body: some View {
        Group {
            if reduceMotion ?? systemReduceMotion {
                staticRing
            } else if let phase {
                rings(phase: phase)
            } else {
                TimelineView(.animation) { context in
                    rings(phase: Self.clockPhase(at: context.date, level: level))
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private func rings(phase: Double) -> some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            // The outermost ring (scale 1.8) just fits the box; strokes thin slightly as they expand.
            let base = side / 1.8
            let line = max(side / 12, 1.2)
            for index in 0..<3 {
                let progress = (phase + Double(index) / 3).truncatingRemainder(dividingBy: 1)
                let diameter = base * (1 + 0.8 * progress)
                let rect = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
                context.stroke(Path(ellipseIn: rect), with: .color(color.opacity(0.5 * (1 - progress))),
                               style: StrokeStyle(lineWidth: line * (1 - 0.35 * progress)))
            }
        }
    }

    /// Reduce Motion: one steady koi ring whose stroke weight follows the level.
    private var staticRing: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            Circle()
                .strokeBorder(staticColor, lineWidth: max(side / 14, 1.2) + side / 8 * min(max(level, 0), 1))
                .padding(side * 0.14)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}
