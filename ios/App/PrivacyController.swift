import UIKit

/// The extra scene window also covers system sheets (such as ShareLink) before app-switcher capture.
@MainActor
final class PrivacyController {
    static let shared = PrivacyController()
    private var observers: [NSObjectProtocol] = []
    private var covers: [UIWindow] = []
    func start() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.cover() } })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.uncover() } })
    }
    private func cover() {
        guard covers.isEmpty else { return }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            let window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
            window.windowLevel = .alert + 1
            let controller = UIViewController()
            controller.view.backgroundColor = .systemBackground
            let label = UILabel()
            label.text = "Chirp"; label.font = .preferredFont(forTextStyle: .largeTitle)
            label.adjustsFontForContentSizeCategory = true; label.translatesAutoresizingMaskIntoConstraints = false
            controller.view.addSubview(label)
            NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor)])
            controller.view.accessibilityIdentifier = "privacyWindow"
            window.rootViewController = controller
            window.isUserInteractionEnabled = false
            window.isHidden = false // Never make key: preserve the editor's focus on return.
            covers.append(window)
        }
    }
    private func uncover() {
        for window in covers { window.isHidden = true }
        covers.removeAll()
    }
}
