import AppKit

/// One tab of the preferences window: the form's content for `tab`, sized to fit. On a screen too short for it (the
/// Clean-up tab holds the prompt editor) the content scrolls and the tab is as tall as the screen allows.
@MainActor
public final class SettingsTabController: NSViewController {
    public let tab: SettingsTab
    private let form: SettingsForm

    public init(tab: SettingsTab, form: SettingsForm) {
        self.tab = tab
        self.form = form
        super.init(nibName: nil, bundle: nil)
        title = tab.title
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    /// The tallest a tab may be on this screen: the window also holds a title bar and the toolbar.
    static func heightLimit(screen: NSScreen? = nil) -> CGFloat {
        let visible = (screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        return max(420, visible - 140)
    }

    override public func loadView() {
        let content = form.view(for: tab)
        let size = form.fittingSize(for: tab)
        if size.height > Self.heightLimit() {
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.drawsBackground = false
            content.setFrameSize(size)
            content.translatesAutoresizingMaskIntoConstraints = true
            scroll.documentView = content
            view = scroll
            preferredContentSize = NSSize(width: size.width + 16, height: Self.heightLimit())
        } else {
            view = content
            preferredContentSize = size
        }
    }

    /// The content changed height (the Custom sound rows appeared): measure it again.
    public func refreshSize() {
        guard isViewLoaded else { return }
        let size = form.fittingSize(for: tab)
        if view is NSScrollView {
            form.view(for: tab).setFrameSize(size)
            preferredContentSize = NSSize(width: size.width + 16, height: min(size.height, Self.heightLimit()))
        } else {
            preferredContentSize = size
        }
    }
}

/// The preferences window's contents: the five tabs as toolbar buttons, like System Settings' older panes. The
/// window takes the selected tab's title and size.
@MainActor
public enum SettingsTabs {
    public static func makeController(form: SettingsForm) -> NSTabViewController {
        let controller = NSTabViewController()
        controller.tabStyle = .toolbar
        controller.transitionOptions = []
        for tab in SettingsTab.allCases {
            let item = NSTabViewItem(viewController: SettingsTabController(tab: tab, form: form))
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            item.toolTip = tab.title
            controller.addTabViewItem(item)
        }
        return controller
    }
}
