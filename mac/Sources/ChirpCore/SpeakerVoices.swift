import Foundation

/// Live Notes' voice-profile policy (issue #18 M3): the Settings switch (off by default), consent before the one model
/// download, offline loads for Record, the saved profiles, and this document's suggestions and links. A suggestion
/// is only ever shown; a name changes only when the user confirms it. The switch is the one stored preference;
/// everything else of a session is memory only.
@MainActor
public final class SpeakerVoices {
    public enum Prompt: Equatable, Sendable {
        case download(size: String)
        case redownload(size: String)
    }

    public enum Failure: Error, Equatable {
        /// Remember needs a name and `VoiceMatch.enrolSeconds` of this person's speech.
        case notEnough
        case keychain
    }

    public private(set) var enabled: Bool
    public private(set) var model: SpeakerModelState
    /// Saved profiles, oldest first.
    public private(set) var profiles: [VoiceProfile] = []
    public var onChange: () -> Void = {}
    public var confirm: (_ prompt: Prompt, _ done: @escaping (Bool) -> Void) -> Void = { _, done in done(false) }

    private let modelStore: VoiceModelStore
    private let profileStore: VoiceProfileStore
    private let onPreference: (Bool) -> Void
    private var embedder: (any VoiceEmbedder)?
    private var loadTask: Task<(any VoiceEmbedder)?, Never>?
    /// This document: people confirmed as (or remembered into) a profile, and suggestions turned down.
    public private(set) var links: [Int: UUID] = [:]
    private var declined: [Int: Set<UUID>] = [:]

    public init(modelStore: VoiceModelStore, profileStore: VoiceProfileStore, enabled: Bool, onPreference: @escaping (Bool) -> Void) {
        self.modelStore = modelStore
        self.profileStore = profileStore
        self.onPreference = onPreference
        let downloaded = modelStore.isDownloaded()
        self.enabled = enabled && downloaded
        model = downloaded ? .ready : .notDownloaded
        if enabled && !downloaded { onPreference(false) }
        profiles = (try? profileStore.load()) ?? []
    }

    public var modelID: String { modelStore.modelID }
    public var sizeText: String { modelStore.sizeText }
    public var needsLoad: Bool { enabled && embedder == nil }
    public var isLoading: Bool { loadTask != nil }
    public func isCompatible(_ profile: VoiceProfile) -> Bool { profile.model == modelID }

    // MARK: the switch

    /// Settings' "Recognize saved voices". On asks before any download. Off stops recognising; whether to forget the
    /// saved voices too is the caller's question (`forgetAll`).
    public func setEnabled(_ on: Bool) {
        guard on else {
            if model.isDownloading { loadTask?.cancel() }
            setPreference(false)
            embedder = nil
            onChange()
            return
        }
        guard loadTask == nil else { return }
        if model.isFailure, modelStore.hasFiles() {
            confirm(.redownload(size: modelStore.sizeText)) { [weak self] yes in
                guard let self, yes else { return }
                try? self.modelStore.remove()
                Task { await self.download() }
            }
        } else if modelStore.isDownloaded() {
            if model.isFailure { model = .ready }
            setPreference(true)
            onChange()
        } else {
            confirm(.download(size: modelStore.sizeText)) { [weak self] yes in
                guard let self, yes else { return }
                Task { await self.download() }
            }
        }
    }

    private func download() async {
        guard await load(download: true) != nil else { return }
        setPreference(true)
        onChange()
    }

    /// Record: the embedder, loaded offline if needed; nil when off. A model gone from disk turns the switch off.
    public func prepare() async -> (any VoiceEmbedder)? {
        guard enabled else { return nil }
        if let embedder { return embedder }
        guard modelStore.isDownloaded() else {
            setPreference(false)
            model = .notDownloaded
            onChange()
            return nil
        }
        return await load(download: false)
    }

    /// The loaded embedder, without waiting.
    public var readyEmbedder: (any VoiceEmbedder)? { enabled ? embedder : nil }

    /// Settings › Remove (the voice model; saved profiles stay). Refused while a load runs.
    @discardableResult
    public func removeModel() -> Bool {
        guard loadTask == nil else { return false }
        embedder = nil
        try? modelStore.remove()
        setPreference(false)
        model = modelStore.isDownloaded() ? .ready : .notDownloaded
        onChange()
        return true
    }

    public var canRemoveModel: Bool { loadTask == nil && modelStore.hasFiles() }

    private func load(download: Bool) async -> (any VoiceEmbedder)? {
        if let loadTask { return await loadTask.value }
        model = download ? .downloading(0) : .loading
        onChange()
        let store = modelStore
        let task = Task { () -> (any VoiceEmbedder)? in
            try? await store.load(download: download, progress: { fraction in
                Task { @MainActor [weak self] in
                    guard let self, self.model.isDownloading else { return }
                    self.model = .downloading(min(max(fraction, 0), 0.99))
                    self.onChange()
                }
            })
        }
        loadTask = task
        let loaded = await task.value
        loadTask = nil
        if let loaded {
            embedder = loaded
            model = .ready
        } else if task.isCancelled {
            model = modelStore.isDownloaded() ? .ready : .notDownloaded
        } else {
            model = .failed(download ? "the download failed" : "the model did not load")
            setPreference(false)
        }
        onChange()
        return loaded
    }

