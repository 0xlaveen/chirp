import SwiftUI

/// The Pond motif: three concentric koi rings expanding out of the mic — *the* "Chirp is listening"
/// sign (record button, session capsule, empty states). A port of `mac/Sources/ChirpUI/Ripple.swift`.
///
/// The input level drives the tempo: each ring scales 1 → 1.8 while its opacity goes 0.5 → 0,
/// staggered by a third, and the period shortens from 1.6 s at silence to 0.6 s at peak level —
/// speech makes the water ripple faster. Reduce Motion shows one static koi ring whose stroke
/// weight follows the level instead.
///
/// Imports only SwiftUI (no `ChirpCore`), so the widget target can compile it too.
public struct Ripple: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The normalized input level, 0...1.
    var level: Double
    /// A fixed phase (0...1) for snapshots; nil runs on the clock.
    var phase: Double?
    /// The rings' colour: koiDecor, a large-shape-only token.
    var color: Color
    /// The static ring's colour (Reduce Motion).
    var staticColor: Color
    /// The side the rings are laid out in.
    var side: CGFloat

    public init(level: Double = 0, phase: Double? = nil, color: Color = Color.chirp.koiDecor,
                staticColor: Color = Color.chirp.koi, side: CGFloat = 24) {
        self.level = level
        self.phase = phase
        self.color = color
        self.staticColor = staticColor
        self.side = side
    }

    /// Seconds per ring cycle at silence, and at peak level.
    public static let periodAtSilence: Double = 1.6
    public static let periodAtPeak: Double = 0.6

    /// The cycle length for a level: 1.6 s at silence, 0.6 s at peak, linear in between.
    public static func period(level: Double) -> Double {
        periodAtSilence + (periodAtPeak - periodAtSilence) * min(max(level, 0), 1)
    }

    public var body: some View {
        Group {
            if reduceMotion {
                staticRing
            } else if let phase {
                rings(phase: phase)
            } else {
                TimelineView(.animation) { context in
                    rings(phase: Self.clockPhase(at: context.date, level: level))
                }
            }
        }
        .frame(width: side, height: side)
    }

    /// Where the ring cycle stands (0...1) at a moment in time.
    static func clockPhase(at date: Date, level: Double) -> Double {
        let period = period(level: level)
        return date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
    }

    private func rings(phase: Double) -> some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            // The outermost ring (scale 1.8) just fits the box; strokes thin slightly as they expand.
            let base = min(size.width, size.height) / 1.8
            let line = max(size.width / 12, 1.2)
            for index in 0..<3 {
                let progress = (phase + Double(index) / 3).truncatingRemainder(dividingBy: 1)
                let diameter = base * (1 + 0.8 * progress)
                let opacity = 0.5 * (1 - progress)
                let rect = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
                context.stroke(Path(ellipseIn: rect), with: .color(color.opacity(opacity)),
                               style: StrokeStyle(lineWidth: line * (1 - 0.35 * progress)))
            }
        }
        .accessibilityHidden(true)
    }

    /// Reduce Motion: one steady koi ring whose stroke weight follows the level.
    private var staticRing: some View {
        Circle()
            .strokeBorder(staticColor, lineWidth: max(side / 14, 1.2) + side / 8 * min(max(level, 0), 1))
            .padding(side * 0.14)
            .accessibilityHidden(true)
    }
}
