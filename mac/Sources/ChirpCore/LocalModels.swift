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
    public var options: [LocalModelOption]?
    public var activeModels: [String: String]?
    public var restartRequired: Bool?
    public var choice: String?
    public var enableCorrection: Bool?

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
    public var busy: Bool { ["preparing", "downloading", "verifying", "cancelling"].contains(phase) }
    public var fraction: Double? {
        guard total > 0 else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }
    public var detail: String {
        switch phase {
        case "complete": return "Downloaded · Ready for offline use"
        case "preparing": return "Preparing download…"
        case "verifying": return "Checking that this model loads on your Mac…"
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
    public var options: [LocalModelOption] = []
    public var choices: [LocalModel: String] = [:]
    public var activeModels: [String: String] = [:]
    public var restartRequired = false
    public var catalogBusy = false
    public var correctionMode: String?
    public var correctionEnabled = false
    public var starting = false
    public var serverRunning = false
    public var errorMessage: String?
    public var message = "Checking the models on this Mac…"
    public init() {}

    public func option(_ kind: LocalModel) -> LocalModelOption? {
        options.first { $0.kind == kind && $0.id == choices[kind] }
    }

    public mutating func pick(_ kind: LocalModel, choice: String) {
        guard models[kind]?.busy != true else { return }
        choices[kind] = choice
        var row = LocalModelProgress()
        row.phase = option(kind)?.ready == true ? "complete" : "missing"
        models[kind] = row
    }

    public mutating func apply(_ event: LocalSetupEvent) {
        switch event.event {
        case "catalog":
            options = event.options ?? options
            activeModels = event.activeModels ?? activeModels
            restartRequired = event.restartRequired ?? restartRequired
            for kind in LocalModel.allCases {
                if choices[kind] == nil {
                    choices[kind] = options.first(where: { $0.kind == kind && $0.id == activeModels[kind.rawValue] })?.id ?? options.first(where: { $0.kind == kind })?.id
                }
                if models[kind]?.busy != true, let option = option(kind) {
                    if models[kind]?.phase == "error" { continue }
                    if option.ready { models[kind]?.phase = "complete" }
                    else if !["error", "cancelled"].contains(models[kind]?.phase ?? "") { models[kind]?.phase = "missing" }
                }
            }
            if restartRequired { message = "Selection saved. Apply and restart the server when you’re ready." }
        case "catalog_progress": message = event.message ?? message
        case "added":
            if let kind = event.model, let choice = event.choice, models[kind]?.busy != true { choices[kind] = choice; models[kind] = LocalModelProgress() }
        case "selected":
            if let kind = event.model { models[kind]?.phase = "complete" }
            restartRequired = true
            message = "Selection saved. Apply and restart the server when you’re ready."
        case "status":
            correctionMode = event.correctionMode
            serverRunning = event.serverRunning ?? false
            for model in event.models ?? [] where models[model.id]?.busy != true && choices[model.id] == nil {
                if model.ready { models[model.id]?.phase = "complete" }
                else if !["error", "cancelled"].contains(models[model.id]?.phase ?? "") { models[model.id]?.phase = "missing" }
            }
            message = errorMessage ?? (serverRunning ? "Server running · Ready to dictate" :
                models[.speech]?.ready == true ? "Start your local server to begin dictating." : "Download the speech model, then start your local server.")
        case "starting": starting = true; errorMessage = nil; message = "Starting the local server and loading speech recognition…"
        case "started": restartRequired = false; starting = false; errorMessage = nil; serverRunning = true; message = "Server running · Ready to dictate"
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

    /// A setup job exited. A helper that printed no events is too old for in-app setup (or rejected the arguments).
    public mutating func finish(_ action: String, model: LocalModel?, code: Int32, sawEvent: Bool, interrupted: Bool) {
        if action == "start" { starting = false }
        if ["refresh", "add"].contains(action) { catalogBusy = false }
        if !sawEvent {
            message = "Update chirp-server to use in-app model setup, then retry."
            if action != "status" { errorMessage = message }
        }
        guard ["download", "select"].contains(action), let model, models[model]?.ready != true else { return }
        var row = models[model] ?? LocalModelProgress()
        if code == 130 || interrupted { row.phase = "cancelled" }
        else if row.phase != "error" { row.phase = "error"; row.message = sawEvent ? "Download stopped. Retry to continue." : message }
        models[model] = row
    }
}

public struct LocalModelOption: Decodable, Sendable, Equatable {
    public let id: String
    public let kind: LocalModel
    public let title: String
    public let repository: String
    public let revision: String
    public let sizeBytes: Int64
    public let details: String
    public let license: String
    public let ready: Bool
    public let active: Bool
    public let latest: Bool?

    public init(id: String, kind: LocalModel, title: String, repository: String, revision: String,
                sizeBytes: Int64 = 0, details: String = "", license: String = "", ready: Bool = false, active: Bool = false, latest: Bool = false) {
        self.id = id; self.kind = kind; self.title = title; self.repository = repository; self.revision = revision
        self.sizeBytes = sizeBytes; self.details = details; self.license = license; self.ready = ready; self.active = active; self.latest = latest
    }

    public var label: String {
        let size = sizeBytes > 0 ? " · " + ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) : ""
        return title + size + (active ? " · Selected" : "") + (latest == true ? " · Latest checked" : "")
    }
}
