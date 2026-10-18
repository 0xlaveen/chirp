import Foundation
import ChirpIOSCore

/// This client has no audio, URLSession or credentials/network logic.
@MainActor
final class KeyboardBridgeClient {
    private let bridge: SharedBridge
    private let signal = DarwinSignal(name: DarwinSignal.bridgeChanged)
    private var observation: DarwinObservation?
    var onChange: (() -> Void)?

    init() throws {
        let configuration = SharedConfiguration(bundle: .main)
        bridge = try SharedBridge(root: configuration.containerURL(),
                                  secrets: KeychainSecretStore(accessGroup: configuration.keychainAccessGroup),
                                  role: .keyboard)
        observation = signal.observe { [weak self] in
            Task { @MainActor [weak self] in self?.onChange?() }
        }
    }

    func state() throws -> BridgeState? { try bridge.state() }

    func send(_ action: BridgeAction, state: BridgeState, utteranceID: UUID? = nil) throws {
        let now = Date()
        guard state.leaseUntil > now else { throw ClientError.expired }
        try bridge.send(BridgeCommand(generation: state.generation, utteranceID: utteranceID,
                                      action: action, createdAt: now,
                                      expiresAt: min(state.leaseUntil, now.addingTimeInterval(5))))
        signal.post()
    }

    func results(generation: UUID, utteranceID: UUID) throws -> [BridgeResult] {
        try bridge.takeResults(generation: generation, utteranceID: utteranceID)
    }

    enum ClientError: Error { case expired }
}
