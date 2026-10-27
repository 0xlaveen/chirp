import AppKit
import ChirpCore
import SwiftUI

/// The word waveform: the live transcript laid out word by word, each word with the bars of its own audio directly above
/// it, so the mapping from sound to text is spatial and immediate. Words wrap like text; a pause between words widens
/// the gap and draws a faint dotted rest in the ribbon. Every word's bars are tinted koi; a word being recognised is stronger and pulses; it settles to the
/// solid colour once later partials leave it alone, a revised word crossfades in place, and dropped older words are
/// marked with an ellipsis. Reduce Motion keeps the layout and drops the pulse, the springs and the shimmer sweep.
struct WordWaveformView: View {
    let cells: [WordCell]
    let levels: UtteranceLevels
    let revised: Set<Int>
    let truncated: Bool
    /// Clean-up runs on these words: the shimmer sweeps across the whole ribbon and no word is "current".
    let polishing: Bool
    let animated: Bool
    let contrast: Bool
    var pulsePhase: Double?
    var shimmerPhase: Double?
    let maxWidth: CGFloat

    static let font = NSFont.systemFont(ofSize: 15)
    static let barWidth: CGFloat = 2.5, barSpacing: CGFloat = 1.5, ribbonHeight: CGFloat = 15, ribbonGap: CGFloat = 3
    static let wordSpacing: CGFloat = 8, lineSpacing: CGFloat = 5
    /// A pause adds up to `maxSilence` points of gap at `silenceScale` points per second.
    static let silenceScale: CGFloat = 40, maxSilence: CGFloat = 30
    static let textHeight: CGFloat = ceil(NSAttributedString(string: "Ag", attributes: [.font: font]).size().height)
    private static let pulsePeriod = 1.1

    var body: some View {
        let widths = cells.map { Self.width(of: $0.text) }
        // The shimmer masks a second copy of the ribbon, so both get the same fixed width and wrap alike.
        let sized = ribbon(widths: widths).frame(width: naturalWidth(widths: widths), alignment: .leading)
        sized
            .overlay {
                if polishing { ShimmerBand(animated: animated, phase: shimmerPhase).mask(sized).allowsHitTesting(false) }
            }
            .animation(animated ? .spring(response: 0.32, dampingFraction: 0.78) : nil, value: cells)
            .animation(animated ? .easeInOut(duration: 0.2) : nil, value: truncated)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text((truncated ? "… " : "") + cells.map(\.text).joined(separator: " ")))
            .accessibilityAddTraits(.updatesFrequently)
    }

    @ViewBuilder private func ribbon(widths: [CGFloat]) -> some View {
        let layout = WordFlowLayout(spacing: Self.wordSpacing, lineSpacing: Self.lineSpacing)
        layout {
            if truncated {
                Text("…").font(Font(Self.font)).foregroundStyle(Color.primary)
                    .frame(height: Self.textHeight)
                    .padding(.top, Self.ribbonHeight + Self.ribbonGap)
                    .transition(.opacity)
            }
            ForEach(Array(cells.enumerated()), id: \.element.id) { i, cell in
                if cell.gapBefore >= WordWaveform.silenceThreshold {
                    SilenceGapView(seconds: cell.gapBefore, contrast: contrast)
                        .layoutValue(key: IsGapKey.self, value: true)
                        .transition(.opacity)
                }
                WordCellView(cell: cell, width: widths[i], bars: bars(for: cell, width: widths[i]),
                             current: !polishing && i == cells.indices.last, revised: revised.contains(cell.id),
                             animated: animated, contrast: contrast, pulsePhase: pulsePhase)
                    .transition(.asymmetric(insertion: .scale(scale: 0.6, anchor: .bottom).combined(with: .opacity),
                                            removal: .opacity))
            }
        }
    }

    static func width(of word: String) -> CGFloat {
        ceil(NSAttributedString(string: word, attributes: [.font: font]).size().width) + 1
    }

    static func gapWidth(seconds: Double) -> CGFloat { min(maxSilence, CGFloat(seconds) * silenceScale) }

    /// The bars across a word: as many as fit its text width at the HUD's bar pitch.
    static func barCount(width: CGFloat) -> Int { max(2, Int(((width + barSpacing) / (barWidth + barSpacing)).rounded(.down))) }

    private func bars(for cell: WordCell, width: CGFloat) -> [Float] {
        levels.bars(from: cell.start, to: cell.end, count: Self.barCount(width: width))
    }

    /// One line's worth when it fits, else the maximum so the layout wraps.
    private func naturalWidth(widths: [CGFloat]) -> CGFloat {
        var total: CGFloat = truncated ? Self.width(of: "…") + Self.wordSpacing : 0
        for (i, cell) in cells.enumerated() {
            if i > 0 { total += Self.wordSpacing }
            if cell.gapBefore >= WordWaveform.silenceThreshold { total += Self.gapWidth(seconds: cell.gapBefore) + Self.wordSpacing }
            total += widths[i]
        }
        return min(maxWidth, max(total, 24))
    }
}

