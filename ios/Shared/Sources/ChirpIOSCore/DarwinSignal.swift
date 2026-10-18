import Foundation
import CoreFoundation
import Darwin

public final class DarwinObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var cleanup: (@Sendable () -> Void)?
    init(_ cleanup: @escaping @Sendable () -> Void) { self.cleanup = cleanup }
    public func cancel() { lock.withLock { cleanup?(); cleanup = nil } }
    deinit { cancel() }
}

public struct DarwinSignal: Sendable {
    public static let bridgeChanged = "dev.chirp.ios.bridge.changed"
    public let name: String
    public init(name: String) { self.name = name }
    public func post() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(name as CFString), nil, nil, true)
    }
    /// Darwin notifications carry no payload. Handler must reread the mailbox; retain the returned token.
    public func observe(_ handler: @escaping @Sendable () -> Void) -> DarwinObservation {
        // notify(3) owns callback lifetime, avoiding an unretained CF observer pointer racing cancellation.
        var token: Int32 = 0
        let status = notify_register_dispatch(name, &token, .global(qos: .userInitiated)) { _ in handler() }
        guard status == NOTIFY_STATUS_OK else { return DarwinObservation({}) }
        let registered = token
        return DarwinObservation { notify_cancel(registered) }
    }
}
