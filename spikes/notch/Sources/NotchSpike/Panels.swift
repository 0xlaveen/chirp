import AppKit
import SwiftUI

/// The island panel: borderless, non-activating, never key. `constrainFrameRect` is overridden because AppKit
/// otherwise pushes windows out from under the menu bar, which is exactly the area we want to cover.
final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    var constrainCalls = 0
    var allowConstrain = false // flip with the menu to see what AppKit does by default
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        constrainCalls += 1
        return allowConstrain ? super.constrainFrameRect(frameRect, to: screen) : frameRect
    }
}

@MainActor
func makePanel(size: CGSize, content: some View) -> IslandPanel {
    let p = IslandPanel(contentRect: CGRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = false
    p.isReleasedWhenClosed = false
    p.hidesOnDeactivate = false
    p.becomesKeyOnlyIfNeeded = true
    p.isMovable = false
    p.animationBehavior = .none
    let host = NSHostingView(rootView: content)
    host.sizingOptions = [] // keep the panel fixed-size; do not let SwiftUI resize the window
    host.frame = CGRect(origin: .zero, size: size)
    p.contentView = host
    return p
}
