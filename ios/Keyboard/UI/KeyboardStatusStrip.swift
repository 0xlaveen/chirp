import UIKit
import ChirpIOSCore
import KeyboardPolicy

/// The 44 pt status strip: a state glyph, one short label, the DEBUG badge, the elapsed or remaining time in tabular
/// digits and the ⓘ button. One line in every state, so the keyboard never changes height.
@MainActor
final class KeyboardStatusStrip: UIView {
    let label = UILabel()
    let time = UILabel()
    let info = UIButton(type: .system)
    private let glyphBox = UIView()
    private let ripple = KeyboardRippleView()
    private let symbol = UIImageView()
    private let dot = UIView()
    private let badge = UILabel()
    private var glyph: StripGlyph?

    init() {
        super.init(frame: .zero)
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

        let row = UIStackView(arrangedSubviews: [glyphBox, label, UIView(), badge, time, info])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        row.setCustomSpacing(0, after: time)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            badge.heightAnchor.constraint(equalToConstant: 18), badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 46),
            info.widthAnchor.constraint(equalToConstant: 44), info.heightAnchor.constraint(equalToConstant: 44),
        ])
        // The label takes the leftover width; the spacer only absorbs slack.
        row.arrangedSubviews[2].setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func apply(_ screen: KeyboardScreen) {
        label.text = screen.phaseText
        time.text = screen.trailing
        time.isHidden = screen.trailing == nil
        // The ticking elapsed time is never announced; the "left" text is a plain label for VoiceOver.
        time.isAccessibilityElement = screen.elapsed == nil && screen.trailing != nil
        time.accessibilityLabel = screen.remaining
        badge.isHidden = screen.warning == nil
        info.isHidden = screen.detail == nil
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

/// The ⓘ overlay: the long guidance, laid over the rows under the strip so the keys don't move. Its label keeps the
/// `chirp.keyboard.detail` identifier.
@MainActor
final class KeyboardInfoOverlay: UIView {
    let detail = UILabel()
    let close = UIButton(type: .system)

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
        let scroll = UIScrollView()
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.alwaysBounceVertical = false
        detail.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(detail)
        let stack = UIStackView(arrangedSubviews: [scroll, close])
        stack.axis = .vertical
        stack.alignment = .trailing
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
