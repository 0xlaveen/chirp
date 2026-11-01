import SwiftUI

/// Diagnostics overlay, shown in its own click-through panel at the bottom-left of the target screen.
struct OverlayView: View {
    let model: SpikeModel
    var body: some View {
        Text(model.diagnostics + "\n" + model.focusReport)
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(.white)
            .padding(8)
            .frame(width: 760, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.78)))
    }
}
