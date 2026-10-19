import AppKit
import ChirpCore

/// A persistent home for model downloads; closing its window does not stop a download.
@MainActor
public final class LocalModelsView: NSView {
    public static let size = NSSize(width: 560, height: 550)
    public let speech = NSButton(title: "Download", target: nil, action: nil)
    public let cleanup = NSButton(title: "Download", target: nil, action: nil)
    public let start = NSButton(title: "Start Local Server", target: nil, action: nil)
    public let correction = NSButton(checkboxWithTitle: "Use local Qwen correction", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private var details: [LocalModel: NSTextField] = [:]
    private var bars: [LocalModel: NSProgressIndicator] = [:]

    public init() {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        let title = NSTextField(labelWithString: "Models on this Mac")
        title.font = .systemFont(ofSize: 23, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString: "Download once, then dictate offline. Your speech and Qwen correction stay on this Mac.")
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: 13)
        let stack = NSStackView(views: [title, subtitle])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        for model in LocalModel.allCases { stack.addArrangedSubview(card(model)) }
        stack.addArrangedSubview(correction)
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.setAccessibilityIdentifier("local-server-status")
        stack.addArrangedSubview(status)
        start.bezelStyle = .rounded
        stack.addArrangedSubview(start)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size.width),
            heightAnchor.constraint(equalToConstant: Self.size.height),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 26),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -20),
        ])
        apply(LocalModelsState())
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    private func card(_ model: LocalModel) -> NSView {
        let title = NSTextField(labelWithString: model.title)
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        let subtitle = NSTextField(labelWithString: model.subtitle)
        subtitle.font = .systemFont(ofSize: 12); subtitle.textColor = .secondaryLabelColor
        let button = model == .speech ? speech : cleanup
        button.bezelStyle = .rounded
        button.setAccessibilityIdentifier("download-\(model.rawValue)")
        let header = NSStackView(views: [title, NSView(), button])
        header.orientation = .horizontal; header.alignment = .centerY
        let bar = NSProgressIndicator()
        bar.style = .bar; bar.minValue = 0; bar.maxValue = 100
        bar.setAccessibilityLabel("\(model.title) download progress")
        bar.setAccessibilityIdentifier("progress-\(model.rawValue)")
        let detail = NSTextField(wrappingLabelWithString: "Not downloaded")
        detail.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.setAccessibilityIdentifier("status-\(model.rawValue)")
        details[model] = detail; bars[model] = bar
        let body = NSStackView(views: [header, subtitle, bar, detail])
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 7
        let box = NSBox()
        box.boxType = .custom; box.cornerRadius = 12; box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.contentViewMargins = NSSize(width: 14, height: 12)
        let container = NSView()
        container.addSubview(body)
        box.contentView = container
        box.translatesAutoresizingMaskIntoConstraints = false
        body.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: Self.size.width - 56),
            box.heightAnchor.constraint(equalToConstant: 126),
            body.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            body.topAnchor.constraint(equalTo: container.topAnchor),
            body.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
            header.widthAnchor.constraint(equalToConstant: Self.size.width - 86),
            bar.widthAnchor.constraint(equalTo: header.widthAnchor),
        ])
        return box
    }

    public func apply(_ state: LocalModelsState) {
        for model in LocalModel.allCases {
            let row = state.models[model] ?? LocalModelProgress()
            let button = model == .speech ? speech : cleanup
            button.title = row.ready ? "Downloaded" : row.phase == "cancelling" ? "Pausing…" : row.busy ? "Pause" : row.phase == "cancelled" ? "Resume" : row.phase == "error" ? "Retry" : "Download"
            button.isEnabled = !row.ready && row.phase != "cancelling"
            details[model]?.stringValue = row.detail
            details[model]?.textColor = row.phase == "error" ? .systemRed : row.ready ? .systemGreen : .secondaryLabelColor
            if let bar = bars[model] {
                bar.isHidden = !row.busy
                bar.isIndeterminate = row.fraction == nil
                bar.doubleValue = (row.fraction ?? 0) * 100
                if row.busy && bar.isIndeterminate { bar.startAnimation(nil) } else { bar.stopAnimation(nil) }
                bar.setAccessibilityValue(row.fraction.map { "\(Int($0 * 100)) percent" } ?? "Preparing")
            }
        }
        correction.state = state.correctionEnabled ? .on : .off
        correction.isEnabled = state.correctionMode == "managed"
        correction.toolTip = state.correctionMode == "managed" ? "Uses the downloaded Qwen model on this Mac." : "This server is not configured for local correction."
        start.isEnabled = state.models[.speech]?.ready == true && !state.starting && !state.serverRunning
        start.title = state.starting ? "Starting…" : state.serverRunning ? "Server Running" : "Start Local Server"
        status.stringValue = state.message
        status.textColor = state.errorMessage != nil ? .systemRed : state.serverRunning ? .systemGreen : .secondaryLabelColor
    }
}
