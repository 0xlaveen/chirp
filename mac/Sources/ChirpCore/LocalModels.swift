import Foundation

public enum LocalModel: String, Codable, CaseIterable, Sendable {
    case speech, cleanup
    public var title: String { self == .speech ? "Speech recognition" : "Local correction" }
    public var subtitle: String { self == .speech ? "Parakeet · English dictation" : "Qwen · Polishes your words on this Mac" }
}

/// The local helper's JSON-lines protocol. It never carries a token, audio or a transcript.
public struct LocalSetupEvent: Decodable, Sendable {
    public struct Model: Decodable, Sendable {
        public let id: LocalModel
        public let title: String
        public let ready: Bool
    }
    public let event: String
    public var model: LocalModel?
    public var phase: String?
    public var completedBytes: Int64?
    public var totalBytes: Int64?
    public var message: String?
    public var models: [Model]?
    public var correctionMode: String?
    public var serverRunning: Bool?

    public static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Self.self, from: data)
    }
}

public struct LocalModelProgress: Equatable, Sendable {
    public var phase = "missing"
    public var completed: Int64 = 0
    public var total: Int64 = 0
    public var message: String?
    public init() {}
    public var ready: Bool { phase == "complete" }
    public var busy: Bool { ["preparing", "downloading", "cancelling"].contains(phase) }
    public var fraction: Double? {
        guard total > 0 else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }
    public var detail: String {
        switch phase {
        case "complete": return "Downloaded · Ready for offline use"
        case "preparing": return "Preparing download…"
        case "downloading":
            guard let fraction else { return "Downloading…" }
            let received = ByteCountFormatter.string(fromByteCount: max(0, completed), countStyle: .file)
            let size = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            return "\(Int(fraction * 100))% · \(received) of \(size)"
        case "cancelled": return "Paused · Resume to continue downloading"
        case "cancelling": return "Pausing… Your downloaded data will be kept."
        case "error": return message ?? "Download interrupted. Retry to continue."
        default: return "Not downloaded"
        }
    }
}

public struct LocalModelsState: Sendable {
    public var models = Dictionary(uniqueKeysWithValues: LocalModel.allCases.map { ($0, LocalModelProgress()) })
    public var correctionMode: String?
    public var correctionEnabled = false
    public var starting = false
    public var serverRunning = false
    public var errorMessage: String?
    public var message = "Checking the models on this Mac…"
    public init() {}

    public mutating func apply(_ event: LocalSetupEvent) {
        switch event.event {
        case "status":
            correctionMode = event.correctionMode
            serverRunning = event.serverRunning ?? false
            for model in event.models ?? [] where models[model.id]?.busy != true {
                if model.ready { models[model.id]?.phase = "complete" }
                else if !["error", "cancelled"].contains(models[model.id]?.phase ?? "") { models[model.id]?.phase = "missing" }
            }
            message = errorMessage ?? (serverRunning ? "Server running · Ready to dictate" :
                models[.speech]?.ready == true ? "Start your local server to begin dictating." : "Download the speech model, then start your local server.")
        case "starting": starting = true; errorMessage = nil; message = "Starting the local server and loading speech recognition…"
        case "started": starting = false; errorMessage = nil; serverRunning = true; message = "Server running · Ready to dictate"
        default:
            guard let model = event.model else {
                if let message = event.message { self.message = message; errorMessage = message; starting = false }
                return
            }
            var row = models[model] ?? LocalModelProgress()
            row.phase = event.event == "progress" ? event.phase ?? "preparing" : event.event
            row.completed = event.completedBytes ?? row.completed
            row.total = event.totalBytes ?? row.total
            row.message = event.message
            models[model] = row
        }
    }
}
