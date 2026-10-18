#if os(macOS)
import Carbon.HIToolbox
import Foundation

/// The short window after a cleaned-up insertion in which "Use raw" is offered outside the HUD: a global ⌃⌥Z hotkey
/// that exists only while the window is open, and a menu item. The HUD itself is already gone. The timing comes from an
/// injected sleep so the tests drive it with a fake clock.
@MainActor
public final class RawOffer {
    public static let duration: Duration = .seconds(5)
    public static let combo = KeyCombo.custom(keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(controlKey | optionKey))

    public private(set) var isOpen = false
    /// The ⌃⌥Z hotkey is registered for this window. False when it is the dictation hotkey or another app owns it:
    /// the menu item is then the only way.
    public private(set) var hotkeyActive = false

    private let sleep: @Sendable (Duration) async -> Void
    private let register: (KeyCombo, @escaping () -> Void) -> Bool
    private let unregister: () -> Void
    private let use: () -> Void
    private let onChange: () -> Void
    private var task: Task<Void, Never>?
    private var generation = 0

    public init(sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
                register: @escaping (KeyCombo, @escaping () -> Void) -> Bool,
                unregister: @escaping () -> Void,
                use: @escaping () -> Void,
                onChange: @escaping () -> Void = {}) {
        self.sleep = sleep
        self.register = register
        self.unregister = unregister
        self.use = use
        self.onChange = onChange
    }

    /// Opens the window for `duration`. `dictation` is the dictation hotkey: ⌃⌥Z is not registered when it is the same.
    public func open(avoiding dictation: KeyCombo? = nil, for duration: Duration = RawOffer.duration) {
        closeQuietly()
        isOpen = true
        if dictation != Self.combo {
            hotkeyActive = register(Self.combo) { [weak self] in self?.take() }
        }
        generation += 1
        let token = generation
        task = Task { [weak self, sleep] in
            await sleep(duration)
            guard !Task.isCancelled else { return }
            self?.expire(token)
        }
        onChange()
    }

    /// Ends the window (a new dictation started, or "Use raw" was taken).
    public func close() {
        guard isOpen else { return }
        closeQuietly()
        onChange()
    }

    /// The hotkey or the menu item: spends the offer and runs "Use raw". Nothing when the window is not open.
    public func take() {
        guard isOpen else { return }
        close()
        use()
    }

    private func expire(_ token: Int) {
        guard isOpen, generation == token else { return }
        close()
    }

    private func closeQuietly() {
        task?.cancel()
        task = nil
        generation += 1
        if hotkeyActive { unregister() }
        hotkeyActive = false
        isOpen = false
    }
}

#endif
