import UIKit
import ChirpIOSCore
import KeyboardPolicy

/// Keyboard extension entry class. Capture and network remain in the app.
@MainActor
final class ChirpKeyboardViewController: UIInputViewController {
    private let status = UILabel()
    private let detail = UILabel()
    private let warning = UILabel()
    private let mic = UIButton(type: .system)
    private let cancel = UIButton(type: .system)
    private let raw = UIButton(type: .system)
    private let style = UIButton(type: .system)
    private let end = UIButton(type: .system)
    private let globe = UIButton(type: .system)
    private var bridge: KeyboardBridgeClient?
    private var state: BridgeState?
    private var policy = OwnedInsertion()
    private var timer: Timer?
    private var applying = false
    private var visible = false
    private var rawUntil: Date?
    private var rawRequested = false
    private var startPending = false
    private var pendingUntil: Date?
    private var fallback: String?
    private var stack: UIStackView!

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground
        status.font = .preferredFont(forTextStyle: .headline)
        detail.font = .preferredFont(forTextStyle: .caption1)
        warning.font = .preferredFont(forTextStyle: .caption1)
        warning.textColor = .systemRed
        for label in [status, detail, warning] {
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
        }
        configure(mic, title: "Start dictation", symbol: "mic.fill", action: #selector(micTapped))
        configure(cancel, title: "Cancel", symbol: "xmark", action: #selector(cancelTapped))
        configure(raw, title: "Use raw", symbol: "arrow.uturn.backward", action: #selector(rawTapped))
        configure(style, title: "Style", symbol: "sparkles", action: nil)
        configure(end, title: "End session", symbol: "mic.slash", action: #selector(endTapped))
        configure(globe, title: "Next keyboard", symbol: "globe", action: nil)
        globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        let space = UIButton(type: .system)
        let delete = UIButton(type: .system)
        let enter = UIButton(type: .system)
        let open = UIButton(type: .system)
        configure(space, title: "Space", symbol: nil, action: #selector(spaceTapped))
        configure(delete, title: "Delete", symbol: "delete.left", action: #selector(deleteTapped))
        configure(enter, title: "Return", symbol: "return", action: #selector(returnTapped))
        configure(open, title: "Open Chirp", symbol: "arrow.up.forward.app", action: #selector(openTapped))
        let actions = row([mic, cancel, raw])
        let options = row([style, end, open])
        let typing = row([globe, space, delete, enter])
        stack = UIStackView(arrangedSubviews: [status, detail, warning, actions, options, typing])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)
        ])
        style.showsMenuAsPrimaryAction = true
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        timer?.invalidate(); timer = nil
        cancelOwnedActiveUtterance()
        bridge = nil; state = nil
        visible = true
        invalidateOwnership()
        if hasFullAccess {
            do {
                bridge = try KeyboardBridgeClient()
                bridge?.onChange = { [weak self] in self?.reconcile() }
            } catch { fallback = "Shared session unavailable. Open Chirp to finish setup." }
        }
        reconcile()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcile() }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        cancelOwnedActiveUtterance()
        visible = false
        timer?.invalidate(); timer = nil
        bridge = nil; state = nil
        invalidateOwnership()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        globe.isHidden = !needsInputModeSwitchKey
        // Wider iPad keys preserve the same reading order and large hit targets.
        stack?.spacing = view.bounds.width >= 600 ? 12 : 8
    }

    override func textWillChange(_ textInput: (any UITextInput)?) {
        super.textWillChange(textInput)
        if !applying { invalidateOwnership() }
    }
    override func selectionWillChange(_ textInput: (any UITextInput)?) {
        super.selectionWillChange(textInput)
        if !applying { invalidateOwnership() }
    }
    override func textDidChange(_ textInput: (any UITextInput)?) {
        super.textDidChange(textInput)
        if !applying { invalidateOwnership(); render() }
    }
    override func selectionDidChange(_ textInput: (any UITextInput)?) {
        super.selectionDidChange(textInput)
        if !applying { invalidateOwnership(); render() }
    }

    private func configure(_ button: UIButton, title: String, symbol: String?, action: Selector?) {
        var configuration = UIButton.Configuration.tinted()
        configuration.title = title
        configuration.image = symbol.flatMap { UIImage(systemName: $0) }
        configuration.imagePadding = 5
        configuration.cornerStyle = .medium
        button.configuration = configuration
        button.titleLabel?.font = .preferredFont(forTextStyle: .body)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.titleLabel?.numberOfLines = 2
        button.accessibilityLabel = title
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        if let action { button.addTarget(self, action: action, for: .touchUpInside) }
    }

    private func row(_ buttons: [UIButton]) -> UIStackView {
        let result = UIStackView(arrangedSubviews: buttons)
        result.distribution = .fillEqually; result.spacing = 6
        return result
    }

    private func context() -> CursorContext {
        let proxy = textDocumentProxy
        return CursorContext(documentID: proxy.documentIdentifier,
                             before: proxy.documentContextBeforeInput,
                             after: proxy.documentContextAfterInput, selection: proxy.selectedText)
    }

    private func invalidateOwnership() {
        policy.invalidate(); rawUntil = nil; rawRequested = false; startPending = false; pendingUntil = nil
    }

    private func cancelOwnedActiveUtterance() {
        // No IPC after access revocation. On hide, only cancel our still-current
        // utterance; never cancel an app/companion recording or end the session.
        guard hasFullAccess, !policy.isFinal, let owned = policy.utteranceID,
              let state, state.generation == policy.generation, state.utteranceID == owned,
              state.phase == .connecting || state.phase == .listening || state.phase == .correcting else { return }
        try? bridge?.send(.cancel, state: state, utteranceID: owned)
    }

    private func reconcile() {
        guard visible else { return }
        guard hasFullAccess else {
            invalidateOwnership(); bridge = nil; state = nil; render(); return
        }
        do {
            if bridge == nil {
                bridge = try KeyboardBridgeClient()
                bridge?.onChange = { [weak self] in self?.reconcile() }
            }
            let current = try bridge?.state()
            if current?.generation != state?.generation { invalidateOwnership() }
            state = current
            guard let current, current.leaseUntil > Date() else {
                invalidateOwnership(); render(); return
            }
            fallback = nil
            if startPending && Date() >= (pendingUntil ?? .distantPast) { invalidateOwnership() }
            if let generation = policy.generation, let utterance = policy.utteranceID {
                if let active = current.utteranceID, active != utterance {
                    if !startPending { invalidateOwnership() }
                } else if current.utteranceID == utterance {
                    startPending = false; pendingUntil = nil
                    for result in try bridge?.results(generation: generation, utteranceID: utterance) ?? [] {
                        apply(result, leaseUntil: current.leaseUntil)
                    }
                }
            }
        } catch {
            state = nil; invalidateOwnership()
            fallback = "Session unavailable. Open Chirp to recover your dictation."
        }
        render()
    }

    private func apply(_ result: BridgeResult, leaseUntil: Date) {
        let kind: ResultKind
        switch result.kind {
        case .partial: kind = .partial
        case .correcting: kind = .correcting
        case .final: kind = .final
        case .raw: kind = .raw
        }
        let event = TextEvent(id: result.id, generation: result.generation, utteranceID: result.utteranceID,
                              kind: kind, text: result.text, sequence: result.sequence,
                              createdAt: result.createdAt, expiresAt: result.expiresAt)
        guard let plan = policy.plan(event, context: context(), now: Date(), leaseUntil: leaseUntil,
                                     rawRequested: rawRequested) else { return }
        startPending = false
        guard execute(plan), policy.didApply(plan, observed: context(), now: Date()) else {
            invalidateOwnership(); return
        }
        if kind == .final, let original = result.raw, original != result.text {
            rawUntil = Date().addingTimeInterval(5)
        }
        if kind == .raw { rawUntil = nil; rawRequested = false }
    }

    /// UIKit edits are synchronous requests, but hosts may apply them differently.
    /// Verify every intermediate context and stop immediately if one disagrees.
    private func execute(_ plan: EditPlan) -> Bool {
        guard context() == plan.expected else { return false }
        applying = true
        defer { applying = false }
        return VerifiedEditor.apply(plan, context: { self.context() },
                                    deleteBackward: { self.textDocumentProxy.deleteBackward() },
                                    insertText: { self.textDocumentProxy.insertText($0) })
    }

    private func send(_ action: BridgeAction, utteranceID: UUID? = nil) {
        guard hasFullAccess, let bridge, let state, state.leaseUntil > Date() else { render(); return }
        do { try bridge.send(action, state: state, utteranceID: utteranceID ?? state.utteranceID) }
        catch { fallback = "Command could not reach Chirp. Open Chirp to check the session." }
        render()
    }

    @objc private func micTapped() {
        guard hasFullAccess else { render(); return }
        reconcile()
        guard let state, state.leaseUntil > Date() else { openTapped(); return }
        switch state.phase {
        case .connecting, .listening:
            send(.stop)
        case .correcting:
            break
        case .armed, .finished:
            guard !startPending else { return }
            let utterance = UUID()
            guard policy.begin(generation: state.generation, utteranceID: utterance,
                               context: context(), now: Date()) else { render(); return }
            rawUntil = nil; rawRequested = false; startPending = true
            pendingUntil = Date().addingTimeInterval(5)
            send(.start, utteranceID: utterance)
        case .idle, .failed:
            openTapped()
        }
    }

    @objc private func cancelTapped() {
        guard !policy.isFinal else { return }
        let utterance = policy.utteranceID ?? state?.utteranceID
        if let plan = policy.cancel(context: context()) {
            if execute(plan) { policy = OwnedInsertion() } else { invalidateOwnership() }
        }
        rawUntil = nil; rawRequested = false; startPending = false; pendingUntil = nil
        send(.cancel, utteranceID: utterance)
    }
    @objc private func rawTapped() {
        guard let rawUntil, Date() < rawUntil, policy.isFinal, !rawRequested else { return }
        rawRequested = true
        send(.useRaw, utteranceID: policy.utteranceID)
    }
    @objc private func endTapped() { send(.end); invalidateOwnership() }
    @objc private func spaceTapped() { invalidateOwnership(); textDocumentProxy.insertText(" "); render() }
    @objc private func deleteTapped() { invalidateOwnership(); textDocumentProxy.deleteBackward(); render() }
    @objc private func returnTapped() { invalidateOwnership(); textDocumentProxy.insertText("\n"); render() }
    @objc private func openTapped() {
        fallback = "Open Chirp manually if iOS refuses. Return here using Back to app or the app switcher."
        render()
        guard let url = URL(string: "chirp://session/start") else { return }
        extensionContext?.open(url, completionHandler: { [weak self] opened in
            Task { @MainActor [weak self] in
                self?.fallback = opened
                    ? "Set up the session in Chirp, then return using the app switcher."
                    : "iOS could not open Chirp from this keyboard. Open Chirp manually, then return here."
                self?.render()
            }
        })
    }

    private func render() {
        let available = hasFullAccess && state != nil && (state?.leaseUntil ?? .distantPast) > Date()
        let phase = available ? state?.phase : nil
        let recording = phase == .connecting || phase == .listening
        mic.configuration?.title = recording ? "Stop dictation" : "Start dictation"
        mic.configuration?.image = UIImage(systemName: recording ? "stop.fill" : "mic.fill")
        mic.accessibilityLabel = recording ? "Stop dictation" : "Start dictation"
        mic.isEnabled = hasFullAccess && phase != .correcting && !startPending
        cancel.isEnabled = available && !policy.isFinal &&
            (phase == .connecting || phase == .listening || phase == .correcting || startPending)
        end.isEnabled = available
        style.isEnabled = available && !recording && phase != .correcting
        let titles = ["default": "Default", "chat": "Chat", "email": "Email", "code": "Code", "notes": "Notes", "custom": "Custom"]
        let availableStyles = state?.availableStyleIDs ?? []
        style.menu = UIMenu(children: availableStyles.map { id in
            UIAction(title: titles[id] ?? id, state: id == state?.styleID ? .on : .off) { [weak self] _ in
                self?.send(.style(id))
            }
        })
        style.isEnabled = style.isEnabled && !availableStyles.isEmpty
        style.configuration?.title = "Style: " + (titles[state?.styleID ?? "default"] ?? "Custom")
        raw.isEnabled = available && policy.isFinal && policy.generation != nil &&
            Date() < (rawUntil ?? .distantPast) && !rawRequested
        warning.text = state?.debugRetention == true ? "DEBUG recordings kept on the server" : nil
        warning.isHidden = warning.text == nil
        if !hasFullAccess {
            status.text = "Dictation needs Full Access"
            detail.text = "Enable Chirp Full Access in Settings → General → Keyboard, then open Chirp to set up. Space, delete, return and next keyboard work here."
        } else if let fallback {
            status.text = "Open Chirp"
            detail.text = fallback
        } else if policy.requiresRecovery {
            status.text = "Text kept in place"
            detail.text = "Cursor or text context changed. Recover the dictation in Chirp; automatic replacement is paused."
        } else if available {
            status.text = phase == .correcting ? "Polishing…" : recording ? "Dictating…" : "Session armed"
            detail.text = "Microphone stays active in Chirp. Idle audio is discarded. End session turns it off."
        } else {
            status.text = "Start a session in Chirp"
            detail.text = "Tap the microphone to try opening Chirp, then return to your editor. Handoff and automatic return are not guaranteed."
        }
    }
}
