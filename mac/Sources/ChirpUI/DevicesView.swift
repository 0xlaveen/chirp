import AppKit
import ChirpCore

/// What Settings → Devices says about its list, in words (kept apart from the AppKit rows so tests can read it).
public enum DevicesText {
    public static func detail(_ d: PairedDevice, now: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, calendar: .current, timeZone: timeZone)
        return "Paired \(d.created.formatted(style)) · \(lastSeen(d.lastSeen, now: now, locale: locale))"
    }

    public static func lastSeen(_ date: Date?, now: Date, locale: Locale = .current) -> String {
        guard let date else { return "not used yet" }
        // The server records a device at most once a minute.
        if now.timeIntervalSince(date) < 90 { return "seen just now" }
        let f = RelativeDateTimeFormatter()
        f.locale = locale
        f.unitsStyle = .abbreviated
        return "seen \(f.localizedString(for: date, relativeTo: now))"
    }

    public static let empty = "No phones paired with their own token yet."
    public static let loading = "Loading…"
    public static let sharedNote = "Phones paired with the shared token don’t show here and keep working until you rotate it."
    public static let rotateHelp = "Replaces the shared token. Every phone paired with it must pair again; phones in the list are not affected."

    public static func revokeTitle(_ d: PairedDevice) -> String { "Revoke “\(d.name)”?" }
    public static let revokeDetail = "It stops working right away and has to be paired again to reconnect. Other phones are not affected."
}

/// Settings → Devices: the phones paired with their own token (name, when paired, last seen) and a Revoke button for
/// each. The owner supplies the data through `apply` and handles `onRevoke` (which asks first).
@MainActor
public final class DevicesView: NSStackView {
    public var onRevoke: ((PairedDevice) -> Void)?
    /// The list grew or shrank: the window should resize.
    public var onResize: (() -> Void)?
    private var shown: [PairedDevice] = []

    public init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        widthAnchor.constraint(equalToConstant: SettingsForm.controlWidth).isActive = true
        apply(.loading, revoking: nil, problem: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    public var devices: [PairedDevice] { shown }

    public func apply(_ phase: DevicesPhase, revoking: String?, problem: String?, now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current) {
        for v in arrangedSubviews { removeArrangedSubview(v); v.removeFromSuperview() }
        shown = []
        switch phase {
        case .loading: addNote(DevicesText.loading)
        case .remote(let host): addNote("Chirp uses the server on \(host). Manage its devices on that machine with chirp-server devices.")
        case .unavailable(let why): addNote(why, tone: .warning)
        case .loaded(let devices):
            shown = devices
            if devices.isEmpty { addNote(DevicesText.empty) }
            for d in devices { addRow(d, busy: revoking == d.id, enabled: revoking == nil, now: now, locale: locale, timeZone: timeZone) }
        }
        if let problem { addNote(problem, tone: .error) }
        onResize?()
    }

    private func addNote(_ text: String, tone: MenuEntry.Tone = .normal) {
        let f = SettingsForm.help(text)
        if tone == .error { f.textColor = .systemRed }
        if tone == .warning { f.textColor = .systemOrange }
        addArrangedSubview(f)
    }

    private func addRow(_ d: PairedDevice, busy: Bool, enabled: Bool, now: Date, locale: Locale, timeZone: TimeZone) {
        let name = NSTextField(labelWithString: d.name)
        name.font = MenuStyle.semiboldFont
        name.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: DevicesText.detail(d, now: now, locale: locale, timeZone: timeZone))
        detail.font = MenuStyle.secondaryFont
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [name, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let revoke = RevokeButton(title: busy ? "Revoking…" : "Revoke…", device: d) { [weak self] in self?.onRevoke?(d) }
        revoke.isEnabled = enabled
        revoke.setAccessibilityLabel("Revoke \(d.name)")
        let row = NSStackView(views: [text, NSView(), revoke])
        row.orientation = .horizontal
        row.alignment = .centerY
        addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
}

@MainActor
private final class RevokeButton: NSButton {
    let device: PairedDevice
    private let handler: () -> Void

    init(title: String, device: PairedDevice, handler: @escaping () -> Void) {
        self.device = device
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
