import UIKit
import ChirpIOSCore
import KeyboardPolicy

/// Capsule chips on `surfaceRaised` that take over the suggestion row while they apply: Undo or Cancel, Use raw and
/// Open Chirp. A chip that doesn't apply is hidden (not disabled) and the row keeps its height, so nothing moves.
@MainActor
final class KeyboardChipRow: UIStackView {
    let undo = UIButton(type: .system)
    let cancel = UIButton(type: .system)
    let raw = UIButton(type: .system)
    let open = UIButton(type: .system)
    private let spacer = UIView()

    init() {
        super.init(frame: .zero)
        axis = .horizontal
        alignment = .fill
        distribution = .fill
        Self.configure(undo, title: "Undo", symbol: "arrow.uturn.backward", id: "undo", label: "Undo last dictation")
        Self.configure(cancel, title: "Cancel", symbol: "xmark", id: "cancel", label: "Cancel")
        Self.configure(raw, title: "Use raw", symbol: "text.append", id: "raw", label: "Use raw", tint: KeyboardPalette.moon)
        Self.configure(open, title: "Open Chirp", symbol: "arrow.up.forward.app", id: "open", label: "Open Chirp")
        spacing = 8
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for chip in [undo, cancel, raw, open] { addArrangedSubview(chip) }
        addArrangedSubview(spacer)
        for chip in [undo, cancel, raw, open] { chip.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal) }
    }
    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }

    func apply(_ screen: KeyboardScreen) {
        let chips = Set(screen.chips)
        undo.isHidden = !chips.contains(.undo)
        cancel.isHidden = !chips.contains(.cancel)
        raw.isHidden = !chips.contains(.raw)
        open.isHidden = !chips.contains(.open)
        raw.configuration?.title = screen.rawTitle
        raw.accessibilityLabel = "Use raw"
        raw.accessibilityValue = screen.rawSecondsLeft.map { "\($0) seconds left" }
    }

    static func configure(_ button: UIButton, title: String, symbol: String?, id: String, label: String,
                          tint: UIColor = KeyboardPalette.ink) {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.image = symbol.flatMap { UIImage(systemName: $0) }
        configuration.imagePadding = 4
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = KeyboardPalette.surfaceRaised
        configuration.baseForegroundColor = tint
        configuration.titleLineBreakMode = .byTruncatingTail
        // The capsule is 32 pt tall whatever the row height, and the whole row height stays tappable.
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
