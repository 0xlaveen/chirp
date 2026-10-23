import AppKit
import ChirpCore
import ChirpUI

/// Pair a Phone: checks Tailscale Serve, offers the publish command, and shows the pairing QR code. The code is a
/// secret: the window is left out of screenshots and screen sharing, blurs while Chirp is in the background, hides
/// itself after two minutes, and nothing about it is logged or sent to Notification Center.
@MainActor
final class PairingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var view: PairingView?
    private let timer = PairingTimer()
    private var observers: [NSObjectProtocol] = []
    private var checkTask: Task<Void, Never>?
    private var clipboardTask: Task<Void, Never>?
    /// A token was minted for a new phone: Settings → Devices lists it.
    var onPaired: (() -> Void)?
    private lazy var flow: PairingFlow = {
        let flow = PairingFlow(serverURL: { settings.serverConfig().baseURL }, run: TailscaleCLI.run,
                               deviceLinks: { DeviceTokenPairing(name: $0, store: PairedDevices.store) },
                               suggestedName: { DeviceName.suggested(macName: Host.current().localizedName) })
        flow.onChange = { [weak self] in self?.stepChanged() }
        return flow
    }()

    func show() {
        if window == nil {
            let v = PairingView()
            v.action.target = self
            v.action.action = #selector(actionPressed)
            v.copyLink.target = self
            v.copyLink.action = #selector(copyPressed)
            v.nameField.target = self
            v.nameField.action = #selector(actionPressed)
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Pair a Phone"
            w.isReleasedWhenClosed = false
            w.sharingType = .none
            w.isExcludedFromWindowsMenu = true
            w.contentView = v
            w.delegate = self
            view = v
            window = w
            timer.onTick = { [weak self] _ in self?.refresh() }
            timer.onExpire = { [weak self] in self?.window?.close() }
        }
        if observers.isEmpty {
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                },
                center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                },
            ]
        }
        NSApp.activate()
        if window?.isVisible != true {
            window?.center()
            check()
        }
        window?.makeKeyAndOrderFront(nil)
    }

    private func check() {
        checkTask?.cancel()
        checkTask = Task { [flow] in await flow.begin() }
    }

    private func stepChanged() {
        if case .ready = flow.step {
            if !timer.isRunning { timer.start(); onPaired?() }
        } else {
            timer.cancel()
        }
        refresh()
    }

    private func refresh() {
        guard let view, let window else { return }
        view.apply(flow.step, remaining: timer.remaining, concealed: !NSApp.isActive)
        window.setContentSize(view.fittingSize)
    }

    func windowWillClose(_ notification: Notification) {
        timer.cancel()
        checkTask?.cancel()
        flow.reset()
        view?.forget()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
    }

    @objc private func actionPressed() {
        switch flow.step {
        case .notServed(let command), .publishFailed(let command, _): confirmPublish(command)
        case .naming:
            let name = view?.nameField.stringValue ?? ""
            checkTask?.cancel()
            checkTask = Task { [flow] in await flow.pair(named: name) }
        case .cannotMint, .noToken, .failed:
            checkTask?.cancel()
            checkTask = Task { [flow] in await flow.check() }
        default: check()
        }
    }

    /// The command runs only after the user agrees to exactly what is shown.
    private func confirmPublish(_ command: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Publish Chirp on your tailnet?"
        alert.informativeText = """
            Chirp will run:

            \(command)

            Devices on your tailnet can then reach this Mac’s chirp-server; they still need the pairing code to use it. \
            It is never put on the public internet. Undo it with \(TailscaleServe.undoCommand).
            """
        alert.addButton(withTitle: "Run Command")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.checkTask?.cancel()
            self.checkTask = Task { [flow = self.flow] in await flow.publish() }
        }
    }

    /// Copies the link only after a warning, marked so clipboard managers skip it, and clears it after two minutes
    /// unless something else was copied since.
    @objc private func copyPressed() {
        guard let window, case .ready(let link) = flow.step else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Copy the pairing link?"
        alert.informativeText = "Anyone with this link can use your Chirp server. Paste it only into Chirp on your phone, never into chat, notes or email. Chirp clears it from the clipboard after 2 minutes."
        alert.addButton(withTitle: "Copy Link")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, self.flow.step == .ready(link) else { return }
            let board = SystemPasteboard()
            let copied = board.write(text: link.uri, transient: true)
            self.clipboardTask?.cancel()
            self.clipboardTask = Task {
                try? await Task.sleep(for: .seconds(PairingTimer.lifetime))
                guard !Task.isCancelled, board.changeCount == copied else { return }
                NSPasteboard.general.clearContents()
            }
        }
    }
}

/// Runs the Tailscale CLI with a deadline. Output is read as it arrives (a full pipe would stall the CLI); the result
/// is returned once the process exits and both pipes close, or shortly after exit if a child still holds them.
enum TailscaleCLI {
    private final class Run: @unchecked Sendable {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        private let lock = NSLock()
        private var out = Data()
        private var err = Data()
        private var outOpen = true
        private var errOpen = true
        private var exited = false
        private var timedOut = false
        private var continuation: CheckedContinuation<CommandResult, Never>?

        init(_ continuation: CheckedContinuation<CommandResult, Never>) { self.continuation = continuation }

        func append(_ data: Data, error isError: Bool) {
            lock.withLock {
                if data.isEmpty {
                    if isError { errOpen = false } else { outOpen = false }
                } else if isError { err.append(data) } else { out.append(data) }
            }
            if data.isEmpty { (isError ? error : output).fileHandleForReading.readabilityHandler = nil }
            finishIfDone()
        }

        func exit() {
            lock.withLock { exited = true }
            finishIfDone()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { self.finish() }
        }

        func timeOut() {
            guard process.isRunning else { return }
            lock.withLock { timedOut = true }
            process.terminate()
        }

        private func finishIfDone() {
            if lock.withLock({ exited && !outOpen && !errOpen }) { finish() }
        }

        func finish(failure: String? = nil) {
            let (c, result): (CheckedContinuation<CommandResult, Never>?, CommandResult) = lock.withLock {
                let c = continuation
                continuation = nil
                let status: Int32 = failure != nil ? 127 : timedOut ? -1 : process.terminationStatus
                return (c, CommandResult(status: status, output: out, error: failure ?? String(decoding: err, as: UTF8.self)))
            }
            guard let c else { return }
            output.fileHandleForReading.readabilityHandler = nil
            error.fileHandleForReading.readabilityHandler = nil
            c.resume(returning: result)
        }
    }

    static let run: CommandRunner = { executable, arguments, timeout in
        await withCheckedContinuation { continuation in
            let run = Run(continuation)
            run.process.executableURL = executable
            run.process.arguments = arguments
            run.process.standardOutput = run.output
            run.process.standardError = run.error
            run.process.standardInput = FileHandle.nullDevice
            run.output.fileHandleForReading.readabilityHandler = { run.append($0.availableData, error: false) }
            run.error.fileHandleForReading.readabilityHandler = { run.append($0.availableData, error: true) }
            run.process.terminationHandler = { _ in run.exit() }
            do { try run.process.run() } catch {
                run.finish(failure: "Couldn’t run Tailscale: \(error.localizedDescription)")
                return
            }
            let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { run.timeOut() }
        }
    }
}