    private func setPreference(_ on: Bool) {
        enabled = on
        onPreference(on)
    }

    // MARK: this document

    /// New: forget this document's links and declined suggestions.
    public func reset() {
        links = [:]
        declined = [:]
    }

    /// Each person's voice in `document` (after merges): the voiceprints of the diarizer slots that speak as them.
    public static func personVoices(_ document: NotesDocument, _ prints: [Int: Voiceprint]) -> [Int: Voiceprint] {
        var out: [Int: Voiceprint] = [:]
        for (slot, print) in prints {
            guard let person = document.roster.existingPerson(forSlot: slot) else { continue }
            out[person, default: Voiceprint()].add(print)
        }
        return out
    }

    /// The profile each unnamed, unlinked person may be: never one already linked, or one this person turned down.
    public func suggestions(_ document: NotesDocument, _ prints: [Int: Voiceprint]) -> [Int: VoiceProfile] {
        guard enabled else { return [:] }
        let roster = document.roster
        let linked = Set(links.values)
        let voices = Self.personVoices(document, prints).filter { person, _ in
            roster.person(id: person)?.name == nil && link(person) == nil
        }
        var out: [Int: VoiceProfile] = [:]
        for (person, id) in VoiceMatch.suggest(voices, profiles: profiles.filter { !linked.contains($0.id) }, model: modelID) {
            guard declined[person]?.contains(id) != true, let p = profiles.first(where: { $0.id == id }) else { continue }
            out[person] = p
        }
        return out
    }

    /// The profile `person` is linked to (after merges), if it is still saved.
    public func link(_ person: Int) -> VoiceProfile? {
        guard let id = links[person] else { return nil }
        return profiles.first { $0.id == id }
    }

    /// "Yes, it's Maya": links the person (the caller renames them).
    public func accept(_ person: Int, _ profile: VoiceProfile) { links[person] = profile.id }

    public func decline(_ person: Int, _ profile: VoiceProfile) { declined[person, default: []].insert(profile.id) }

    /// Whether `person` can be remembered now: named, unlinked, with enough speech.
    public func canRemember(_ person: Int, in document: NotesDocument, _ prints: [Int: Voiceprint]) -> Bool {
        enabled && embedder != nil && document.roster.person(id: person)?.name != nil && link(person) == nil
            && (Self.personVoices(document, prints)[person]?.seconds ?? 0) >= VoiceMatch.enrolSeconds
    }

    /// "Remember this voice as Maya", after the consent tick: saves one profile (Keychain) and links the person.
    @discardableResult
    public func remember(_ person: Int, name: String, voice: Voiceprint?, now: Date = Date()) throws -> VoiceProfile {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard enabled, !name.isEmpty, let voice, voice.seconds >= VoiceMatch.enrolSeconds else { throw Failure.notEnough }
        let profile = VoiceProfile(name: name, embedding: voice.centroid, model: modelID, seconds: voice.seconds, created: now)
        do { try profileStore.save(profile) } catch { throw Failure.keychain }
        profiles.append(profile)
        links[person] = profile.id
        onChange()
        return profile
    }

    /// "Update Maya's voice from this session": the saved voice becomes the speech-weighted mean of what it had and
    /// this session's. Only ever on the user's say-so.
    @discardableResult
    public func update(_ person: Int, voice: Voiceprint?, now: Date = Date()) throws -> VoiceProfile {
        guard var profile = link(person), isCompatible(profile), let voice, voice.seconds > 0 else { throw Failure.notEnough }
        var merged = Voiceprint()
        merged.add(profile.embedding, seconds: profile.seconds)
        merged.add(voice)
        profile.embedding = merged.centroid
        profile.seconds = merged.seconds
        profile.updated = now
        do { try profileStore.save(profile) } catch { throw Failure.keychain }
        profiles[profiles.firstIndex { $0.id == profile.id }!] = profile
        onChange()
        return profile
    }

    /// Settings › Forget.
    public func forget(_ id: UUID) {
        try? profileStore.delete(id)
        profiles.removeAll { $0.id == id }
        links = links.filter { $0.value != id }
        onChange()
    }

    /// Settings › Forget all voices, or turning the switch off with "Forget".
    public func forgetAll() {
        try? profileStore.deleteAll()
        profiles = (try? profileStore.load()) ?? []
        links = [:]
        onChange()
    }

    /// Profiles from another embedding model: shown as needing to be saved again, never compared.
    public var incompatibleCount: Int { profiles.filter { !isCompatible($0) }.count }
}