/// A word and the bars of its audio: unstable words are tinted, the current one pulses, stable ones settle.
private struct WordCellView: View {
    let cell: WordCell
    let width: CGFloat
    let bars: [Float]
    let current: Bool
    let revised: Bool
    let animated: Bool
    let contrast: Bool
    var pulsePhase: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: WordWaveformView.ribbonGap) {
            if current, animated, pulsePhase == nil {
                TimelineView(.animation) { context in
                    ribbon(pulse: Self.pulse(at: context.date.timeIntervalSinceReferenceDate))
                }
            } else {
                ribbon(pulse: current && animated ? Self.pulse(phase: pulsePhase ?? 0.25) : 1)
            }
            Text(cell.text)
                .font(Font(WordWaveformView.font))
                .lineLimit(1)
                .foregroundStyle(revised ? HUDColors.change : cell.stable ? Color.primary : Color.primary.opacity(contrast ? 0.72 : 0.55))
                .frame(width: width, height: WordWaveformView.textHeight, alignment: .leading)
                .id(cell.text)
                .transition(.opacity)
        }
        .frame(width: width)
    }

    private static func pulse(at seconds: TimeInterval) -> Double {
        pulse(phase: seconds.truncatingRemainder(dividingBy: 1.1) / 1.1)
    }
    /// 0.72…1 on a gentle sine, so the current word breathes rather than blinks.
    private static func pulse(phase: Double) -> Double { 0.86 + 0.14 * sin(phase * 2 * .pi) }

    private func ribbon(pulse: Double) -> some View {
        // Every bar is koi: settled words at half strength, the words still being recognised at full strength, the current one breathing.
        let tint: Color = cell.stable ? HUDColors.action.opacity(contrast ? 0.85 : 0.55) : HUDColors.action.opacity(current ? pulse : 0.85)
        return HStack(alignment: .bottom, spacing: WordWaveformView.barSpacing) {
            ForEach(bars.indices, id: \.self) { i in
                Capsule()
                    .fill(tint)
                    .frame(width: WordWaveformView.barWidth,
                           height: 2.5 + (WordWaveformView.ribbonHeight - 2.5) * CGFloat(bars[i]) * (current ? CGFloat(0.9 + 0.1 * pulse) : 1))
            }
        }
        .frame(width: width, height: WordWaveformView.ribbonHeight, alignment: .bottomLeading)
        .shadow(color: current ? Color.chirp.koiDecor.opacity(0.35 * pulse) : .clear, radius: current ? 3 : 0)
        .animation(animated ? .spring(response: 0.22, dampingFraction: 0.7) : nil, value: bars)
        .animation(animated ? .easeInOut(duration: 0.35) : nil, value: cell.stable)
    }
}

/// A pause between words: a faint dotted rest in the ribbon row, as wide as the silence (capped).
private struct SilenceGapView: View {
    let seconds: Double
    let contrast: Bool

    var body: some View {
        let width = WordWaveformView.gapWidth(seconds: seconds)
        VStack(spacing: WordWaveformView.ribbonGap) {
            HStack(spacing: 3) {
                ForEach(0..<max(1, Int(width / 5)), id: \.self) { _ in
                    Circle().fill(Color.primary.opacity(contrast ? 0.45 : 0.28)).frame(width: 2, height: 2)
                }
            }
            .frame(width: width, height: WordWaveformView.ribbonHeight, alignment: .bottom)
            .padding(.bottom, 0.5)
            Color.clear.frame(width: width, height: WordWaveformView.textHeight)
        }
    }
}

/// Marks a layout item as a pause: it is dropped when it would start a line.
struct IsGapKey: LayoutValueKey { static let defaultValue = false }

/// Lays the word cells out left to right and wraps them like text, bottom-aligned per line. Pause items are skipped at
/// the start of a line, where there is nothing to space from.
struct WordFlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(width: bounds.width, subviews: subviews).frames
        for (i, subview) in subviews.enumerated() {
            guard let frame = frames[i] else { subview.place(at: CGPoint(x: -10_000, y: -10_000), proposal: .zero); continue }
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [CGRect?], size: CGSize) {
        var frames = [CGRect?](repeating: nil, count: subviews.count)
        var line: [(index: Int, size: CGSize)] = []
        var y: CGFloat = 0, widest: CGFloat = 0
        func flush() {
            guard !line.isEmpty else { return }
            let height = line.map(\.size.height).max() ?? 0
            var x: CGFloat = 0
            for (i, item) in line.enumerated() {
                if i > 0 { x += spacing }
                frames[item.index] = CGRect(x: x, y: y + height - item.size.height, width: item.size.width, height: item.size.height)
                x += item.size.width
            }
            widest = max(widest, x)
            y += height + lineSpacing
            line.removeAll()
        }
        for (i, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let isGap = subview[IsGapKey.self]
            let used = line.reduce(CGFloat(0)) { $0 + $1.size.width } + CGFloat(max(0, line.count - 1)) * spacing
            if !line.isEmpty, used + spacing + size.width > width + 0.5 { flush() }
            if isGap, line.isEmpty { continue }
            line.append((i, size))
        }
        flush()
        // Report the proposed width when there is one, so placement wraps exactly as the measurement did.
        return (frames, CGSize(width: width.isFinite ? width : widest, height: max(0, y - lineSpacing)))
    }
}

/// The soft highlight band that sweeps across the polishing transcript (shared by the plain and the word waveform).
struct ShimmerBand: View {
    let animated: Bool
    var phase: Double?
    private static let period = 1.5

    var body: some View {
        if animated, phase == nil {
            TimelineView(.animation) { context in
                band(at: context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period) / Self.period)
            }
        } else if animated {
            band(at: phase ?? 0)
        }
    }

    private func band(at position: Double) -> some View {
        GeometryReader { geo in
            let band = max(40, geo.size.width * 0.28)
            let x = -band + (geo.size.width + 2 * band) * position
            LinearGradient(colors: [.clear, HUDColors.shimmer, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: band)
                .offset(x: x)
        }
    }
}
