import AppKit
import ChirpCore
import ChirpUI

@MainActor
final class LocalModelsWindowController: NSObject {
    var onServerChanged: (() -> Void)? { get { session.onServerChanged } set { session.onServerChanged = newValue } }
    private var window: NSWindow?
    private var view: LocalModelsView?
    private lazy var session: LocalSetupSession = {
        let session = LocalSetupSession(host: .init(
            isLoopback: { settings.serverConfig().isLoopback },
            port: { settings.serverConfig().baseURL.port ?? 7821 },
            executable: { Self.executable() },
            correction: { settings.correction },
            enableCorrection: { settings.correction = true }))
        session.onChange = { [weak self] state in self?.view?.apply(state) }
        return session
    }()

    func stop() { session.stop() }

    func show() {
        guard settings.serverConfig().isLoopback else { return }
        if window == nil {
            let v = LocalModelsView()
            v.speechPicker.target = self; v.speechPicker.action = #selector(speechPicked(_:))
            v.cleanupPicker.target = self; v.cleanupPicker.action = #selector(cleanupPicked(_:))
            v.checkUpdates.target = self; v.checkUpdates.action = #selector(checkUpdatesPressed)
            v.addRepository.target = self; v.addRepository.action = #selector(addPressed)
            v.speech.target = self; v.speech.action = #selector(speechPressed)
            v.cleanup.target = self; v.cleanup.action = #selector(cleanupPressed)
            v.start.target = self; v.start.action = #selector(startPressed)
            v.correction.target = self; v.correction.action = #selector(correctionPressed(_:))
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: LocalModelsView.size),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Chirp Models"; w.contentView = v; w.isReleasedWhenClosed = false; w.center()
            view = v; window = w
        }
        session.refresh()
        session.run("status")
        NSApp.activate(); window?.makeKeyAndOrderFront(nil)
    }

    @objc private func speechPicked(_ sender: NSPopUpButton) { picked(.speech, sender) }
    @objc private func cleanupPicked(_ sender: NSPopUpButton) { picked(.cleanup, sender) }
    private func picked(_ model: LocalModel, _ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String else { return }
        session.pick(model, choice: id)
    }
    @objc private func checkUpdatesPressed() { session.checkUpdates() }
    @objc private func addPressed() {
        guard let view else { return }
        let repository = view.repository.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repository.isEmpty else { return }
        session.add(repository, model: view.repositoryKind.indexOfSelectedItem == 0 ? .speech : .cleanup)
    }
    @objc private func speechPressed() { session.download(.speech) }
    @objc private func cleanupPressed() { session.download(.cleanup) }
    @objc private func startPressed() { session.start() }
    @objc private func correctionPressed(_ sender: NSButton) {
        settings.correction = sender.state == .on
        session.refresh()
    }

    private static func executable() -> URL? {
        if let path = ProcessInfo.processInfo.environment["CHIRP_SERVER_EXECUTABLE"],
           path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [home.appendingPathComponent("Library/Application Support/Chirp/server/.venv/bin/chirp-server").path, "/run/current-system/sw/bin/chirp-server", home.appendingPathComponent(".local/bin/chirp-server").path,
                          home.appendingPathComponent(".local/share/chirp/src/server/.venv/bin/chirp-server").path]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/chirp-server" }
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }
}
