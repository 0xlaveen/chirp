import UIKit
import ChirpIOSCore
import KeyboardPolicy

/// The one row above the keys, as on Android: while idle it is the suggestion bar with a small ⋯ options button at the
/// leading edge and a small mic at the trailing edge (the word suggestions are KeyboardKit's, laid under this row, and
/// touches in the middle pass through to them). Every other state takes the same row over: ✕ · Ripple "Listening…" ·
/// time · red ■ Stop; ✦ Polishing…; ✓ Finished · Use raw · Undo; a short notice; or one compact message with ⋯ and one
/// action. The row is a fixed height (`KeyboardMetrics.suggestionHeight`), so the keyboard never changes height.
@MainActor
final class KeyboardTopRow: UIView {
    let label = UILabel()
    let time = UILabel()
    /// ⋯ at the leading edge: opens the options panel (Style, help, End session).
    let options = UIButton(type: .system)
    let cancel = UIButton(type: .system)
    let undo = UIButton(type: .system)
    let raw = UIButton(type: .system)
    let open = UIButton(type: .system)
    /// The mic while idle, Stop while dictating, Polishing…, or Open Chirp: the trailing action.
    let primary = UIButton(type: .system)
    private let backing = UIView()
    private let tint = UIView()
    private let glyphBox = UIView()
    private let ripple = KeyboardRippleView()
    private let symbol = UIImageView()
    private let dot = UIView()
    private let row = UIStackView()
    private var glyph: StripGlyph?
    private var mode: TopRow = .suggestions
    private var showsTitle = false
    private var primaryStyle: PrimaryStyle = .koi { didSet { if primaryStyle != oldValue { primary.setNeedsUpdateConfiguration() } } }
    private var primaryPlain = true { didSet { if primaryPlain != oldValue { primary.setNeedsUpdateConfiguration() } } }
    private var primaryWidth: NSLayoutConstraint!
    private var insets: [NSLayoutConstraint] = []

