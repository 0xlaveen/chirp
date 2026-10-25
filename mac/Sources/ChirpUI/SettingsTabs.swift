import AppKit

/// The preferences window's content controller: the sidebar-and-page shell at its fixed size. The window takes the selected
/// page's title (hidden, but VoiceOver and Mission Control read it).
@MainActor
public final class SettingsShellController: NSViewController {
    public let shell: SettingsShell
    /// A page came on screen (the user chose it, or the window opened on it).
    public var onAppear: ((SettingsTab) -> Void)?

    public init(form: SettingsForm, selected: SettingsTab = .general) {
        shell = SettingsShell(form: form, selected: selected)
        super.init(nibName: nil, bundle: nil)
        title = "Chirp Settings"
        shell.onSelect = { [weak self] tab in
            self?.view.window?.title = "Chirp Settings — \(tab.title)"
            self?.onAppear?(tab)
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    override public func loadView() {
        view = shell
        preferredContentSize = SettingsShell.size
    }

    override public func viewDidAppear() {
        super.viewDidAppear()
        view.window?.title = "Chirp Settings — \(shell.selected.title)"
        onAppear?(shell.selected)
    }
}

@MainActor
public enum SettingsTabs {
    public static func makeController(form: SettingsForm, onAppear: ((SettingsTab) -> Void)? = nil) -> SettingsShellController {
        let controller = SettingsShellController(form: form)
        controller.onAppear = onAppear
        return controller
    }
}
