import AppKit
import ChirpCore

public struct VoiceProfilesState: Equatable, Sendable {
    public var localServer = true
    public var supported = false
    public var enabled = false
    public var busy = false
    public var error: String?
    public var profiles: [SavedVoice] = []
    public init() {}
}

public enum VoiceProfilesText {
    public static let toggle = "Remember voices of people I name"
    public static func explainer(local: Bool) -> String {
        "Chirp recognises these people in new notes on all your devices. Saved voices stay on \(MacServerCopy.place(local: local)), never uploaded. Each Chirp server has its own library."
    }
    public static let empty = "Name a speaker in a note and Chirp will recognise them next time."
    public static func unsupported(local: Bool) -> String { MacServerCopy.update(local: local, to: "save voices") }
    public static let forgetAll = "Forget All Voices…"
    public static func turnOffTitle(_ n: Int) -> String { "Also forget \(n) saved \(n == 1 ? "voice" : "voices")?" }
    public static func turnOffDetail(local: Bool) -> String {
        "Kept voices stay on \(MacServerCopy.place(local: local)), unused, until you turn this on again or forget them."
    }
    public static func forgetTitle(_ p: SavedVoice) -> String { "Forget \(p.name)?" }
    public static let forgetAllTitle = "Forget all voices?"
    public static func forgetDetail(_ name: String?, local: Bool) -> String {
        "Removes \(name.map { $0 + "’s voice" } ?? "all saved voices") from \(MacServerCopy.place(local: local)) for every device. Names in existing notes stay. This can’t be undone."
    }
    public static func detail(_ p: SavedVoice, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, calendar: .current, timeZone: timeZone)
        let dates = "Saved \(p.created.formatted(style))" + (p.updated > p.created ? " · updated \(p.updated.formatted(style))" : "")
        return dates + " · \(Int(p.seconds.rounded())) s" + (p.compatible ? "" : " · name them again to keep")
    }
}

/// The server library's own screen. Callbacks keep destructive confirmations in the window controller.
@MainActor
public final class VoiceProfilesView: NSStackView {
    public let toggle = NSButton(checkboxWithTitle: VoiceProfilesText.toggle, target: nil, action: nil)
    public var onToggle: ((Bool) -> Void)?
    public var onRename: ((SavedVoice) -> Void)?
    public var onForget: ((SavedVoice) -> Void)?
    public var onForgetAll: (() -> Void)?
    public var onRefresh: (() -> Void)?
    public var onResize: (() -> Void)?
    private let list = NSStackView()
    private let status = SettingsForm.help("")
    private let explanation = SettingsForm.help("")
    private let forgetAll = NSButton(title: VoiceProfilesText.forgetAll, target: nil, action: nil)
    public private(set) var shown: [SavedVoice] = []

    public init() {
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 12
        widthAnchor.constraint(equalToConstant: SettingsForm.controlWidth).isActive = true
        let title = NSTextField(labelWithString: "Saved voices")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        toggle.target = self; toggle.action = #selector(toggled)
        forgetAll.bezelStyle = .rounded; forgetAll.controlSize = .small
        forgetAll.target = self; forgetAll.action = #selector(forgetAllPressed)
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshed))
        refresh.bezelStyle = .rounded; refresh.controlSize = .small
        let actions = NSStackView(views: [refresh, forgetAll])
        list.orientation = .vertical; list.alignment = .leading; list.spacing = 14
        for view in [title, toggle, explanation, status, list, actions] { addArrangedSubview(view) }
        list.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        apply(VoiceProfilesState())
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    public func apply(_ state: VoiceProfilesState, locale: Locale = .current, timeZone: TimeZone = .current) {
        explanation.stringValue = VoiceProfilesText.explainer(local: state.localServer)
        toggle.state = state.enabled ? .on : .off
        toggle.isEnabled = state.supported && !state.busy
        status.stringValue = !state.supported ? VoiceProfilesText.unsupported(local: state.localServer) : state.error ?? (state.busy ? "Updating saved voices…" : "")
        status.isHidden = status.stringValue.isEmpty
        status.textColor = state.error == nil ? .secondaryLabelColor : .systemOrange
        let changed = shown != state.profiles
        shown = state.profiles
        for view in list.arrangedSubviews { list.removeArrangedSubview(view); view.removeFromSuperview() }
        if state.profiles.isEmpty, state.supported { list.addArrangedSubview(SettingsForm.help(VoiceProfilesText.empty)) }
        for profile in state.profiles {
            let name = NSTextField(labelWithString: profile.name)
            name.font = MenuStyle.semiboldFont
            let detail = NSTextField(wrappingLabelWithString: VoiceProfilesText.detail(profile, locale: locale, timeZone: timeZone))
            detail.font = MenuStyle.secondaryFont
            detail.preferredMaxLayoutWidth = SettingsForm.controlWidth - 48
            detail.maximumNumberOfLines = 2
            detail.textColor = profile.compatible ? .secondaryLabelColor : .systemOrange
            let text = NSStackView(views: [name, detail])
            text.orientation = .vertical; text.alignment = .leading; text.spacing = 2
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let menu = ProfileMenu(rename: { [weak self] in self?.onRename?(profile) }, forget: { [weak self] in self?.onForget?(profile) })
            menu.isEnabled = !state.busy
            menu.setAccessibilityLabel("Manage \(profile.name)'s saved voice")
            let row = NSStackView(views: [text, menu])
            row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 12
            list.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                menu.widthAnchor.constraint(equalToConstant: 32),
                text.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -44),
                detail.widthAnchor.constraint(equalTo: text.widthAnchor)
            ])
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        forgetAll.isHidden = state.profiles.isEmpty
        forgetAll.isEnabled = state.supported && !state.busy
        if changed { onResize?() }
    }
    @objc private func toggled() { onToggle?(toggle.state == .on) }
    @objc private func forgetAllPressed() { onForgetAll?() }
    @objc private func refreshed() { onRefresh?() }
}

@MainActor
private final class ProfileMenu: NSButton {
    let rename: () -> Void
    let forget: () -> Void
    init(rename: @escaping () -> Void, forget: @escaping () -> Void) {
        self.rename = rename; self.forget = forget
        super.init(frame: .zero)
        title = "⋯"; bezelStyle = .rounded; controlSize = .small
        target = self; action = #selector(pressed)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }
    @objc private func pressed() {
        let menu = NSMenu()
        let rename = menu.addItem(withTitle: "Rename…", action: #selector(renamed), keyEquivalent: "")
        rename.target = self
        let forget = menu.addItem(withTitle: "Forget…", action: #selector(forgotten), keyEquivalent: "")
        forget.target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY), in: self)
    }
    @objc private func renamed() { rename() }
    @objc private func forgotten() { forget() }
}
