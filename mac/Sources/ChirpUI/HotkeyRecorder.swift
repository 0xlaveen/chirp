import AppKit
import ChirpCore
import Carbon.HIToolbox

/// The recorder's pure rules: what a key press means while it is listening.
public enum HotkeyRecording {
    public enum Outcome: Equatable, Sendable {
        case accepted(KeyCombo)
        case rejected(HotKeyValidation.Rejection)
        /// Esc on its own leaves recording without changing anything.
        case cancelled
    }

    /// AppKit modifier flags to the Carbon flags `RegisterEventHotKey` takes (⌃⌥⇧⌘ only).
    public static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m = 0
        if flags.contains(.control) { m |= controlKey }
        if flags.contains(.option) { m |= optionKey }
        if flags.contains(.shift) { m |= shiftKey }
        if flags.contains(.command) { m |= cmdKey }
        return UInt32(m)
    }

    public static func outcome(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Outcome {
        let modifiers = carbonModifiers(flags)
        if Int(keyCode) == kVK_Escape, modifiers == 0 { return .cancelled }
        switch HotKeyValidation.validate(keyCode: UInt32(keyCode), modifiers: modifiers) {
        case .success(let combo): return .accepted(combo)
        case .failure(let why): return .rejected(why)
        }
    }
}

/// A shortcut recorder: click, then press the combination. It listens only while recording (a local event monitor,
/// so no Input Monitoring permission) and swallows every key meanwhile so nothing else reacts. A combination that
/// cannot fire is refused with the reason and recording continues; Esc or a click elsewhere gives up.
@MainActor
public final class HotkeyRecorder: NSButton {
    public enum Status: Equatable, Sendable {
        case idle
        case recording(heldModifiers: String)
        case rejected(HotKeyValidation.Rejection)
    }

    public private(set) var status: Status = .idle { didSet { refreshTitle(); onStatusChange?(status) } }
    public var onCapture: ((KeyCombo) -> Void)?
    /// True when recording begins and false when it ends, so the owner can release the live hotkey meanwhile
    /// (pressing the current shortcut would otherwise start a dictation).
    public var onRecordingChanged: ((Bool) -> Void)?
    public var onStatusChange: ((Status) -> Void)?
    public var isRecording: Bool { if case .idle = status { false } else { true } }

    private var monitor: Any?

    public init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        controlSize = .small
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggle)
        setAccessibilityLabel("Record a custom shortcut")
        refreshTitle()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    /// Leaving a window (it closed, or the form was torn down) ends recording so no monitor outlives it.
    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() }
    }

    private func refreshTitle() {
        switch status {
        case .idle: title = "Record Shortcut…"
        case .recording(let held): title = held.isEmpty ? "Type shortcut…" : held
        case .rejected: title = "Type shortcut…"
        }
    }

    @objc private func toggle() { isRecording ? stop() : start() }

    public func start() {
        guard !isRecording else { return }
        status = .recording(heldModifiers: "")
        onRecordingChanged?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            nonisolated(unsafe) let e = event
            let swallow = MainActor.assumeIsolated { self?.handle(e) ?? false }
            return swallow ? nil : event
        }
        window?.makeFirstResponder(self)
    }

    public func stop() {
        guard isRecording else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        status = .idle
        onRecordingChanged?(false)
    }

    /// Returns true when the event is consumed (every key while recording).
    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .flagsChanged:
            status = .recording(heldModifiers: HotKeyValidation.modifierSymbols(HotkeyRecording.carbonModifiers(event.modifierFlags)))
            return false
        case .keyDown:
            apply(HotkeyRecording.outcome(keyCode: event.keyCode, flags: event.modifierFlags))
            return true
        default:
            // A click anywhere but the button gives up; a click on the button toggles through its action.
            if event.window !== window || !(hitTestInWindow(event)) { stop() }
            return false
        }
    }

    private func hitTestInWindow(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        return bounds.contains(point)
    }

    /// Applies a key press's outcome (the event monitor calls this; tests call it directly).
    public func apply(_ outcome: HotkeyRecording.Outcome) {
        switch outcome {
        case .accepted(let combo):
            stop()
            onCapture?(combo)
        case .rejected(let why):
            status = .rejected(why)
        case .cancelled:
            stop()
        }
    }
}
