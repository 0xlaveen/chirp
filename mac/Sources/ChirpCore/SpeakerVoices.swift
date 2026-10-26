import Foundation

/// Injectable server library. The app resolves its current server for every request; tests use an in-memory server.
public struct VoiceLibraryClient: Sendable {
    public var list: @Sendable () async throws -> SavedVoices
    public var action: @Sendable (VoiceLibraryAction) async throws -> SavedVoices
    public var identify: @Sendable ([VoiceClip]) async throws -> [IdentifiedVoice]
    public var prepare: @Sendable () async throws -> Void

    public init(list: @escaping @Sendable () async throws -> SavedVoices,
                action: @escaping @Sendable (VoiceLibraryAction) async throws -> SavedVoices,
                identify: @escaping @Sendable ([VoiceClip]) async throws -> [IdentifiedVoice],
                prepare: @escaping @Sendable () async throws -> Void = {}) {
        self.list = list; self.action = action; self.identify = identify; self.prepare = prepare
    }

    public static let unavailable = VoiceLibraryClient(list: { throw VoiceLibraryError.unsupported },
        action: { _ in throw VoiceLibraryError.unsupported }, identify: { _ in throw VoiceLibraryError.unsupported })
}

/// The server is the only saved-voice library. Clips and document links stay in memory; errors never carry server text.
@MainActor
public final class SpeakerVoices {
    public private(set) var supported = false
    public private(set) var enabled = false
    public private(set) var profiles: [SavedVoice] = []
    public private(set) var error: String?
    public private(set) var busy = false
    public private(set) var links: [Int: String] = [:]
    public private(set) var recognised: Set<Int> = []
    public var onChange: () -> Void = {}
    public var beforeRemember: (String) async -> Bool = { _ in true }
    private let client: VoiceLibraryClient
    private let legacy: VoiceProfileStore
    private let imported: (UUID) -> Bool
    private let acknowledgeImport: (UUID) -> Void
    private var savedVoice: String?
    private var epoch = UUID()
    private var documentEpoch = UUID()
    private var server = ""
    private var declined: [Int: Set<String>] = [:]
    private var attempted: [Int: Int] = [:]
    private var pending: [Int: String] = [:]
    private var revisions: [Int: Int] = [:]
    private var processing = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if busy { await withCheckedContinuation { waiters.append($0) } } else { busy = true }
        onChange()
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        onChange()
    }

    public init(client: VoiceLibraryClient, legacy: VoiceProfileStore = MemoryVoiceProfileStore(),
                imported: @escaping (UUID) -> Bool = { _ in false }, acknowledgeImport: @escaping (UUID) -> Void = { _ in }) {
        self.client = client; self.legacy = legacy
        self.imported = imported; self.acknowledgeImport = acknowledgeImport
    }

    /// Invalidates in-flight work before changing servers or losing the capability. Never reuses another server's list.
    public func configure(supported: Bool, server: String) {
        guard self.supported != supported || self.server != server else { return }
        self.supported = supported; self.server = server
        epoch = UUID(); profiles = []; enabled = false; error = nil
        reset(); onChange()
    }

    private func apply(_ result: SavedVoices) {
        enabled = result.enabled; profiles = result.voices
        let ids = Set(profiles.map(\.id))
        links = links.filter { ids.contains($0.value) }
        recognised = recognised.intersection(Set(links.keys))
        if !enabled { pending = [:] }
        error = nil
    }

    /// Refresh on health/Settings/Record, then move each legacy item only after the server acknowledges its import.
    /// Persist acknowledgements before deletion so a Keychain deletion failure is retried without importing again.
    public func refresh() async {
        guard supported, !busy else { return }
        let version = epoch
        await acquire()
        defer { release() }
        do {
            let result = try await client.list()
            guard version == epoch else { return }
            apply(result)
            if enabled {
                for old in try legacy.load() {
                    if imported(old.id) { try legacy.delete(old.id); continue }
                    let imported = try await client.action(.importVoice(name: old.name, embedding: old.embedding,
                        seconds: old.seconds, model: old.model))
                    acknowledgeImport(old.id)
                    try legacy.delete(old.id)
                    guard version == epoch else { return }
                    apply(imported)
                }
            }
        } catch { if version == epoch { self.error = "Couldn’t load saved voices. Try again." } }
    }

    @discardableResult
    public func perform(_ action: VoiceLibraryAction) async -> Bool {
        guard supported else { return false }
        let version = epoch
        await acquire()
        defer { release() }
        guard version == epoch, supported else { return false }
        error = nil
        do {
            if case .remember = action { try await client.prepare() }
            guard version == epoch else { return false }
            let result = try await client.action(action)
            guard version == epoch else { return false }
            apply(result)
            savedVoice = result.voice?.id
            return true
        } catch {
            if version == epoch {
                self.error = "Couldn’t update saved voices. Try again."
                if error as? VoiceLibraryError == .disabled { enabled = false; pending = [:] }
            }
            return false
        }
    }

    public func reset() {
        documentEpoch = UUID(); links = [:]; recognised = []; declined = [:]; attempted = [:]; pending = [:]; revisions = [:]
    }

    public func link(_ person: Int) -> SavedVoice? {
        guard let id = links[person] else { return nil }
        return profiles.first { $0.id == id }
    }

    /// A rename opts in by default, including a name given before 20 seconds. An unticked row cancels its pending save.
    public func name(_ person: Int, _ name: String?, remember: Bool = true) {
        revisions[person, default: 0] += 1
        recognised.remove(person)
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        pending[person] = enabled && remember && SavedVoice.isValidName(name) ? name : nil
    }

    public func decline(_ person: Int) {
        revisions[person, default: 0] += 1
        if let id = links.removeValue(forKey: person) { declined[person, default: []].insert(id) }
        pending[person] = nil
        recognised.remove(person)
        onChange()
    }

    /// Combines slots only after resolving this note's merges, retaining at most 30 seconds per person.
    public static func personClips(_ document: NotesDocument, _ clips: [Int: Data]) -> [Int: Data] {
        var out: [Int: Data] = [:]
        for slot in clips.keys.sorted() {
            guard let person = document.roster.existingPerson(forSlot: slot), let pcm = clips[slot] else { continue }
            out[person, default: Data()].append(pcm)
            out[person] = Data(out[person]!.suffix(VoiceClip.maxBytes))
        }
        return out
    }

    public static func seconds(_ pcm: Data) -> Double { Double(pcm.count) / 32_000 }

    public func hasWork(_ document: NotesDocument, clips: [Int: Data]) -> Bool {
        guard supported, enabled, !processing, !busy else { return false }
        let heard = Self.personClips(document, clips)
        return heard.contains { person, pcm in
            let seconds = Self.seconds(pcm)
            if let name = pending[person], document.roster.person(id: person)?.name == name,
               seconds >= VoiceMatch.enrolSeconds { return true }
            guard !profiles.isEmpty, document.roster.person(id: person)?.name == nil, links[person] == nil else { return false }
            let stage = seconds >= 30 ? 2 : seconds >= VoiceMatch.minSeconds ? 1 : 0
            return stage > attempted[person, default: 0]
        }
    }

    /// Called as settled turns arrive. Each unnamed person is identified at 10 s, then once more at 30 s.
    /// Names edited while a request runs take precedence in the caller. Rejected identities stay rejected for this note.
    public func process(_ document: NotesDocument, clips: [Int: Data]) async -> [IdentifiedVoice] {
        guard supported, enabled, !processing, !busy else { return [] }
        processing = true
        defer { processing = false }
        let version = epoch, note = documentEpoch, originalRevisions = revisions
        let heard = Self.personClips(document, clips)
        for (person, name) in pending.sorted(by: { $0.key < $1.key }) {
            guard let pcm = heard[person], Self.seconds(pcm) >= VoiceMatch.enrolSeconds,
                  document.roster.person(id: person)?.name == name else { continue }
            let agreed = await beforeRemember(name)
            guard version == epoch, note == documentEpoch, enabled else { return [] }
            guard agreed else { pending[person] = nil; continue }
            guard pending[person] == name else { continue }
            let saved = await perform(.remember(name: name, from: .audio(pcm), voice: links[person]))
            guard version == epoch, note == documentEpoch else { return [] }
            if saved {
                if let id = savedVoice { links[person] = id }
                if pending[person] == name { pending[person] = nil }
            } else {
                // Explicitly retry from the menu; never spin on a failed endpoint from onChange.
                pending[person] = nil
            }
        }
        guard !profiles.isEmpty else { return [] }
        var requests: [VoiceClip] = []
        for (person, pcm) in heard.sorted(by: { $0.key < $1.key }) {
            guard document.roster.person(id: person)?.name == nil, links[person] == nil else { continue }
            let seconds = Self.seconds(pcm), prior = attempted[person] ?? 0
            let stage = seconds >= 30 ? 2 : seconds >= VoiceMatch.minSeconds ? 1 : 0
            guard stage > prior else { continue }
            attempted[person] = stage
            requests.append(VoiceClip(person: person, pcm: pcm))
        }
        guard !requests.isEmpty, !profiles.isEmpty, enabled else { return [] }
        do {
            try await client.prepare()
            guard version == epoch, note == documentEpoch, enabled else { return [] }
            let matches = try await client.identify(requests)
            guard version == epoch, note == documentEpoch, enabled else { return [] }
            var used = Set(links.values), people = Set<Int>()
            return matches.filter { match in
                guard revisions[match.person, default: 0] == originalRevisions[match.person, default: 0],
                      requests.contains(where: { $0.person == match.person }), SavedVoice.isValidID(match.voice),
                      SavedVoice.isValidName(match.name), declined[match.person]?.contains(match.voice) != true,
                      profiles.contains(where: { $0.id == match.voice && $0.compatible }),
                      !used.contains(match.voice), people.insert(match.person).inserted else { return false }
                used.insert(match.voice)
                return true
            }
        } catch {
            if version == epoch, note == documentEpoch {
                self.error = "Couldn’t recognise saved voices. Try again on the next recording."
            }
            return []
        }
    }

    public func accept(_ match: IdentifiedVoice) { links[match.person] = match.voice; recognised.insert(match.person) }
}
