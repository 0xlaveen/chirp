import UIKit
import ChirpIOSCore
import KeyboardPolicy

/// The 44 pt Chirp strip above the suggestion row: a state glyph, one short label, the DEBUG badge, the elapsed or
/// remaining time in tabular digits, the Style chip, the ⓘ button and the mic/Stop capsule at the trailing edge (where
/// Android's strip has its mic). One line in every state, so the keyboard never changes height.
@MainActor
final class KeyboardStatusStrip: UIView {
    let label = UILabel()
    let time = UILabel()
    let info = UIButton(type: .system)
    let style = UIButton(type: .system)
    /// Start / Stop / Polishing / Open Chirp: a filled capsule whose colour follows `PrimaryStyle`.
    let primary = UIButton(type: .system)
    private let glyphBox = UIView()
    private let ripple = KeyboardRippleView()
    private let symbol = UIImageView()
    private let dot = UIView()
    private let badge = UILabel()
    private var glyph: StripGlyph?
    private var primaryStyle: PrimaryStyle = .tonal { didSet { if primaryStyle != oldValue { primary.setNeedsUpdateConfiguration() } } }
    private var primaryWidth: NSLayoutConstraint!
    private var showsTitle = false
    private var showsRemaining = true

    init() {
        super.init(frame: .zero)
        configurePrimary()
        KeyboardChipRow.configure(style, title: "Default", symbol: nil, id: "style", label: "Style")
        style.configuration?.image = UIImage(systemName: "chevron.down")
        style.configuration?.imagePlacement = .trailing
        style.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)
        style.showsMenuAsPrimaryAction = true
        style.setContentHuggingPriority(.required, for: .horizontal)
        // The status label gives way first, then the Style chip's title truncates.
        style.setContentCompressionResistancePriority(.defaultHigh - 1, for: .horizontal)
        label.font = UIFontMetrics(forTextStyle: .subheadline)
            .scaledFont(for: .systemFont(ofSize: 15, weight: .medium), maximumPointSize: KeyboardMetrics.maxStripTextPoints)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = KeyboardPalette.ink
        label.lineBreakMode = .byTruncatingTail
        label.accessibilityIdentifier = "chirp.keyboard.status"
        label.accessibilityTraits.insert(.updatesFrequently)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        time.font = UIFontMetrics(forTextStyle: .subheadline)
            .scaledFont(for: .monospacedDigitSystemFont(ofSize: 14, weight: .regular), maximumPointSize: KeyboardMetrics.maxStripTextPoints)
        time.adjustsFontForContentSizeCategory = true
        time.textColor = KeyboardPalette.inkMuted
        time.textAlignment = .right
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        time.setContentHuggingPriority(.required, for: .horizontal)
        time.accessibilityIdentifier = "chirp.keyboard.time"

