import AppKit
import ChirpCore
import CoreImage

/// A QR code drawn crisp at any size: black modules on white, built with Core Image (no dependency, no network).
public enum QRCode {
    /// One pixel per module, or nil when the text does not fit a QR code.
    public static func modules(_ text: String) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }

    /// The code at `side` points, drawn without smoothing so every module keeps hard edges.
    public static func image(_ text: String, side: CGFloat) -> NSImage? {
        guard let cg = modules(text) else { return nil }
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            guard let context = NSGraphicsContext.current else { return false }
            context.imageInterpolation = .none
            context.cgContext.draw(cg, in: rect)
            return true
        }
    }

    /// The same code blurred past reading, for while Chirp is in the background.
    public static func blurred(_ text: String, side: CGFloat) -> NSImage? {
        guard let cg = modules(text) else { return nil }
        let scale = 8.0
        let big = CIImage(cgImage: cg).samplingNearest().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let blurred = big.clampedToExtent().applyingGaussianBlur(sigma: scale * 2.5).cropped(to: big.extent)
        guard let out = CIContext().createCGImage(blurred, from: big.extent) else { return nil }
        return NSImage(cgImage: out, size: NSSize(width: side, height: side))
    }
}

/// What the pairing window says for each step, in words and which controls show.
public struct PairingPresentation: Equatable, Sendable {
    public var headline: String
    public var detail: String
    public var tone: MenuEntry.Tone = .normal
    /// The exact command shown before it is run.
    public var command: String?
    /// The button under it: "Run Command…" or "Check Again", or none while busy.
    public var action: String?
    public var showsCode = false
    /// The name field shows, filled with this.
    public var asksName: String?

    public init(_ step: PairingStep) {
        switch step {
        case .naming(let suggested, let problem):
            headline = "Name this phone"
            detail = problem ?? "Each phone gets its own pairing, so you can cut one off later in Settings → Devices without re-pairing the others."
            if problem != nil { tone = .warning }
            asksName = suggested
            action = "Continue"
        case .checking:
            headline = "Checking Tailscale…"
            detail = "Looking for this Mac’s tailnet name and whether Chirp is published on it."
        case .remoteServer:
            headline = "Chirp uses your Chirp server"
            detail = "Run the pairing command on your Chirp server: chirp-server pair."
            tone = .warning
        case .noTailscale:
            headline = "Tailscale isn’t installed"
            detail = "Your phone reaches this Mac over your tailnet. Install Tailscale and sign in on this Mac and the phone, then check again."
            tone = .warning
            action = "Check Again"
        case .tailscaleOff:
            headline = "Tailscale isn’t connected"
            detail = "Open Tailscale on this Mac and sign in, then check again."
            tone = .warning
            action = "Check Again"
        case .notServed(let c):
            headline = "Publish Chirp on your tailnet"
            detail = "Your phone can’t reach Chirp yet. This command shares it with your own tailnet devices only, never the internet (no Funnel). Undo it with \(TailscaleServe.undoCommand)."
            command = c
            action = "Run Command…"
        case .publishing(let c):
            headline = "Publishing on your tailnet…"
            detail = "Tailscale is adding \(TailscaleServe.path) for this Mac."
            command = c
        case .publishFailed(let c, let reason):
            headline = "Tailscale didn’t publish Chirp"
            detail = reason
            tone = .warning
            command = c
            action = "Run Command…"
        case .conflict(let target):
            headline = "\(TailscaleServe.path) is already in use"
            detail = "Tailscale serves \(TailscaleServe.path) from \(target). Chirp leaves it alone: free it with \(TailscaleServe.undoCommand), then check again."
            tone = .warning
            action = "Check Again"
        case .funnel:
            headline = "Funnel is on for this Mac"
            detail = "Funnel puts served paths on the public internet, so Chirp won’t pair here. Turn Funnel off for this Mac, then check again."
            tone = .error
            action = "Check Again"
        case .failed(let reason):
            headline = "Couldn’t check Tailscale"
            detail = reason
            tone = .warning
            action = "Check Again"
        case .noToken:
            headline = "No pairing code yet"
            detail = "Start Chirp on this Mac once, then check again."
            tone = .warning
            action = "Check Again"
        case .cannotMint(let reason):
            headline = "Couldn’t pair this phone"
            detail = reason
            tone = .warning
            action = "Try Again"
        case .ready(let link):
            headline = "Scan with Chirp on your phone"
            detail = "In Chirp on Android or iPhone, tap Scan the code. The phone connects to \(link.serverURL.absoluteString) over your tailnet."
            showsCode = true
        }
    }
}

