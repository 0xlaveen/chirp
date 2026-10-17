import AppKit
import ChirpUI

/// The About window: app icon, name and version.
@MainActor
final class AboutWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let view = AboutView(icon: NSApp.applicationIconImage, info: AboutInfo(infoDictionary: Bundle.main.infoDictionary))
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "About Chirp"
            w.isReleasedWhenClosed = false
            w.contentView = view
            w.setContentSize(view.fittingSize)
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
