import AppKit
import ChirpUI

/// The About window: app icon, name and version.
@MainActor
final class AboutWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let view = AboutView(icon: NSApp.applicationIconImage, info: AboutInfo(infoDictionary: Bundle.main.infoDictionary),
                                 onNotices: { Self.openNotices() })
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

    /// The notices shipped in the app bundle (`bundle.sh` copies them); the repository copy for a bare `swift run`.
    private static func openNotices() {
        let url = Bundle.main.url(forResource: "NOTICES", withExtension: "md", subdirectory: "ThirdParty")
            ?? URL(string: "https://github.com/araa47/chirp/blob/main/mac/Assets/ThirdParty/NOTICES.md")!
        NSWorkspace.shared.open(url)
    }
}
