import SwiftUI

/// Content of the fixed-size panel. Island is top-centre; in simulated mode a dashed cutout stands in for the notch.
struct PanelContent: View {
    let model: SpikeModel
    var body: some View {
        let lay = model.layout
        ZStack(alignment: .top) {
            if model.sim != .off, let n = lay.notchRect, lay.mode == .notch {
                // Fake hardware cutout, drawn in panel-local coordinates (panel is centred on the notch).
                Rectangle()
                    .strokeBorder(Color.pink, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    .frame(width: n.width, height: n.height)
            }
            IslandView(model: model)
        }
        .frame(width: NotchGeometry.panelSize.width, height: NotchGeometry.panelSize.height, alignment: .top)
    }
}

struct IslandView: View {
    let model: SpikeModel
    // @Namespace is the "does it compile under CLT" question. It is a property wrapper on a View struct,
    // not @State, so test.sh's grep ban does not hit it.
    @Namespace private var ns

    var body: some View {
        let lay = model.layout
        let st = model.state
        let floating = lay.mode == .floating
        let barH = floating ? max(st.size.h, 40) : max(st.size.h, lay.notchHeight)
        let totalH = st == .polishing ? max(st.size.h, barH + 46) : barH
        let gap = floating ? 0 : lay.notchWidth
        let width = max(st.size.w, gap + 2 * 70)
        let tr: CGFloat = floating ? 0 : 8

        VStack(spacing: 0) {
            HStack(spacing: 0) {
                leading(st)
                Spacer(minLength: gap)
                trailing(st)
            }
            .frame(height: barH)
            .padding(.horizontal, tr + 14)
            if st == .polishing {
                polishingBody.frame(height: totalH - barH)
            }
        }
        .frame(width: width, height: totalH, alignment: .top)
        .background(
            Group {
                if floating {
                    RoundedRectangle(cornerRadius: st.size.r, style: .continuous).fill(.black)
                } else {
                    NotchShape(topRadius: tr, bottomRadius: st.size.r).fill(.black)
                }
            }
        )
        .padding(.top, floating ? NotchGeometry.floatingGap : 0)
        .opacity(model.panelVisible ? 1 : 0)
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: st)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Chirp \(st.rawValue)")
    }

    @ViewBuilder private func leading(_ st: IslandState) -> some View {
        HStack(spacing: 6) {
            dot(st).matchedGeometryEffect(id: "dot", in: ns)
            if st == .done { Text("Pasted").font(.system(size: 12, weight: .medium)).foregroundStyle(.white) }
        }
    }

    @ViewBuilder private func trailing(_ st: IslandState) -> some View {
        switch st {
        case .listening:
            Text(String(format: "%d:%02d", model.elapsed / 60, model.elapsed % 60))
                .font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.85))
        case .polishing:
            Text("Polishing").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.85))
        case .done:
            Text("\u{2303}\u{2325}Z Use raw").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
        }
    }

    private func dot(_ st: IslandState) -> some View {
        let c: Color = switch st { case .listening: .red; case .polishing: .orange; case .done: .green }
        return Circle().fill(c).frame(width: 12, height: 12)
    }

    private var polishingBody: some View {
        HStack {
            Text("so we agreed to ship on friday and uh keep the vendor contract")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            Spacer(minLength: 0)
        }.padding(.horizontal, 22)
    }
}
