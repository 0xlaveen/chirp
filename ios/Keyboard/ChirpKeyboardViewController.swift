import UIKit
import ChirpIOSCore
import KeyboardPolicy

/// Delete key: reports touch-down/up so the controller can repeat while held. VoiceOver activation
/// sends neither, so it is mapped to a single press+release.
private final class HoldRepeatButton: KeyCapButton {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    override func accessibilityActivate() -> Bool { onPress?(); onRelease?(); return true }
}

/// Keyboard extension entry class. Capture and network remain in the app. All screen decisions live in
/// `KeyboardPresenter` (KeyboardPolicy package); this class only gathers inputs and applies the result.
@MainActor
final class ChirpKeyboardViewController: UIInputViewController {
    private let strip = KeyboardStatusStrip()
    private let overlay = KeyboardInfoOverlay()
    private let chips = KeyboardChipRow()
    private let primary = UIButton(type: .system)
    private let end = KeyCapButton(type: .system)
    private let globe = KeyCapButton(type: .system)
    private let space = KeyCapButton(type: .system)
    private let delete = HoldRepeatButton(type: .system)
    private let enter = KeyCapButton(type: .system)
    private var cancel: UIButton { chips.cancel }
    private var raw: UIButton { chips.raw }
    private var style: UIButton { chips.style }
    private var open: UIButton { chips.open }
    private var bridge: KeyboardBridgeClient?
    private var state: BridgeState?
    private var policy = OwnedInsertion()
    private var timer: Timer?
    private var applying = false
    private var visible = false
    private var rawUntil: Date?
    private var kept = false
    private var notice: String?
    private var noticeUntil: Date?
    private var rawRequested = false
    private var startPending = false
    private var pendingUntil: Date?
    private var fallback: String?
    private var clock = RecordingClock()
    private var styleItems: [StyleItem] = []
    private var privacyOn = false
    private var repeatTimer: Timer?
    private var repeatCount = 0
    private lazy var haptic = UIImpactFeedbackGenerator(style: .light)
    private var stack: UIStackView!
    private var columnStack: UIStackView!
    private var keyRow: UIStackView!
    private var keyHeights: [NSLayoutConstraint] = []
    private var insets: [NSLayoutConstraint] = []
    private var primaryHeight: NSLayoutConstraint!
    private var chipHeight: NSLayoutConstraint!
    private var stripHeight: NSLayoutConstraint!
    private var columnCap: NSLayoutConstraint!
    private var appliedMetrics: KeyboardMetrics?

