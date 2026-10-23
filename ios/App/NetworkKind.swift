import ChirpIOSCore
import Foundation
import Network

/// The kind of network the device is on, for content-free session timings: never an address, name or SSID.
final class NetworkKind: @unchecked Sendable {
    static let shared = NetworkKind()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var path: NWPath?
    private init() {
        monitor.pathUpdateHandler = { [weak self] path in self?.lock.withLock { self?.path = path } }
        monitor.start(queue: DispatchQueue(label: "dev.chirp.network-kind"))
    }
    var current: SessionTiming.Network {
        lock.withLock {
            guard let path, path.status == .satisfied else { return .none }
            if path.usesInterfaceType(.wifi) { return .wifi }
            if path.usesInterfaceType(.cellular) { return .cellular }
            if path.usesInterfaceType(.wiredEthernet) { return .wired }
            return .other
        }
    }
}
