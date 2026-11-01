import AppKit
import SwiftUI

/// Renders the panel content to PNG with ImageRenderer so the layout can be eyeballed without a notched display
/// or Screen Recording permission. Backdrop imitates a wallpaper with a menu bar strip.
@MainActor
enum Snapshots {
    static func run(into dir: String) -> Bool {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var ok = true
        let base = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                 visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 880), safeAreaTop: 0, auxLeft: nil, auxRight: nil)
        for (label, sim) in [("notch14", SimNotch.mbp14), ("floating", SimNotch.off)] {
            for st in IslandState.allCases {
                let model = SpikeModel()
                model.sim = sim; model.state = st; model.elapsed = 7
                model.layout = NotchGeometry.layout(sim == .off ? base : ScreenMetrics.fake(sim, on: base))
                let view = ZStack(alignment: .top) {
                    LinearGradient(colors: [.indigo, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Rectangle().fill(.gray.opacity(0.35)).frame(height: 32).frame(maxHeight: .infinity, alignment: .top)
                    PanelContent(model: model)
                }.frame(width: NotchGeometry.panelSize.width, height: NotchGeometry.panelSize.height)
                let r = ImageRenderer(content: view)
                r.scale = 2
                guard let cg = r.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { say("render failed \(label)-\(st)"); ok = false; continue }
                let path = "\(dir)/\(label)-\(st.rawValue).png"
                do { try png.write(to: URL(fileURLWithPath: path)); say("wrote \(path)") } catch { say("write failed: \(error)"); ok = false }
            }
        }
        return ok
    }
}