/// The pairing window's content. Plain AppKit like Settings; the owner wires `action` and `copyLink`.
@MainActor
public final class PairingView: NSView {
    static let width: CGFloat = 400
    static let codeSide: CGFloat = 220
    public static let secretWarning = "This code works like a password to your Chirp server. Don’t screenshot or share it."
    public static let concealedText = "Hidden while Chirp is in the background"

    public let action = NSButton(title: "", target: nil, action: nil)
    public let copyLink = NSButton(title: "Copy Pairing Link…", target: nil, action: nil)
    /// The phone's name; Return in it presses `action`.
    public let nameField = NSTextField(string: "")
    private let icon = NSImageView()
    private let headline = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let command = NSTextField(wrappingLabelWithString: "")
    private let commandBox = Panel(fill: .textBackgroundColor, border: .separatorColor, radius: 6, inset: NSSize(width: 10, height: 8))
    private let code = NSImageView()
    /// Scanners want dark modules on light, so the code sits on white in both appearances.
    private let codeBox = Panel(fill: .white, radius: 10, inset: NSSize(width: 16, height: 16))
    private let concealedLabel = NSTextField(labelWithString: PairingView.concealedText)
    private let countdown = NSTextField(labelWithString: "")
    private let warning = NSTextField(wrappingLabelWithString: PairingView.secretWarning)
    private var shownURI: String?
    private var sharp: NSImage?
    private var blurred: NSImage?
    public private(set) var isConcealed = false