    init() {
        super.init(frame: .zero)
        configurePrimary()
        Self.configure(undo, title: "Undo", symbol: "arrow.uturn.backward", id: "undo", label: "Undo last dictation")
        Self.configure(raw, title: "Use raw", symbol: "text.append", id: "raw", label: "Use raw", tint: KeyboardPalette.onMoonFill,
                       fill: KeyboardPalette.moonFill)
        Self.configure(open, title: "Open Chirp", symbol: "arrow.up.forward.app", id: "open", label: "Open Chirp")

        var more = UIButton.Configuration.plain()
        more.image = UIImage(systemName: "ellipsis")
        more.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        more.baseForegroundColor = KeyboardPalette.inkMuted
        more.contentInsets = .zero
        options.configuration = more
        options.accessibilityLabel = KeyboardPresenter.optionsLabel
        options.accessibilityHint = "Style, help and End session."
        options.accessibilityIdentifier = "chirp.keyboard.options"

        var close = UIButton.Configuration.plain()
        close.image = UIImage(systemName: "xmark")
        close.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        close.baseForegroundColor = KeyboardPalette.onKoiContainer
        close.contentInsets = .zero
        cancel.configuration = close
        cancel.accessibilityLabel = "Cancel dictation"
        cancel.accessibilityIdentifier = "chirp.keyboard.cancel"

        label.font = UIFontMetrics(forTextStyle: .subheadline)
            .scaledFont(for: .systemFont(ofSize: 15, weight: .medium), maximumPointSize: KeyboardMetrics.maxRowTextPoints)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = KeyboardPalette.ink
        label.lineBreakMode = .byTruncatingTail
        label.accessibilityIdentifier = "chirp.keyboard.status"
        label.accessibilityTraits.insert(.updatesFrequently)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        time.font = UIFontMetrics(forTextStyle: .subheadline)
            .scaledFont(for: .monospacedDigitSystemFont(ofSize: 14, weight: .regular), maximumPointSize: KeyboardMetrics.maxRowTextPoints)
        time.adjustsFontForContentSizeCategory = true
        time.textColor = KeyboardPalette.onKoiContainer
        time.textAlignment = .right
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        time.setContentHuggingPriority(.required, for: .horizontal)
        // The ticking elapsed time is never announced.
        time.isAccessibilityElement = false
        time.accessibilityIdentifier = "chirp.keyboard.time"

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

        for view in [backing, tint] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.isUserInteractionEnabled = false
            addSubview(view)
            NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: leadingAnchor), view.trailingAnchor.constraint(equalTo: trailingAnchor),
                                         view.topAnchor.constraint(equalTo: topAnchor), view.bottomAnchor.constraint(equalTo: bottomAnchor)])
        }
        backing.alpha = 0
        let spacer = UIView()
        for view in [options, cancel, glyphBox, label, spacer, time, undo, raw, open, primary] { row.addArrangedSubview(view) }
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        row.setCustomSpacing(0, after: options)
        row.setCustomSpacing(0, after: cancel)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        insets = [row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor)]
        NSLayoutConstraint.activate(insets + [
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            options.widthAnchor.constraint(equalToConstant: KeyboardMetrics.controlWidth), options.heightAnchor.constraint(equalTo: row.heightAnchor),
            cancel.widthAnchor.constraint(equalToConstant: KeyboardMetrics.controlWidth), cancel.heightAnchor.constraint(equalTo: row.heightAnchor),
            undo.heightAnchor.constraint(equalTo: row.heightAnchor), raw.heightAnchor.constraint(equalTo: row.heightAnchor),
            open.heightAnchor.constraint(equalTo: row.heightAnchor), primary.heightAnchor.constraint(equalTo: row.heightAnchor),
            primaryWidth,
        ])
        // The label takes the leftover width; the spacer only absorbs slack.
        spacer.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for chip in [undo, raw, open] { chip.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal) }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// While idle only the two small buttons are the row's: everything between them belongs to the suggestions below.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard mode == .suggestions else { return super.point(inside: point, with: event) }
        return [options, primary].contains { button in
            !button.isHidden && button.point(inside: button.convert(point, from: self), with: event)
        }
    }

    // MARK: Primary

    /// Idle it is the mic alone (a koi glyph, no fill); as Stop, Polishing… or Open Chirp it is a filled capsule, 32 pt
    /// tall inside the row (the whole row height stays tappable).
    private func configurePrimary() {
        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .capsule
        configuration.imagePadding = 6
        configuration.titleLineBreakMode = .byTruncatingTail
        configuration.background.backgroundInsets = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFontMetrics(forTextStyle: .subheadline)
                .scaledFont(for: .systemFont(ofSize: 15, weight: .semibold), maximumPointSize: KeyboardMetrics.maxRowTextPoints)
            return attributes
        }
        primary.configuration = configuration
        primary.accessibilityIdentifier = "chirp.keyboard.primary"
        primary.titleLabel?.adjustsFontForContentSizeCategory = true
        primary.setContentHuggingPriority(.required, for: .horizontal)
        primary.setContentCompressionResistancePriority(.required, for: .horizontal)
        primaryWidth = primary.widthAnchor.constraint(greaterThanOrEqualToConstant: KeyboardMetrics.controlWidth)
        // A disabled primary is a status (Polishing…), not a dimmed button: it keeps its own colours.
        primary.configurationUpdateHandler = { [weak self] button in
            guard let self, var configuration = button.configuration else { return }
            if self.primaryPlain {
                configuration.baseBackgroundColor = .clear
                configuration.baseForegroundColor = KeyboardPalette.koi
                configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
                configuration.contentInsets = .zero
            } else {
                let (fill, ink) = self.primaryColors
                configuration.baseBackgroundColor = fill
                configuration.baseForegroundColor = ink
                configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
                configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14)
            }
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

    // MARK: Render

    func apply(_ metrics: KeyboardMetrics) {
        showsTitle = metrics.showsPrimaryTitle
        insets[0].constant = metrics.inset - 2; insets[1].constant = -metrics.inset
    }

    func apply(_ screen: KeyboardScreen) {
        let next = screen.topRow
        let changed = next != mode
        if changed, window != nil, !UIAccessibility.isReduceMotionEnabled {
            UIView.transition(with: self, duration: 0.15, options: [.transitionCrossDissolve, .allowUserInteraction]) { self.layout(screen) }
        } else {
            layout(screen)
        }
    }

    private func layout(_ screen: KeyboardScreen) {
        let next = screen.topRow
        mode = next
        let action = screen.primary
        let chips = Set(screen.chips)
        let idle = next == .suggestions
        // Everything the row can show, then only what applies.
        backing.alpha = idle ? 0 : 1
        let (base, wash) = fills(for: screen)
        backing.backgroundColor = base
        tint.backgroundColor = wash
        let onTint = next == .dictating || next == .polishing
        label.textColor = onTint ? KeyboardPalette.onKoiContainer : KeyboardPalette.ink
        label.text = screen.phaseText
        label.isHidden = idle
        glyphBox.isHidden = idle
        time.text = screen.elapsed
        time.isHidden = next != .dictating || screen.elapsed == nil
        options.isHidden = !(idle || next == .notReady) || screen.detail == nil
        cancel.isHidden = !chips.contains(.cancel)
        undo.isHidden = !chips.contains(.undo)
        raw.isHidden = !chips.contains(.raw)
        undo.configuration?.title = screen.undoTitle
        undo.accessibilityLabel = "Undo last dictation"
        undo.accessibilityValue = screen.undoSecondsLeft.map { "\($0) seconds left" }
        raw.configuration?.title = screen.rawTitle
        raw.accessibilityLabel = "Use raw"
        raw.accessibilityValue = screen.rawSecondsLeft.map { "\($0) seconds left" }
        // The fallback "Open Chirp" is the one action of a not-ready row; the primary steps aside for it.
        let opens = next == .notReady && chips.contains(.open) && action.kind != .openChirp
        open.isHidden = !opens
        let hasPrimary: Bool
        switch next {
        case .suggestions: hasPrimary = action.kind != .fullAccess
        case .dictating, .polishing: hasPrimary = true
        case .notReady: hasPrimary = !opens && action.kind != .fullAccess
        case .finished, .notice: hasPrimary = false
        }
        primary.isHidden = !hasPrimary
        primaryPlain = idle
        primaryStyle = action.style
        let title = next == .notReady && (showsTitle || action.kind == .openChirp) ? action.rowTitle : nil
        primary.configuration?.title = title
        primary.configuration?.image = UIImage(systemName: action.symbol)
        primary.accessibilityLabel = action.accessibilityLabel
        primary.accessibilityHint = action.hint
        primaryWidth.constant = idle ? KeyboardMetrics.controlWidth : KeyboardMetrics.minimumPrimaryWidth
        // Polishing is a status, not a dimmed button: it stays "enabled" so it keeps its moon fill, and VoiceOver
        // still reads it as dimmed. The controller ignores the tap.
        primary.isEnabled = action.isEnabled || action.kind == .polishing
        if action.kind == .polishing { primary.accessibilityTraits.insert(.notEnabled) } else { primary.accessibilityTraits.remove(.notEnabled) }
        setGlyph(screen.glyph)
    }

    /// The row's opaque base and the wash over it (the error red), as Android tints its row from the keyboard's own
    /// colours. The idle row has none: the system's suggestion bar shows through.
    private func fills(for screen: KeyboardScreen) -> (UIColor?, UIColor?) {
        switch screen.topRow {
        case .suggestions: return (nil, nil)
        case .dictating, .polishing: return (KeyboardPalette.koiContainer, nil)
        case .finished, .notice: return (KeyboardPalette.surfaceRaised, nil)
        case .notReady: return (KeyboardPalette.surfaceRaised, screen.glyph == .warning ? KeyboardPalette.record.withAlphaComponent(0.14) : nil)
        }
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
        case .check:
            symbol.image = UIImage(systemName: "checkmark")?.applyingSymbolConfiguration(.init(pointSize: 15, weight: .bold))
            symbol.tintColor = KeyboardPalette.koi
        case .idle:
            // The approved brand glyph from the asset catalog the extension ships (template-rendered).
            symbol.image = UIImage(named: "ChirpGlyph", in: .main, compatibleWith: nil)
            symbol.tintColor = KeyboardPalette.inkMuted
        case .ripple, .koiDot: break
        }
    }

    /// Capsule chips (Undo, Use raw, Open Chirp, the Style picker), 32 pt tall whatever the row height; the whole row
    /// height stays tappable.
    static func configure(_ button: UIButton, title: String, symbol: String?, id: String, label: String,
                          tint: UIColor = KeyboardPalette.onKoiContainer, fill: UIColor = KeyboardPalette.koiContainer) {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.image = symbol.flatMap { UIImage(systemName: $0) }
        configuration.imagePadding = 4
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = fill
        configuration.baseForegroundColor = tint
        configuration.titleLineBreakMode = .byTruncatingTail
        configuration.background.backgroundInsets = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFontMetrics(forTextStyle: .footnote)
                .scaledFont(for: .systemFont(ofSize: 14, weight: .medium), maximumPointSize: KeyboardMetrics.maxChipTextPoints)
            return attributes
        }
        button.configuration = configuration
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.accessibilityLabel = label
        button.accessibilityIdentifier = "chirp.keyboard." + id
    }
}

