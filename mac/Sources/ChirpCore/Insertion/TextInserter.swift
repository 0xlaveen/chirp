import Foundation

/// The system calls insertion depends on, injectable so the strategy runs in tests.
@MainActor
public struct InsertionEnvironment {
    public var secureInputEnabled: () -> Bool
    public var axTrusted: () -> Bool
    public var frontmostBundleID: () -> String?
    /// Sets the focused element's selected text and verifies the value changed.
    public var axInsert: (String) async -> Bool
    /// Posts ⌘V. Returns false if the event could not be created.
    public var postPaste: () -> Bool
    public var sleep: (Duration) async -> Void

    public init(secureInputEnabled: @escaping () -> Bool, axTrusted: @escaping () -> Bool,
                frontmostBundleID: @escaping () -> String?, axInsert: @escaping (String) async -> Bool,
                postPaste: @escaping () -> Bool,
                sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.secureInputEnabled = secureInputEnabled
        self.axTrusted = axTrusted
        self.frontmostBundleID = frontmostBundleID
        self.axInsert = axInsert
        self.postPaste = postPaste
        self.sleep = sleep
    }
}

/// AX insert → paste (pasteboard saved and restored) → copy-only.
@MainActor
public final class TextInserter {
    public static let restoreDelay: Duration = .milliseconds(250)

    private let env: InsertionEnvironment
    private let pasteboard: PasteboardClient
    private var restoreTask: Task<Void, Never>?

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
                if await env.axInsert(text) { return .inserted(.ax) }
            case .paste:
                if pasteViaPasteboard(text) { return .inserted(.paste) }
            case .copy:
                _ = pasteboard.write(text: text, transient: false)
                return .copied
            }
        }
        return .copied
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
