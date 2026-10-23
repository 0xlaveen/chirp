import AppKit
import ChirpCore

/// What Settings › Notes shows about saved voices (issue #18 M3).
public struct VoiceProfilesState: Equatable, Sendable {
    public var enabled = false
    public var model: SpeakerModelState = .notDownloaded
    public var profiles: [VoiceProfile] = []
    /// The embedding model profiles must come from (others are listed as needing to be saved again).
    public var modelID = ""

    public init() {}
}

/// Settings › Notes, in words (kept apart from the AppKit rows so tests can read it).
public enum VoiceProfilesText {
    public static let toggle = "Recognize saved voices"
    public static let explainer = "Chirp can remember what a person's voice sounds like as a numeric voiceprint, stored only in this Mac's Keychain. Voiceprints are biometric data: only save people who agreed. They never leave this Mac."
    public static let empty = "No saved voices yet: name a speaker in Live Notes, then Remember This Voice."
    public static let forgetAll = "Forget All Voices…"
    public static func downloadPrompt(size: String) -> String {
        "Recognizing saved voices needs a \(size) on-device model, downloaded once. Audio and voiceprints never leave this Mac."
    }
    public static func redownloadPrompt(size: String) -> String {
        "The voice model on this Mac did not load. Remove it and download it again (\(size))? Audio and voiceprints never leave this Mac."
    }
    public static func turnOffTitle(_ n: Int) -> String { n == 1 ? "Also forget 1 saved voice?" : "Also forget \(n) saved voices?" }
    public static let turnOffDetail = "Kept voices stay in this Mac's Keychain, unused, until you turn this on again or forget them."
    public static func forgetTitle(_ p: VoiceProfile) -> String { "Forget “\(p.name)”'s voice?" }
    public static let forgetAllTitle = "Forget all saved voices?"
    public static let forgetDetail = "The voiceprint is deleted from this Mac's Keychain. Chirp will no longer suggest this name."

    public static func detail(_ p: VoiceProfile, compatible: Bool, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, calendar: .current, timeZone: timeZone)
        let saved = "Saved \(p.created.formatted(style)) · \(Int(p.seconds.rounded())) s of speech"
        return compatible ? saved : saved + " · from an older model: forget it and remember the voice again"
    }

    public static func status(_ s: VoiceProfilesState) -> String {
        switch s.model {
        case .downloading(let f): "Downloading voice model… \(Int((f * 100).rounded()))%"
        case .loading: "Loading voice model…"
        case .failed(let why): "Voice model unavailable: \(why)"
        case .ready, .notDownloaded:
            s.enabled ? "On: Live Notes suggests a saved name for a voice it recognizes" : "Off"
        }
    }
}

/// Settings › Notes › Voices: the switch, what it means, and each saved voice with Forget. The owner supplies the data
/// through `apply` and handles the callbacks (which ask first).
@MainActor
public final class VoiceProfilesView: NSStackView {
    public let toggle = NSButton(checkboxWithTitle: VoiceProfilesText.toggle, target: nil, action: nil)
    public var onToggle: ((Bool) -> Void)?
    public var onForget: ((VoiceProfile) -> Void)?
    public var onForgetAll: (() -> Void)?
    public var onResize: (() -> Void)?
    private let list = NSStackView()
    private let status = SettingsForm.help("")
    private let forgetAll = NSButton(title: VoiceProfilesText.forgetAll, target: nil, action: nil)
    public private(set) var shown: [VoiceProfile] = []

    public init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 4
        widthAnchor.constraint(equalToConstant: SettingsForm.controlWidth).isActive = true
        toggle.target = self
        toggle.action = #selector(toggled)
        forgetAll.bezelStyle = .rounded
        forgetAll.controlSize = .small
        forgetAll.target = self
        forgetAll.action = #selector(forgetAllPressed)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 8
        for v in [toggle, SettingsForm.help(VoiceProfilesText.explainer), status, list, forgetAll] as [NSView] { addArrangedSubview(v) }
        list.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        apply(VoiceProfilesState())
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    public func apply(_ s: VoiceProfilesState, locale: Locale = .current, timeZone: TimeZone = .current) {
        toggle.state = s.enabled || s.model.isDownloading ? .on : .off
        status.stringValue = VoiceProfilesText.status(s)
        status.textColor = s.model.isFailure ? .systemOrange : .secondaryLabelColor
        // Only a download, a load or a failure needs a line of its own; on and off are the checkbox.
        status.isHidden = s.model == .ready || s.model == .notDownloaded
        let changed = shown != s.profiles
        shown = s.profiles
        for v in list.arrangedSubviews { list.removeArrangedSubview(v); v.removeFromSuperview() }
        if s.profiles.isEmpty, s.enabled { list.addArrangedSubview(SettingsForm.help(VoiceProfilesText.empty)) }
        list.isHidden = list.arrangedSubviews.isEmpty
        for p in s.profiles { addRow(p, compatible: p.model == s.modelID, locale: locale, timeZone: timeZone) }
        forgetAll.isHidden = s.profiles.isEmpty
        if changed { onResize?() }
    }

    private func addRow(_ p: VoiceProfile, compatible: Bool, locale: Locale, timeZone: TimeZone) {
        let name = NSTextField(labelWithString: p.name)
        name.font = MenuStyle.semiboldFont
        name.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: VoiceProfilesText.detail(p, compatible: compatible, locale: locale, timeZone: timeZone))
        detail.font = MenuStyle.secondaryFont
        detail.textColor = compatible ? .secondaryLabelColor : .systemOrange
        detail.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [name, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let forget = ProfileButton(title: "Forget…") { [weak self] in self?.onForget?(p) }
        forget.setAccessibilityLabel("Forget \(p.name)'s voice")
        let row = NSStackView(views: [text, NSView(), forget])
        row.orientation = .horizontal
        row.alignment = .centerY
        list.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
    }

    @objc private func toggled() { onToggle?(toggle.state == .on) }
    @objc private func forgetAllPressed() { onForgetAll?() }
}

@MainActor
private final class ProfileButton: NSButton {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        controlSize = .small
        target = self
        action = #selector(pressed)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func pressed() { handler() }
}