    override func viewDidLoad() {
        super.viewDidLoad()
        // No background of our own: the input view's `.keyboard` surface is the system keyboard's surround.
        configurePrimary()
        overlay.accessibilityViewIsModal = true
        strip.info.addTarget(self, action: #selector(infoTapped), for: .touchUpInside)
        overlay.close.addTarget(self, action: #selector(infoTapped), for: .touchUpInside)
        chips.cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        chips.undo.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        chips.raw.addTarget(self, action: #selector(rawTapped), for: .touchUpInside)
        chips.open.addTarget(self, action: #selector(openTapped), for: .touchUpInside)
        configureKey(end, kind: .function, title: "End", symbol: "mic.slash", id: "end", action: #selector(endTapped))
        end.accessibilityLabel = "End session"
        configureKey(globe, kind: .function, title: nil, symbol: "globe", id: "globe", action: nil)
        globe.accessibilityLabel = "Next keyboard"
        globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        configureKey(space, kind: .letter, title: "space", symbol: nil, id: "space", action: #selector(spaceTapped))
        space.accessibilityLabel = "Space"
        configureKey(delete, kind: .function, title: nil, symbol: "delete.left", id: "delete", action: nil)
        delete.accessibilityLabel = "Delete"
        delete.accessibilityHint = "Touch and hold to keep deleting."
        delete.addTarget(self, action: #selector(deleteDown), for: .touchDown)
        delete.addTarget(self, action: #selector(deleteUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        delete.onPress = { [weak self] in self?.deleteDown() }
        delete.onRelease = { [weak self] in self?.deleteUp() }
        configureKey(enter, kind: .function, title: nil, symbol: "return", id: "return", action: #selector(returnTapped))
        enter.accessibilityLabel = "Return"

        // The strip, primary and chips share one column (capped and centred on iPad); the typing row spans the width.
        stripHeight = strip.heightAnchor.constraint(equalToConstant: KeyboardMetrics.stripHeight)
        chipHeight = chips.heightAnchor.constraint(equalToConstant: 40)
        stripHeight.isActive = true; chipHeight.isActive = true
        columnStack = UIStackView(arrangedSubviews: [strip, primary, chips])
        columnStack.axis = .vertical
        let column = UIView()
        columnStack.translatesAutoresizingMaskIntoConstraints = false
        column.addSubview(columnStack)
        columnCap = columnStack.widthAnchor.constraint(lessThanOrEqualToConstant: KeyboardMetrics.iPadColumnWidth)
        let fill = [columnStack.leadingAnchor.constraint(equalTo: column.leadingAnchor),
                    columnStack.trailingAnchor.constraint(equalTo: column.trailingAnchor)]
        fill.forEach { $0.priority = .defaultHigh }
        NSLayoutConstraint.activate(fill + [
            columnStack.centerXAnchor.constraint(equalTo: column.centerXAnchor),
            columnStack.topAnchor.constraint(equalTo: column.topAnchor),
            columnStack.bottomAnchor.constraint(equalTo: column.bottomAnchor), columnCap])

        keyRow = UIStackView(arrangedSubviews: [globe, space, delete, enter, end])
        for key in [globe, delete, enter, end] {
            key.setContentHuggingPriority(.required, for: .horizontal)
            key.widthAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
        }
        space.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack = UIStackView(arrangedSubviews: [column, keyRow])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlay)
        insets = [stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                  stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                  stack.topAnchor.constraint(equalTo: view.topAnchor),
                  stack.bottomAnchor.constraint(equalTo: view.bottomAnchor)]
        NSLayoutConstraint.activate(insets + [
            overlay.leadingAnchor.constraint(equalTo: primary.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: primary.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: strip.bottomAnchor),
            overlay.bottomAnchor.constraint(equalTo: keyRow.bottomAnchor),
        ])
        registerForTraitChanges([UITraitVerticalSizeClass.self]) { (self: Self, _) in self.render() }
        applyMetrics()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        timer?.invalidate(); timer = nil
        stopRepeat()
        cancelOwnedActiveUtterance()
        bridge = nil; state = nil
        visible = true
        invalidateOwnership()
        if hasFullAccess {
            do {
                bridge = try KeyboardBridgeClient()
                bridge?.onChange = { [weak self] in self?.reconcile() }
            } catch { fallback = "Shared session unavailable. Open Chirp to finish setup." }
            // Lets the app's setup checklist show "keyboard ready". Only a timestamp is stored.
            try? KeyboardSetupStore(root: SharedConfiguration(bundle: .main).containerURL()).recordFullAccess()
        }
        reconcile()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcile() }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopRepeat()
        cancelOwnedActiveUtterance()
        setInfo(open: false)
        visible = false
        timer?.invalidate(); timer = nil
        bridge = nil; state = nil
        invalidateOwnership()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyMetrics()
        if globe.isHidden == needsInputModeSwitchKey { render() }
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

    // MARK: Layout

    private func configureKey(_ key: KeyCapButton, kind: KeyCapButton.Kind, title: String?, symbol: String?, id: String,
                              action: Selector?) {
        KeyboardKeyStyle.apply(to: key, kind: kind, title: title, symbol: symbol)
        key.accessibilityLabel = title
        key.accessibilityIdentifier = "chirp.keyboard." + id
        keyHeights.append(key.heightAnchor.constraint(equalToConstant: 48))
        keyHeights.last?.isActive = true
        if let action { key.addTarget(self, action: action, for: .touchUpInside) }
    }

    /// The one big control: a capsule whose fill follows `PrimaryStyle` (koi, record, moon or tonal koiContainer).
    private func configurePrimary() {
        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .capsule
        configuration.imagePadding = 8
        configuration.titleLineBreakMode = .byTruncatingTail
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFontMetrics(forTextStyle: .title3)
                .scaledFont(for: .systemFont(ofSize: 20, weight: .semibold), maximumPointSize: KeyboardMetrics.maxPrimaryTextPoints)
            return attributes
        }
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        primary.configuration = configuration
        primary.accessibilityIdentifier = "chirp.keyboard.primary"
        primary.titleLabel?.adjustsFontForContentSizeCategory = true
        primary.addTarget(self, action: #selector(primaryTapped), for: .touchUpInside)
        primary.translatesAutoresizingMaskIntoConstraints = false
        primaryHeight = primary.heightAnchor.constraint(equalToConstant: KeyboardMetrics.minimumPrimaryHeight)
        primaryHeight.isActive = true
        // A disabled primary is a status (Polishing…, Full Access required), not a dimmed button: keep its own colours.
        primary.configurationUpdateHandler = { [weak self] button in
            guard let self, var configuration = button.configuration else { return }
            let (fill, ink) = self.primaryColors
            configuration.baseBackgroundColor = fill
            configuration.baseForegroundColor = ink
            button.configuration = configuration
        }
    }

    private var primaryStyle: PrimaryStyle = .tonal { didSet { if primaryStyle != oldValue { primary.setNeedsUpdateConfiguration() } } }
    private var primaryColors: (UIColor, UIColor) {
        switch primaryStyle {
        case .koi: (KeyboardPalette.koi, KeyboardPalette.onKoi)
        case .record: (KeyboardPalette.record, KeyboardPalette.onRecord)
        case .moon: (KeyboardPalette.moonFill, KeyboardPalette.onMoonFill)
        case .tonal: (KeyboardPalette.koiContainer, KeyboardPalette.onKoiContainer)
        }
    }

    private var compactHeight: Bool { traitCollection.verticalSizeClass == .compact }

    /// iPad: wider spacing, one capped and centred column. Compact height (landscape iPhone): smaller keys. Every row
    /// has a fixed height, so the keyboard is the same height in every state.
    private func applyMetrics() {
        let metrics = KeyboardMetrics.make(width: Double(view.bounds.width), compactHeight: compactHeight)
        guard metrics != appliedMetrics else { return }
        appliedMetrics = metrics
        ([stack!, columnStack!, keyRow!, chips]).forEach { $0.spacing = metrics.spacing }
        chips.spacing = 8
        keyHeights.forEach { $0.constant = metrics.keyHeight }
        primaryHeight.constant = metrics.primaryHeight
        chipHeight.constant = metrics.chipHeight
        stripHeight.constant = metrics.stripHeight
        columnCap.isActive = metrics.maxPrimaryWidth != nil
        columnCap.constant = metrics.maxPrimaryWidth ?? 0
        insets[0].constant = metrics.inset; insets[1].constant = -metrics.inset
        insets[2].constant = metrics.verticalInset; insets[3].constant = -metrics.verticalInset
    }

    // MARK: Ownership

    private func context() -> CursorContext {
        let proxy = textDocumentProxy
        return CursorContext(documentID: proxy.documentIdentifier,
                             before: proxy.documentContextBeforeInput,
                             after: proxy.documentContextAfterInput, selection: proxy.selectedText,
                             hasText: proxy.hasText)
    }

    private func invalidateOwnership() {
        // Losing real ownership also ends a held Delete; the hold's own presses never owned anything.
        if policy.generation != nil || startPending { stopRepeat() }
        policy.invalidate(); rawUntil = nil; rawRequested = false; startPending = false; pendingUntil = nil; kept = false
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
                              createdAt: result.createdAt, expiresAt: result.expiresAt, segment: result.segment ?? 0)
        guard let plan = policy.plan(event, context: context(), now: Date(), leaseUntil: leaseUntil,
                                     rawRequested: rawRequested, commands: state?.spokenCommands == true) else { return }
        startPending = false
        guard execute(plan), policy.didApply(plan, observed: context(), now: Date()) else {
            invalidateOwnership(); return
        }
        if kind == .final { kept = result.kept == true; pressReturnIfAsked(after: plan, result: result) }
        if kind == .final, let original = result.raw, original != result.text {
            rawUntil = Date().addingTimeInterval(5)
        }
        if kind == .raw { rawUntil = nil; rawRequested = false }
    }

    /// UIKit edits are synchronous requests, but hosts may apply them differently.
    /// Verify every intermediate context and stop immediately if one disagrees.
    private func execute(_ plan: EditPlan) -> Bool {
        guard context().matches(plan.expected) else { return false }
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

    // MARK: Actions

    /// Light feedback on start/stop. Keyboards without Full Access may not use haptics, so skip them.
    private func tick() { if hasFullAccess { haptic.impactOccurred() } }

    @objc private func primaryTapped() {
        guard hasFullAccess else { render(); return }
        reconcile()
        guard let state, state.leaseUntil > Date() else { openTapped(); return }
        switch state.phase {
        case .connecting, .listening:
            tick(); send(.stop)
        case .correcting:
            break
        case .armed, .finished:
            guard !startPending else { return }
            let utterance = UUID()
            guard policy.begin(generation: state.generation, utteranceID: utterance,
                               context: context(), now: Date()) else { render(); return }
            stopRepeat(); tick()
            rawUntil = nil; rawRequested = false; startPending = true
            pendingUntil = Date().addingTimeInterval(5)
            send(.start, utteranceID: utterance)
        case .idle, .failed:
            openTapped()
        }
    }

    @objc private func cancelTapped() {
        if policy.canUndo(now: Date()) { undo(); return }
        guard !policy.isFinal else { return }
        let utterance = policy.utteranceID ?? state?.utteranceID
        if let plan = policy.cancel(context: context()) {
            if execute(plan) { policy = OwnedInsertion() } else { invalidateOwnership() }
        }
        rawUntil = nil; rawRequested = false; startPending = false; pendingUntil = nil
        send(.cancel, utteranceID: utterance)
    }
    /// Auto-Enter: after the last segment's final, wait for the host to settle, then type Return only if the editor
    /// still shows exactly what we left (a cursor move or edit cancels it).
    private func pressReturnIfAsked(after plan: EditPlan, result: BridgeResult) {
        let mode = AutoEnterMode(rawValue: state?.autoEnter ?? "") ?? .off
        guard textDocumentProxy.isSecureTextEntry != true,
              AutoEnter.presses(mode: mode, returnKey: returnKey(), kept: result.kept == true, moved: false,
                                lastSegment: state?.phase == .finished, text: plan.replacement) else { return }
        let landed = context()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.visible, self.policy.isFinal, self.context().matches(landed) else { return }
            self.textDocumentProxy.insertText("\n")
            // Sent: nothing is left to undo or swap.
            self.policy.release(); self.rawUntil = nil; self.rawRequested = false; self.kept = false
            self.show("Finished · " + AutoEnter.sent)
            self.render()
        }
    }
    private func returnKey() -> ReturnKey {
        switch textDocumentProxy.returnKeyType ?? .default {
        case .default: .plain
        case .send: .send
        case .go: .go
        case .done: .done
        case .join: .join
        case .route: .route
        case .continue: .continue
        case .search, .google, .yahoo: .search
        case .next, .emergencyCall: .next
        @unknown default: .other
        }
    }

    /// Removes the dictation that just landed, only if the editor still shows exactly what we inserted.
    private func undo() {
        if let plan = policy.undo(context: context(), now: Date()), execute(plan) { show("Dictation removed") }
        else { show("Text changed — nothing to undo") }
        policy.release(); rawUntil = nil; rawRequested = false; kept = false
        render()
    }
    private func show(_ text: String) { notice = text; noticeUntil = Date().addingTimeInterval(3) }
    @objc private func rawTapped() {
        guard let rawUntil, Date() < rawUntil, policy.isFinal, !rawRequested else { return }
        rawRequested = true
        send(.useRaw, utteranceID: policy.utteranceID)
    }
    @objc private func endTapped() { send(.end); invalidateOwnership() }
    @objc private func spaceTapped() { invalidateOwnership(); textDocumentProxy.insertText(" "); render() }
    @objc private func returnTapped() { invalidateOwnership(); textDocumentProxy.insertText("\n"); render() }
    @objc private func openTapped() {
        fallback = "Open Chirp manually if iOS refuses. Return here using Back to app or the app switcher."
        render()
        guard let url = URL(string: "chirp://session/start") else { return }
        if openThroughApplication(url) {
            fallback = "Set up the session in Chirp, then return using the app switcher."
            render()
            return
        }
        // The completion's thread is unspecified; @Sendable keeps it free of main-actor isolation checks.
        extensionContext?.open(url, completionHandler: { @Sendable [weak self] opened in
            Task { @MainActor [weak self] in
                self?.fallback = opened
                    ? "Set up the session in Chirp, then return using the app switcher."
                    : "iOS could not open Chirp from this keyboard. Open Chirp manually, then return here."
                self?.render()
            }
        })
    }
    /// `extensionContext.open` always fails for keyboards (it serves Today widgets only). The UIApplication at
    /// the end of the responder chain still opens URLs, but its `open(_:options:)` is extension-unavailable,
    /// so it is called through its selector. Personal-install only: an App Store review risk (see README).
    private func openThroughApplication(_ url: URL) -> Bool {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication, application.responds(to: selector) {
                typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?) -> Void
                let open = unsafeBitCast(application.method(for: selector), to: Open.self)
                open(application, selector, url as NSURL, [:] as NSDictionary, nil)
                return true
            }
            responder = current.next
        }
        return false
    }

    // MARK: Delete press-and-hold

    @objc private func deleteDown() {
        stopRepeat()
        invalidateOwnership()
        deleteOnce()
        repeatTimer = scheduleRepeat(after: KeyRepeat.initialDelay)
    }
    @objc private func deleteUp() { stopRepeat() }

    private func scheduleRepeat(after delay: TimeInterval) -> Timer {
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.repeatFired() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private func repeatFired() {
        // A hold never edits through an owned utterance: if one appears, stop instead of racing it.
        guard repeatTimer != nil, policy.generation == nil, !startPending else { stopRepeat(); return }
        deleteOnce()
        repeatCount += 1
        repeatTimer = scheduleRepeat(after: KeyRepeat.interval(afterRepeats: repeatCount))
    }

    private func deleteOnce() {
        applying = true
        textDocumentProxy.deleteBackward()
        applying = false
        render()
    }

    private func stopRepeat() {
        repeatTimer?.invalidate(); repeatTimer = nil; repeatCount = 0
    }

    // MARK: Render

    private func inputs() -> KeyboardInputs {
        let now = Date()
        var i = KeyboardInputs(now: now)
        i.hasFullAccess = hasFullAccess
        if hasFullAccess, let state {
            i.phase = KeyboardPhase(rawValue: state.phase.rawValue)
            i.leaseUntil = state.leaseUntil; i.sessionExpiresAt = state.sessionExpiresAt
            i.styleID = state.styleID; i.availableStyleIDs = state.availableStyleIDs
            i.debugRetention = state.debugRetention; i.privacyMode = state.privacyMode
            i.errorCode = state.errorCode.flatMap { KeyboardError(rawValue: $0.rawValue) }
        }
        i.ownsUtterance = policy.generation != nil
        i.isFinal = policy.isFinal; i.requiresRecovery = policy.requiresRecovery
        i.rawUntil = rawUntil; i.rawRequested = rawRequested; i.startPending = startPending
        i.undoAvailable = policy.canUndo(now: now); i.kept = kept
        i.notice = now < (noticeUntil ?? .distantPast) ? notice : nil
        i.fallback = fallback
        let live = hasFullAccess && (state?.leaseUntil ?? .distantPast) > now
        let owned = state.flatMap { $0.generation == policy.generation && !policy.isFinal ? policy.utteranceID : nil }
        clock.observe(phase: live ? i.phase : nil, ownedUtterance: live && owned == state?.utteranceID ? owned : nil, now: now)
        i.recordingStartedAt = clock.startedAt
        i.needsGlobe = needsInputModeSwitchKey
        i.compactHeight = compactHeight
        #if DEBUG && targetEnvironment(simulator)
        KeyboardPreview.apply(to: &i)
        #endif
        return i
    }

    private func render() {
        let screen = KeyboardPresenter.screen(inputs())
        strip.apply(screen)
        #if DEBUG && targetEnvironment(simulator)
        if KeyboardPreview.preset != nil { setInfo(open: KeyboardPreview.opensInfo) }
        #endif
        overlay.detail.text = screen.detail
        if screen.detail == nil { setInfo(open: false) }
        let action = screen.primary
        primaryStyle = action.style
        primary.configuration?.title = action.title
        primary.configuration?.image = UIImage(systemName: action.symbol)
        primary.accessibilityLabel = action.accessibilityLabel
        primary.accessibilityHint = action.hint
        // Polishing is a status, not a dimmed button: it stays "enabled" so it keeps its moon fill, and VoiceOver
        // still reads it as dimmed. primaryTapped ignores the tap.
        primary.isEnabled = action.isEnabled || action.kind == .polishing
        if action.kind == .polishing { primary.accessibilityTraits.insert(.notEnabled) } else { primary.accessibilityTraits.remove(.notEnabled) }
        chips.apply(screen)
        // Rebuilding the menu while it is open would dismiss it, so only replace it when items change.
        if screen.styleItems != styleItems || screen.privacyOn != privacyOn {
            styleItems = screen.styleItems; privacyOn = screen.privacyOn
            let styles = styleItems.map { item in
                UIAction(title: item.title, state: item.isChecked ? .on : .off) { [weak self] _ in
                    self?.send(.style(item.id))
                }
            }
            let on = privacyOn
            let privacy = UIAction(title: KeyboardPresenter.privateTitle, state: on ? .on : .off) { [weak self] _ in
                self?.send(.privacy(!on))
            }
            style.menu = UIMenu(children: [UIMenu(options: .displayInline, children: styles), UIMenu(options: .displayInline, children: [privacy])])
        }
        end.isEnabled = screen.endEnabled
        globe.isHidden = !screen.showsGlobe
    }

    // MARK: Info overlay

    @objc private func infoTapped() { setInfo(open: overlay.isHidden) }

    private func setInfo(open: Bool) {
        guard overlay.isHidden == open else { return }
        overlay.isHidden = !open
        stripInfoAccessibility(open: open)
        UIAccessibility.post(notification: .screenChanged, argument: open ? overlay.detail : strip.info)
    }

    private func stripInfoAccessibility(open: Bool) {
        strip.info.configuration?.image = UIImage(systemName: open ? "info.circle.fill" : "info.circle")
        strip.info.accessibilityValue = open ? "Expanded" : nil
    }
}
