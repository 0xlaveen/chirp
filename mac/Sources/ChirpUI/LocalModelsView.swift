import AppKit
import ChirpCore

/// Model choice is separate from downloading and applying it to the local server.
@MainActor
public final class LocalModelsView: NSView {
    public static let size = NSSize(width: 640, height: 720)
    public let speech = NSButton(title: "Download", target: nil, action: nil)
    public let cleanup = NSButton(title: "Download", target: nil, action: nil)
    public let start = NSButton(title: "Start Local Server", target: nil, action: nil)
    public let checkUpdates = NSButton(title: "Check for Updates", target: nil, action: nil)
    public let correction = NSButton(checkboxWithTitle: "Use local correction", target: nil, action: nil)
    public let speechPicker = NSPopUpButton()
    public let cleanupPicker = NSPopUpButton()
    public let repository = NSTextField()
    public let repositoryKind = NSPopUpButton()
    public let addRepository = NSButton(title: "Add Model", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private var details: [LocalModel: NSTextField] = [:]
    private var descriptions: [LocalModel: NSTextField] = [:]
    private var bars: [LocalModel: NSProgressIndicator] = [:]

    public init() {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        let title = NSTextField(labelWithString: "Models on this Mac")
        title.font = .systemFont(ofSize: 23, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString: "Choose speech and correction models. Downloads stay on your Mac; apply a selection when you’re ready to restart.")
        subtitle.textColor = .secondaryLabelColor; subtitle.font = .systemFont(ofSize: 13)
        let stack = NSStackView(views: [title, subtitle])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        for model in LocalModel.allCases { stack.addArrangedSubview(card(model)) }
        checkUpdates.bezelStyle = .rounded
        stack.addArrangedSubview(checkUpdates)
        repository.placeholderString = "Hugging Face owner/model"
        repository.setAccessibilityLabel("Hugging Face model repository")
        repositoryKind.addItems(withTitles: ["Speech", "Correction"])
        repositoryKind.setAccessibilityLabel("Model type to add")
        addRepository.bezelStyle = .rounded
        let advanced = NSStackView(views: [repositoryKind, repository, addRepository])
        advanced.orientation = .horizontal; advanced.spacing = 8
        advanced.widthAnchor.constraint(equalToConstant: Self.size.width - 56).isActive = true
        stack.addArrangedSubview(advanced)
        stack.addArrangedSubview(correction)
        status.font = .systemFont(ofSize: 12); status.setAccessibilityIdentifier("local-server-status")
        stack.addArrangedSubview(status)
        start.bezelStyle = .rounded; stack.addArrangedSubview(start)
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
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
        let picker = model == .speech ? speechPicker : cleanupPicker
        picker.setAccessibilityLabel("\(model.title) model")
        picker.setAccessibilityIdentifier("choose-\(model.rawValue)")
        let description = NSTextField(wrappingLabelWithString: model.subtitle)
        description.font = .systemFont(ofSize: 11); description.textColor = .secondaryLabelColor
        let button = model == .speech ? speech : cleanup
        button.bezelStyle = .rounded; button.setAccessibilityIdentifier("download-\(model.rawValue)")
        let header = NSStackView(views: [title, NSView(), button])
        header.orientation = .horizontal; header.alignment = .centerY
        let bar = NSProgressIndicator()
        bar.style = .bar; bar.minValue = 0; bar.maxValue = 100
        bar.setAccessibilityLabel("\(model.title) download progress")
        bar.setAccessibilityIdentifier("progress-\(model.rawValue)")
        let detail = NSTextField(wrappingLabelWithString: "Not downloaded")
        detail.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        detail.setAccessibilityIdentifier("status-\(model.rawValue)")
        details[model] = detail; descriptions[model] = description; bars[model] = bar
        let body = NSStackView(views: [header, picker, description, bar, detail])
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 7
        let box = NSBox()
        box.boxType = .custom; box.cornerRadius = 12; box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor; box.contentViewMargins = NSSize(width: 14, height: 12)
        let container = NSView(); container.addSubview(body); box.contentView = container
        box.translatesAutoresizingMaskIntoConstraints = false; body.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: Self.size.width - 56),
            box.heightAnchor.constraint(equalToConstant: 176),
            body.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            body.topAnchor.constraint(equalTo: container.topAnchor),
            body.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
            header.widthAnchor.constraint(equalToConstant: Self.size.width - 86),
            picker.widthAnchor.constraint(equalTo: header.widthAnchor),
            description.widthAnchor.constraint(equalTo: header.widthAnchor),
            bar.widthAnchor.constraint(equalTo: header.widthAnchor),
        ])
        return box
    }

    public func apply(_ state: LocalModelsState) {
        for model in LocalModel.allCases {
            let row = state.models[model] ?? LocalModelProgress()
            let option = state.option(model)
            let selected = state.activeModels[model.rawValue] == option?.id && option != nil
            let picker = model == .speech ? speechPicker : cleanupPicker
            let options = state.options.filter { $0.kind == model }
            // Avoid replacing an open native popup on every progress event.
            if picker.itemArray.compactMap({ $0.representedObject as? String }) != options.map(\.id) || picker.itemTitles != options.map(\.label) {
                picker.removeAllItems()
                for option in options {
                    picker.addItem(withTitle: option.label)
                    picker.lastItem?.toolTip = option.repository + "\nRevision: " + option.revision
                    picker.lastItem?.representedObject = option.id
                }
            }
            if let id = state.choices[model], let index = options.firstIndex(where: { $0.id == id }) { picker.selectItem(at: index) }
            picker.isEnabled = !row.busy && !state.starting && !state.catalogBusy
            let button = model == .speech ? speech : cleanup
            button.title = row.ready ? (option == nil ? "Downloaded" : selected ? "Selected" : "Use Model") : row.phase == "verifying" ? "Checking…" : row.phase == "cancelling" ? "Pausing…" : row.busy ? "Pause" : row.phase == "cancelled" ? "Resume" : row.phase == "error" ? "Retry" : "Download"
            button.isEnabled = !state.starting && (!state.catalogBusy || row.busy) && row.phase != "cancelling" && row.phase != "verifying" && !(row.ready && (selected || option == nil))
            descriptions[model]?.stringValue = option.map { $0.details + ($0.license.isEmpty ? "" : " · " + $0.license) } ?? model.subtitle
            details[model]?.stringValue = selected && row.ready ? (state.restartRequired ? "Selected · Restart to apply" : "Selected · Ready for offline use") : row.detail
            details[model]?.textColor = row.phase == "error" ? .systemRed : row.ready ? .systemGreen : .secondaryLabelColor
            if let bar = bars[model] {
                bar.isHidden = !row.busy; bar.isIndeterminate = row.fraction == nil || row.phase == "verifying"
                bar.doubleValue = (row.fraction ?? 0) * 100
                if row.busy && bar.isIndeterminate { bar.startAnimation(nil) } else { bar.stopAnimation(nil) }
                bar.setAccessibilityValue(row.fraction.map { "\(Int($0 * 100)) percent" } ?? "Preparing")
            }
        }
        checkUpdates.isEnabled = !state.catalogBusy && !state.starting
        checkUpdates.title = state.catalogBusy ? "Checking Models…" : "Check for Updates"
        addRepository.isEnabled = !state.catalogBusy && !state.starting && !state.models.values.contains(where: \.busy)
        correction.state = state.correctionEnabled ? .on : .off
        correction.isEnabled = state.correctionMode == "managed" && !state.restartRequired
        correction.toolTip = "Uses the selected local correction model after applying it to the server."
        let selectedSpeech = state.options.first { $0.kind == .speech && $0.id == state.activeModels["speech"] }
        let speechReady = selectedSpeech?.ready ?? (state.models[.speech]?.ready == true)
        start.isEnabled = speechReady && !state.starting && !state.catalogBusy && !state.models.values.contains(where: \.busy) && (state.restartRequired || !state.serverRunning)
        start.title = state.starting ? "Starting…" : state.restartRequired ? "Apply & Restart Server" : state.serverRunning ? "Server Running" : "Start Local Server"
        status.stringValue = state.message
        status.textColor = state.errorMessage != nil ? .systemRed : state.serverRunning ? .systemGreen : .secondaryLabelColor
    }
}