    public init() {
        super.init(frame: .zero)
        headline.font = .systemFont(ofSize: 15, weight: .semibold)
        headline.lineBreakMode = .byTruncatingTail
        for f in [detail, warning] {
            f.font = MenuStyle.secondaryFont
            f.textColor = .secondaryLabelColor
            f.preferredMaxLayoutWidth = Self.width - 40
        }
        detail.isSelectable = true
        command.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        command.isSelectable = true
        command.preferredMaxLayoutWidth = Self.width - 64
        command.setAccessibilityLabel("Command")
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setAccessibilityElement(false)

        code.imageScaling = .scaleNone
        code.setAccessibilityLabel("Pairing QR code")
        code.translatesAutoresizingMaskIntoConstraints = false
        concealedLabel.font = MenuStyle.semiboldFont
        concealedLabel.textColor = .black
        concealedLabel.drawsBackground = true
        concealedLabel.backgroundColor = NSColor.white.withAlphaComponent(0.85)
        concealedLabel.translatesAutoresizingMaskIntoConstraints = false
        commandBox.hold(command)
        let codeContent = NSView()
        codeContent.addSubview(code)
        codeContent.addSubview(concealedLabel)
        codeBox.hold(codeContent)
        NSLayoutConstraint.activate([
            code.widthAnchor.constraint(equalToConstant: Self.codeSide), code.heightAnchor.constraint(equalToConstant: Self.codeSide),
            code.topAnchor.constraint(equalTo: codeContent.topAnchor), code.bottomAnchor.constraint(equalTo: codeContent.bottomAnchor),
            code.leadingAnchor.constraint(equalTo: codeContent.leadingAnchor), code.trailingAnchor.constraint(equalTo: codeContent.trailingAnchor),
            concealedLabel.centerXAnchor.constraint(equalTo: code.centerXAnchor), concealedLabel.centerYAnchor.constraint(equalTo: code.centerYAnchor),
        ])

        nameField.placeholderString = "Phone name"
        nameField.setAccessibilityLabel("Phone name")
        nameField.cell?.sendsActionOnEndEditing = false

        countdown.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        countdown.textColor = .secondaryLabelColor
        for b in [action, copyLink] { b.bezelStyle = .rounded }
        copyLink.setAccessibilityHelp("Copies the secret pairing link after a warning.")

        let titleRow = NSStackView(views: [icon, headline])
        titleRow.orientation = .horizontal
        titleRow.spacing = 6
        let codeRow = NSStackView(views: [codeBox])
        codeRow.orientation = .vertical
        codeRow.alignment = .centerX
        let footer = NSStackView(views: [countdown, NSView(), copyLink])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        let stack = NSStackView(views: [titleRow, detail, nameField, commandBox, action, codeRow, warning, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(4, after: titleRow)
        stack.setCustomSpacing(14, after: codeRow)
        stack.setCustomSpacing(6, after: warning)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: 20),
            bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: 20),
            codeRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            commandBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            nameField.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        apply(.checking)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows `step`; `remaining` seconds before the code hides, and `concealed` while Chirp is in the background.
    public func apply(_ step: PairingStep, remaining: Int = PairingTimer.lifetime, concealed: Bool = false) {
        let p = PairingPresentation(step)
        headline.stringValue = p.headline
        detail.stringValue = p.detail
        let symbol = switch p.tone {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        default: p.showsCode ? "qrcode" : "iphone.and.arrow.forward"
        }
        icon.image = MenuStyle.symbol(symbol, tone: p.tone)
        if let suggested = p.asksName {
            // Keep what the user typed while the step stays the same; a new naming step starts from its suggestion.
            if nameField.isHidden || nameField.stringValue.isEmpty { nameField.stringValue = suggested }
        }
        nameField.isHidden = p.asksName == nil
        command.stringValue = p.command ?? ""
        commandBox.isHidden = p.command == nil
        action.title = p.action ?? ""
        action.isHidden = p.action == nil
        action.setAccessibilityLabel(p.action)
        let uri: String? = if case .ready(let link) = step { link.uri } else { nil }
        if uri != shownURI {
            shownURI = uri
            sharp = uri.flatMap { QRCode.image($0, side: Self.codeSide) }
            blurred = uri.flatMap { QRCode.blurred($0, side: Self.codeSide) }
        }
        isConcealed = concealed
        code.image = concealed ? blurred : sharp
        concealedLabel.isHidden = !concealed
        for v in [codeBox.superview, warning, countdown.superview] { v?.isHidden = !p.showsCode }
        countdown.stringValue = "Hides in \(PairingTimer.text(remaining))"
        copyLink.isEnabled = p.showsCode && !concealed
    }

    /// The link left the window (hidden or closed): drop the images that encode it.
    public func forget() {
        nameField.stringValue = ""
        apply(.checking)
    }
}

/// A rounded background drawn behind `content`, inset on every side (drawn, so offscreen snapshots show it too).
@MainActor
private final class Panel: NSView {
    private let fill: NSColor
    private let border: NSColor?
    private let radius: CGFloat

    private let inset: NSSize

    init(fill: NSColor, border: NSColor? = nil, radius: CGFloat, inset: NSSize) {
        self.fill = fill
        self.border = border
        self.radius = radius
        self.inset = inset
        super.init(frame: .zero)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    func hold(_ content: NSView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: inset.height),
            bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: inset.height),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset.width),
            trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: inset.width),
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        fill.setFill()
        path.fill()
        if let border {
            border.setStroke()
            path.stroke()
        }
    }
}