/// The options panel behind ⋯: the Style picker and the session's time left, the long guidance and End session, laid
/// over the keys so nothing moves. Its label keeps the `chirp.keyboard.detail` identifier.
@MainActor
final class KeyboardInfoOverlay: UIView {
    let detail = UILabel()
    let close = UIButton(type: .system)
    /// Ends the keyboard session (the app's microphone turns off); shown while a session is live.
    let end = UIButton(type: .system)
    /// The clean-up style (and Private session) menu; shown while a session is live.
    let style = UIButton(type: .system)
    /// "4:12 left": the session's remaining time, a detail here rather than a label in the row.
    let remaining = UILabel()

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
            .scaledFont(for: .systemFont(ofSize: 15), maximumPointSize: KeyboardMetrics.maxRowTextPoints)
        detail.adjustsFontForContentSizeCategory = true
        detail.textColor = KeyboardPalette.ink
        detail.numberOfLines = 0
        detail.accessibilityIdentifier = "chirp.keyboard.detail"
        KeyboardTopRow.configure(style, title: "Default", symbol: nil, id: "style", label: "Style")
        style.configuration?.image = UIImage(systemName: "chevron.down")
        style.configuration?.imagePlacement = .trailing
        style.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
        style.configuration?.background.backgroundInsets = .zero
        style.showsMenuAsPrimaryAction = true
        style.setContentHuggingPriority(.required, for: .horizontal)
        style.heightAnchor.constraint(equalToConstant: 36).isActive = true
        remaining.font = UIFontMetrics(forTextStyle: .subheadline)
            .scaledFont(for: .monospacedDigitSystemFont(ofSize: 14, weight: .regular), maximumPointSize: KeyboardMetrics.maxRowTextPoints)
        remaining.adjustsFontForContentSizeCategory = true
        remaining.textColor = KeyboardPalette.inkMuted
        remaining.textAlignment = .right
        remaining.accessibilityIdentifier = "chirp.keyboard.remaining"
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
        // Explicit anchors, not a stack: the header sits at the top, the buttons at the bottom, and the text scrolls in
        // between (a scroll view has no intrinsic height for a stack to hug).
        let buttons = UIStackView(arrangedSubviews: [end, UIView(), close])
        buttons.axis = .horizontal
        buttons.alignment = .center
        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = false
        detail.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(detail)
        for view in [style, remaining, buttons, scroll] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            style.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), style.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            remaining.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16), remaining.centerYAnchor.constraint(equalTo: style.centerYAnchor),
            remaining.leadingAnchor.constraint(greaterThanOrEqualTo: style.trailingAnchor, constant: 8),
            buttons.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: style.bottomAnchor, constant: 8), scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -8),
            detail.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            detail.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            detail.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            detail.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}
