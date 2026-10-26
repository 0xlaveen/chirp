import ChirpIOSCore
import SwiftUI

// The Settings rows (#194), a port of Android's `ui/ChirpComponents.kt`: rows in one rounded
// `surface` container with 2 pt gaps (the Android 16 / Gboard settings layout), each showing one
// line plus an optional one-line summary, with the paragraph behind an ⓘ InfoSheet. Rows are at least
// 44 pt (56 with a summary) and grow with Dynamic Type.

/// A group's rows: an optional header above one rounded container with 2 pt gaps between the rows.
struct SettingsGroup<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: ChirpSpacing.s8) {
            if let title {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.chirp.koi)
                    .padding(.leading, ChirpSpacing.s8).accessibilityAddTraits(.isHeader)
            }
            VStack(spacing: 2) { content }
                .clipShape(RoundedRectangle(cornerRadius: ChirpRadius.panel, style: .continuous))
        }.fixedSize(horizontal: false, vertical: true)
    }
}

extension SettingsGroup where Content == EmptyView {
    init(title: String? = nil) { self.init(title: title, content: { }) }
}

/// Free-form content (chips, pickers, banners) on its own row container, inside a `SettingsGroup`.
struct SettingsItem<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: ChirpSpacing.s8) { content }
            .padding(.horizontal, ChirpSpacing.s16).padding(.vertical, ChirpSpacing.s12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.chirp.surface, in: RoundedRectangle(cornerRadius: ChirpRadius.row, style: .continuous))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The paragraph behind a row, as an ⓘ that opens an `InfoSheet` labelled "About <row>".
private struct RowInfo: View {
    let title: String
    let text: String
    var body: some View {
        LearnMore(title: title) { Text(text) }
    }
}

/// Title plus an optional one-line summary (wrapping at accessibility sizes), and an optional leading SF Symbol.
struct RowText: View {
    let title: String
    var summary: String?
    var symbol: String?
    var color: Color = Color.chirp.ink
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ChirpSpacing.s12) {
            if let symbol {
                Image(systemName: symbol).symbolRenderingMode(.hierarchical)
                    .font(.body).foregroundStyle(color)
                    .frame(width: 28, alignment: .center).accessibilityHidden(true)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).foregroundStyle(color)
                if let summary {
                    Text(summary).font(.footnote).foregroundStyle(Color.chirp.inkMuted)
                }
            }.fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The row container: a tile, at least 44 pt (56 with a summary), growing with Dynamic Type.
struct RowTile<Content: View>: View {
    var hasSummary: Bool
    var fill: Color = Color.chirp.surface
    @ViewBuilder var content: Content
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ChirpSpacing.s8) { content }
            .padding(.horizontal, ChirpSpacing.s16).padding(.vertical, ChirpSpacing.s8)
            .frame(minHeight: hasSummary ? 56 : 44, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: ChirpRadius.row, style: .continuous))
    }
}

/// The whole row toggles. `set` runs the page's save or consent path; the binding keeps the true state,
/// so a consent dialog that is cancelled leaves the switch where it was.
struct SwitchRow: View {
    let title: String
    /// The true state; writes go through `set`, so a consent dialog can still decline.
    var isOn: Bool
    var summary: String?
    var symbol: String?
    var infoTitle: String?
    var infoBody: String?
    var identifier: String?
    var disabled = false
    var set: (Bool) -> Void
    var body: some View {
        RowTile(hasSummary: summary != nil) {
            RowText(title: title, summary: summary, symbol: symbol)
            Spacer(minLength: 0)
            if let infoTitle, let infoBody { RowInfo(title: infoTitle, text: infoBody) }
            Toggle("", isOn: Binding(get: { isOn }, set: set))
                .labelsHidden().tint(Color.chirp.koi).fixedSize().disabled(disabled)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
                .accessibilityLabel([title, summary].compactMap { $0 }.joined(separator: ", "))
                .accessibilityIdentifier(identifier ?? "")
        }
        .opacity(disabled ? 0.55 : 1)
        .contentShape(RoundedRectangle(cornerRadius: ChirpRadius.row, style: .continuous))
        .onTapGesture { if !disabled { set(!isOn) } }
    }
}

/// Opens a pushed page, dialog or app: trailing chevron.
struct NavRow<Destination: View>: View {
    let title: String
    var summary: String?
    var symbol: String?
    var identifier: String?
    @ViewBuilder var destination: Destination
    var body: some View {
        NavigationLink {
            destination
        } label: {
            RowTile(hasSummary: summary != nil) {
                RowText(title: title, summary: summary, symbol: symbol)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.chirp.inkMuted).accessibilityHidden(true)
            }
        }
        .buttonStyle(.rowPress)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier ?? "")
    }
}

/// Does something in place. Destructive actions use the `record` colour.
struct ActionRow: View {
    let title: String
    var summary: String?
    var symbol: String?
    var destructive = false
    var disabled = false
    var identifier: String?
    var action: () -> Void
    var body: some View {
        Button(role: destructive ? .destructive : nil, action: action) {
            RowTile(hasSummary: summary != nil) {
                RowText(title: title, summary: summary, symbol: symbol,
                        color: destructive ? Color.chirp.record : Color.chirp.ink)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.rowPress)
        .opacity(disabled ? 0.45 : 1)
        .disabled(disabled)
        .accessibilityIdentifier(identifier ?? "")
    }
}

/// Rows press like tiles: a quick dim, never a tint flood.
struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.65 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == RowPressStyle { static var rowPress: RowPressStyle { .init() } }

/// Single-select chip row (Keep for, session length): koi container when selected, at least 44 pt tall.
/// Writes go through `selection`'s binding, so the caller's side effect lives there.
struct ChoiceChips<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String
    var body: some View {
        FlowLayout(spacing: ChirpSpacing.s8) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button { selection = option } label: {
                    Text(label(option)).font(.subheadline.weight(.medium))
                        .foregroundStyle(selected ? Color.chirp.onKoiContainer : Color.chirp.ink)
                        .padding(.horizontal, ChirpSpacing.s16).frame(minHeight: 44)
                        .background(selected ? Color.chirp.koiContainer : Color.chirp.surfaceRaised, in: Capsule())
                }.accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
    }
}

/// One line while it fits, then wrapped: as Android's FlowRow behaves for the settings chips.
struct FlowLayout<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content
    var body: some View { WrapLayout(spacing: spacing) { content } }
}

private struct WrapLayout: Layout {
    var spacing: CGFloat
    private func rows(_ subviews: Subviews, width: CGFloat) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = [], x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height); widest = max(widest, x - spacing)
        }
        return (frames, CGSize(width: widest, height: y + rowHeight))
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        rows(subviews, width: proposal.width ?? .infinity).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let laidOut = rows(subviews, width: bounds.width).frames
        for (view, frame) in zip(subviews, laidOut) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: .unspecified)
        }
    }
}
