import AppKit

/// One pasteboard item as `type → data`.
public typealias PasteboardItem = [String: Data]

@MainActor
public protocol PasteboardClient {
    var changeCount: Int { get }
    func snapshot() -> [PasteboardItem]
    /// Writes `text` (optionally marked transient/concealed so clipboard managers skip it); returns the new change count.
    func write(text: String, transient: Bool) -> Int
    func restore(_ items: [PasteboardItem])
}

public enum PasteboardMarkers {
    public static let transient = "org.nspasteboard.TransientType"
    public static let concealed = "org.nspasteboard.ConcealedType"
}

@MainActor
public struct SystemPasteboard: PasteboardClient {
    public init() {}
    private var board: NSPasteboard { .general }

    public var changeCount: Int { board.changeCount }

    public func snapshot() -> [PasteboardItem] {
        (board.pasteboardItems ?? []).map { item in
            var out: PasteboardItem = [:]
            for type in item.types { if let d = item.data(forType: type) { out[type.rawValue] = d } }
            return out
        }
    }

    public func write(text: String, transient: Bool) -> Int {
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if transient {
            item.setData(Data(), forType: .init(PasteboardMarkers.transient))
            item.setData(Data(), forType: .init(PasteboardMarkers.concealed))
        }
        board.writeObjects([item])
        return board.changeCount
    }

    public func restore(_ items: [PasteboardItem]) {
        board.clearContents()
        let restored = items.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: .init(type)) }
            return item
        }
        if !restored.isEmpty { board.writeObjects(restored) }
    }
}