        badge.text = KeyboardPresenter.warningBadge
        badge.font = UIFontMetrics(forTextStyle: .caption2)
            .scaledFont(for: .systemFont(ofSize: 11, weight: .bold), maximumPointSize: KeyboardMetrics.maxChipTextPoints)
        badge.adjustsFontForContentSizeCategory = true
        badge.textColor = KeyboardPalette.record
        badge.textAlignment = .center
        badge.backgroundColor = KeyboardPalette.record.withAlphaComponent(0.16)
        badge.layer.cornerRadius = 9
        badge.layer.masksToBounds = true
        badge.isAccessibilityElement = false
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)

        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "info.circle")
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        configuration.baseForegroundColor = KeyboardPalette.inkMuted
        info.configuration = configuration
        info.accessibilityLabel = KeyboardPresenter.infoLabel
        info.accessibilityIdentifier = "chirp.keyboard.info"

        symbol.contentMode = .scaleAspectFit
        symbol.isHidden = true
        dot.layer.cornerRadius = 5
        dot.backgroundColor = KeyboardPalette.koi
        for view in [ripple, symbol, dot] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            glyphBox.addSubview(view)
            view.isAccessibilityElement = false
        }
        glyphBox.isAccessibilityElement = false
        NSLayoutConstraint.activate([
            ripple.leadingAnchor.constraint(equalTo: glyphBox.leadingAnchor), ripple.trailingAnchor.constraint(equalTo: glyphBox.trailingAnchor),
            ripple.topAnchor.constraint(equalTo: glyphBox.topAnchor), ripple.bottomAnchor.constraint(equalTo: glyphBox.bottomAnchor),
            symbol.centerXAnchor.constraint(equalTo: glyphBox.centerXAnchor), symbol.centerYAnchor.constraint(equalTo: glyphBox.centerYAnchor),
            symbol.widthAnchor.constraint(equalToConstant: 20), symbol.heightAnchor.constraint(equalToConstant: 20),
            dot.centerXAnchor.constraint(equalTo: glyphBox.centerXAnchor), dot.centerYAnchor.constraint(equalTo: glyphBox.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 10), dot.heightAnchor.constraint(equalToConstant: 10),
            glyphBox.widthAnchor.constraint(equalToConstant: 28), glyphBox.heightAnchor.constraint(equalToConstant: 28),
        ])

        let row = UIStackView(arrangedSubviews: [glyphBox, label, UIView(), badge, time, style, info, primary])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        row.setCustomSpacing(0, after: style)
        row.setCustomSpacing(0, after: info)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            badge.heightAnchor.constraint(equalToConstant: 18), badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 46),
            info.widthAnchor.constraint(equalToConstant: 44), info.heightAnchor.constraint(equalToConstant: 44),
            style.heightAnchor.constraint(equalToConstant: 44), primary.heightAnchor.constraint(equalToConstant: 44),
            primaryWidth,
        ])
        // The label takes the leftover width; the spacer only absorbs slack.
        row.arrangedSubviews[2].setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The capsule is 36 pt tall inside the 44 pt row (the whole row height stays tappable) and at least 56 pt wide;
    /// on iPhone it is the symbol alone, with the title for VoiceOver.
    private func configurePrimary() {
        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .capsule
        configuration.imagePadding = 6
        configuration.titleLineBreakMode = .byTruncatingTail
        configuration.background.backgroundInsets = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFontMetrics(forTextStyle: .headline)
                .scaledFont(for: .systemFont(ofSize: 16, weight: .semibold), maximumPointSize: KeyboardMetrics.maxPrimaryTextPoints)
            return attributes
        }
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        primary.configuration = configuration
        primary.accessibilityIdentifier = "chirp.keyboard.primary"
        primary.titleLabel?.adjustsFontForContentSizeCategory = true
        primary.setContentHuggingPriority(.required, for: .horizontal)
        primary.setContentCompressionResistancePriority(.required, for: .horizontal)
        primaryWidth = primary.widthAnchor.constraint(greaterThanOrEqualToConstant: KeyboardMetrics.minimumPrimaryWidth)
        // A disabled primary is a status (Polishing…, Full Access required), not a dimmed button: keep its own colours.
        primary.configurationUpdateHandler = { [weak self] button in
            guard let self, var configuration = button.configuration else { return }
            let (fill, ink) = self.primaryColors
            configuration.baseBackgroundColor = fill
            configuration.baseForegroundColor = ink
            button.configuration = configuration
        }
    }

    private var primaryColors: (UIColor, UIColor) {
        switch primaryStyle {
        case .koi: (KeyboardPalette.koi, KeyboardPalette.onKoi)
        case .record: (KeyboardPalette.record, KeyboardPalette.onRecord)
        case .moon: (KeyboardPalette.moonFill, KeyboardPalette.onMoonFill)
        case .tonal: (KeyboardPalette.koiContainer, KeyboardPalette.onKoiContainer)
        }
    }

    func apply(_ metrics: KeyboardMetrics) {
        showsTitle = metrics.showsPrimaryTitle
        showsRemaining = metrics.showsRemaining
    }

    func apply(_ screen: KeyboardScreen) {
        label.text = screen.phaseText
        // A narrow strip keeps the ticking elapsed time and leaves the session's remaining time to ⓘ.
        let trailing = screen.elapsed ?? (showsRemaining ? screen.remaining : nil)
        time.text = trailing
        time.isHidden = trailing == nil
        // The ticking elapsed time is never announced; the "left" text is a plain label for VoiceOver.
        time.isAccessibilityElement = screen.elapsed == nil && trailing != nil
        time.accessibilityLabel = screen.remaining
        badge.isHidden = screen.warning == nil
        info.isHidden = screen.detail == nil
        style.isHidden = !screen.showsStyle
        style.configuration?.title = screen.styleTitle
        style.accessibilityLabel = "Style: " + screen.styleTitle
        style.accessibilityHint = "Opens the style menu."
        let action = screen.primary
        primaryStyle = action.style
        primary.configuration?.title = showsTitle ? action.title : nil
        primary.configuration?.image = UIImage(systemName: action.symbol)
        primary.accessibilityLabel = action.accessibilityLabel
        primary.accessibilityHint = action.hint
        // Polishing is a status, not a dimmed button: it stays "enabled" so it keeps its moon fill, and VoiceOver
        // still reads it as dimmed. The controller ignores the tap.
        primary.isEnabled = action.isEnabled || action.kind == .polishing
        if action.kind == .polishing { primary.accessibilityTraits.insert(.notEnabled) } else { primary.accessibilityTraits.remove(.notEnabled) }
        setGlyph(screen.glyph)
    }

    private func setGlyph(_ next: StripGlyph) {
        guard next != glyph else { return }
        glyph = next
        ripple.setActive(next == .ripple)
        ripple.isHidden = next != .ripple
        dot.isHidden = next != .koiDot
        symbol.isHidden = next == .ripple || next == .koiDot
        switch next {
        case .moon:
            symbol.image = UIImage(systemName: "sparkle")?.applyingSymbolConfiguration(.init(pointSize: 16, weight: .bold))
            symbol.tintColor = KeyboardPalette.moon
        case .warning:
            symbol.image = UIImage(systemName: "exclamationmark.triangle.fill")?
                .applyingSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
            symbol.tintColor = KeyboardPalette.record
        case .idle:
            // The approved brand glyph from the asset catalog the extension ships (template-rendered).
            symbol.image = UIImage(named: "ChirpGlyph", in: .main, compatibleWith: nil)
            symbol.tintColor = KeyboardPalette.inkMuted
        case .ripple, .koiDot: break
        }
    }
}

