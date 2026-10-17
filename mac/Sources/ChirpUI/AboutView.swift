import AppKit

/// What the About window says about the build, from the bundle's Info.plist (nil keys mean a bare `swift run`).
public struct AboutInfo: Equatable, Sendable {
    public var version: String?
    public var build: String?

    public init(version: String? = nil, build: String? = nil) {
        self.version = version
        self.build = build
    }

    public init(infoDictionary: [String: Any]?) {
        self.init(version: infoDictionary?["CFBundleShortVersionString"] as? String,
                  build: infoDictionary?["CFBundleVersion"] as? String)
    }

    /// "Version 0.1.0 (1)", "Version 0.1.0" when the build adds nothing, "Development build" outside the app bundle.
    public var line: String {
        guard let version, !version.isEmpty else { return "Development build" }
        guard let build, !build.isEmpty, build != version else { return "Version \(version)" }
        return "Version \(version) (\(build))"
    }
}

/// The About window's content: the app icon, the name, the version and one line on what Chirp does.
@MainActor
public final class AboutView: NSView {
    static let width: CGFloat = 320

    public init(icon: NSImage?, info: AboutInfo) {
        super.init(frame: .zero)
        let iconView = NSImageView(image: icon ?? NSImage())
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setAccessibilityLabel("Chirp app icon")
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 96), iconView.heightAnchor.constraint(equalToConstant: 96),
        ])

        let name = NSTextField(labelWithString: "Chirp")
        name.font = .systemFont(ofSize: 22, weight: .semibold)
        let version = NSTextField(labelWithString: info.line)
        version.font = MenuStyle.secondaryFont
        version.textColor = .secondaryLabelColor
        version.setAccessibilityIdentifier("about-version")
        let blurb = NSTextField(wrappingLabelWithString: "Dictate into any app with a hotkey. Speech is recognised by your own chirp-server; audio never leaves your Mac.")
        blurb.font = MenuStyle.secondaryFont
        blurb.textColor = .secondaryLabelColor
        blurb.alignment = .center
        blurb.preferredMaxLayoutWidth = Self.width - 72

        let stack = NSStackView(views: [iconView, name, version, blurb])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.setCustomSpacing(10, after: iconView)
        stack.setCustomSpacing(14, after: version)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 28),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: 26),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }
}
