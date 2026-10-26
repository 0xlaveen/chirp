import ChirpCore

/// Mac copy follows the configured address, so a remote Chirp server is never called this Mac.
public enum MacServerCopy {
    public static func place(local: Bool) -> String { local ? "this Mac" : "your Chirp server" }
    public static func update(local: Bool, to action: String) -> String {
        local ? "Update Chirp on this Mac to \(action)" : "Update your Chirp server to \(action)"
    }
}
