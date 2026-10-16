import Foundation

public enum AXInsertAttempt: Sendable, Equatable {
    /// The AX write was never made (no focused element, not settable, unreadable field, or the call failed),
    /// so falling back to paste cannot duplicate text.
    case notAttempted
    /// The write was accepted and read back. `range` (UTF-16 units) is where the text landed, if known.
    case verified(NSRange?)
    /// The write was accepted but the readback never changed: the app may still apply it.
    case unverified
}

/// The system calls insertion depends on, injectable so the strategy runs in tests.
@MainActor
public struct InsertionEnvironment {
    public var secureInputEnabled: () -> Bool
    public var axTrusted: () -> Bool
    public var frontmostBundleID: () -> String?
    /// Sets the focused element's selected text and verifies the value changed.
    public var axInsert: (String) async -> AXInsertAttempt
    /// Reselects `range` in the focused element if it still holds `expected` there, then replaces it. False otherwise.
    public var axReplace: (NSRange, String, String) async -> Bool
    /// Posts ⌘V. Returns false if the event could not be created.
    public var postPaste: () -> Bool
    public var postUndo: () -> Bool
    public var sleep: (Duration) async -> Void

    public init(secureInputEnabled: @escaping () -> Bool, axTrusted: @escaping () -> Bool,
                frontmostBundleID: @escaping () -> String?,
                axInsert: @escaping (String) async -> AXInsertAttempt,
                axReplace: @escaping (NSRange, String, String) async -> Bool,
                postPaste: @escaping () -> Bool, postUndo: @escaping () -> Bool,
                sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.secureInputEnabled = secureInputEnabled
        self.axTrusted = axTrusted
        self.frontmostBundleID = frontmostBundleID
        self.axInsert = axInsert
        self.axReplace = axReplace
        self.postPaste = postPaste
        self.postUndo = postUndo
        self.sleep = sleep
    }
}

/// AX insert → paste (pasteboard saved and restored) → copy-only.
@MainActor
public final class TextInserter {
    /// Slow apps can take a while to read the pasteboard after ⌘V. The change-count guard protects user copies.
    public static let restoreDelay: Duration = .milliseconds(600)

    private enum Last { case ax(NSRange?, String), unverified, paste, copy }

    private let env: InsertionEnvironment
    private let pasteboard: PasteboardClient
    private var restoreTask: Task<Void, Never>?
    private var last: Last?

    public init(env: InsertionEnvironment, pasteboard: PasteboardClient) {
        self.env = env
        self.pasteboard = pasteboard
    }

    public func insert(_ text: String) async -> InsertionOutcome {
        let plan = InsertionPolicy.plan(secureInput: env.secureInputEnabled(), axTrusted: env.axTrusted(),
                                        bundleID: env.frontmostBundleID())
        guard case .try_(let methods) = plan else { return .refusedSecure }
        for method in methods {
            switch method {
            case .ax:
                switch await env.axInsert(text) {
                case .verified(let range):
                    last = .ax(range, text)
                    return .inserted(.ax)
                case .unverified:
                    // Never paste after an attempted AX write: if it lands late we would insert twice.
                    _ = pasteboard.write(text: text, transient: true)
                    last = .unverified
                    return .insertedUnverified
                case .notAttempted:
                    continue
                }
            case .paste:
                if pasteViaPasteboard(text) { last = .paste; return .inserted(.paste) }
            case .copy:
                _ = pasteboard.write(text: text, transient: false)
                last = .copy
                return .copied
            }
        }
        return .copied
    }

    /// Replaces what the previous `insert` put in the field with `raw` ("Use raw").
    /// AX insertions are replaced in place by reselecting the exact inserted range. Pasted text can only be
    /// taken back with ⌘Z, which is best effort. If the field changed or nothing was inserted, `raw` is copied.
    public func replaceLast(with raw: String) async -> InsertionOutcome {
        defer { last = nil }
        switch last {
        case .ax(let range?, let text):
            if env.secureInputEnabled() == false, await env.axReplace(range, text, raw) { return .inserted(.ax) }
            _ = pasteboard.write(text: raw, transient: false)
            return .copied
        case .ax(nil, _):
            _ = pasteboard.write(text: raw, transient: false)
            return .copied
        case .paste:
            if env.postUndo() { await env.sleep(.milliseconds(150)) }
            return await insert(raw)
        case .unverified, .copy, nil:
            _ = pasteboard.write(text: raw, transient: false)
            return .copied
        }
    }

    private func pasteViaPasteboard(_ text: String) -> Bool {
        restoreTask?.cancel()
        let saved = pasteboard.snapshot()
        let ours = pasteboard.write(text: text, transient: true)
        guard env.postPaste() else {
            pasteboard.restore(saved)
            return false
        }
        // Give the target app time to read the pasteboard, then put the user's clipboard back,
        // but only if nobody else has written to it in the meantime.
        restoreTask = Task { [pasteboard, env] in
            await env.sleep(Self.restoreDelay)
            if pasteboard.changeCount == ours { pasteboard.restore(saved) }
        }
        return true
    }

    /// Wait for a pending pasteboard restore (tests and shutdown).
    public func settle() async { await restoreTask?.value }
}