/// The ⓘ overlay: the long guidance and End session, laid over the rows under the strip so the keys don't move. Its
/// label keeps the `chirp.keyboard.detail` identifier.
@MainActor
final class KeyboardInfoOverlay: UIView {
    let detail = UILabel()
    let close = UIButton(type: .system)
    /// Ends the keyboard session (the app's microphone turns off); shown while a session is live.
    let end = UIButton(type: .system)

    init() {
        super.init(frame: .zero)
        backgroundColor = KeyboardPalette.surface
        layer.cornerRadius = ChirpRadius.panel
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.12
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 2)
        isHidden = true
        accessibilityViewIsModal = true
        detail.font = UIFontMetrics(forTextStyle: .callout)
            .scaledFont(for: .systemFont(ofSize: 15), maximumPointSize: KeyboardMetrics.maxStripTextPoints)
        detail.adjustsFontForContentSizeCategory = true
        detail.textColor = KeyboardPalette.ink
        detail.numberOfLines = 0
        detail.accessibilityIdentifier = "chirp.keyboard.detail"
        var configuration = UIButton.Configuration.filled()
        configuration.title = "Got it"
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = KeyboardPalette.koiContainer
        configuration.baseForegroundColor = KeyboardPalette.onKoiContainer
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20)
        close.configuration = configuration
        close.accessibilityIdentifier = "chirp.keyboard.info.close"
        close.accessibilityLabel = KeyboardPresenter.closeInfoLabel
        close.setContentHuggingPriority(.required, for: .vertical)
        close.setContentCompressionResistancePriority(.required, for: .vertical)
        var ending = UIButton.Configuration.plain()
        ending.title = "End session"
        ending.image = UIImage(systemName: "mic.slash")
        ending.imagePadding = 6
        ending.baseForegroundColor = KeyboardPalette.record
        ending.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 12)
        end.configuration = ending
        end.accessibilityIdentifier = "chirp.keyboard.end"
        end.accessibilityLabel = "End session"
        end.accessibilityHint = "Turns off Chirp's microphone. Start a new session in Chirp."
        let buttons = UIStackView(arrangedSubviews: [end, UIView(), close])
        buttons.axis = .horizontal
        buttons.alignment = .center
        // The text takes the spare height; the buttons stay at the bottom of the panel.
        buttons.setContentHuggingPriority(.required, for: .vertical)
        let scroll = UIScrollView()
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.alwaysBounceVertical = false
        detail.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(detail)
        let stack = UIStackView(arrangedSubviews: [scroll, buttons])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let fit = scroll.heightAnchor.constraint(equalTo: detail.heightAnchor)
        fit.priority = .defaultLow
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            scroll.leadingAnchor.constraint(equalTo: stack.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            detail.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            detail.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            detail.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            detail.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor), fit,
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}
