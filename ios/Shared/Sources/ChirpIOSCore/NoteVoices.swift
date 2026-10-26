import ChirpCore
import Foundation

/// Per-open-note bookkeeping only. The server owns the library and every voiceprint.
public struct NoteVoiceState: Sendable {
    public var sources: [Int: VoiceSource] = [:]
    public var recognised: [Int: ServerVoiceMatch] = [:]
    public var linked: [Int: String] = [:]
    public var rejected: [Int: Set<String>] = [:]
    public var manual: Set<Int> = []
    public var pending: [Int: String] = [:]
    public var inFlight: Set<Int> = []
    public init() {}

    /// Called immediately after turns attach, before the recorder builds its structuring request.
    public mutating func receive(_ labels: ServerSpeakers, session: String, document: NotesDocument, enabled: Bool) -> [Int: String] {
        guard labels.error == nil, let generation = labels.generation else { return [:] }
        for turn in labels.turns {
            if let person = document.roster.existingPerson(forSlot: turn.speaker) {
                sources[person] = .note(session: session, generation: generation, speaker: turn.speaker)
            }
        }
        guard enabled else { return [:] }
        var names: [Int: String] = [:]
        for match in labels.matches ?? [] {
            guard let person = document.roster.existingPerson(forSlot: match.speaker),
                  !manual.contains(person), rejected[person]?.contains(match.voice) != true,
                  document.roster.person(id: person)?.name == nil || recognised[person] != nil else { continue }
            recognised[person] = match
            linked[person] = match.voice
            names[person] = match.name
        }
        return names
    }

    public mutating func name(_ person: Int, name: String?, remember: Bool) {
        manual.insert(person)
        recognised[person] = nil
        pending[person] = remember ? name : nil
    }

    public mutating func reject(_ person: Int) {
        if let match = recognised.removeValue(forKey: person) { rejected[person, default: []].insert(match.voice) }
        linked[person] = nil
        pending[person] = nil
        manual.remove(person)
    }
}

public enum SavedVoiceNotice {
    public static func error(_ error: any Error) -> String {
        switch error as? VoiceLibraryError {
        case .gone: "Record a little more with them, then try again"
        case .tooShort: "Name kept in this note. Chirp will remember the voice after 20 seconds of speech in this note."
        case .disabled: "Remember voices is off on your computer."
        case .full: "Your computer has 50 saved voices. Forget a voice before saving another."
        case .noVoice: "This voice was forgotten on another device. Refresh saved voices."
        case .unsupported: "Update Chirp on your computer to save voices"
        default: "Couldn’t update saved voices. Check your computer and try again."
        }
    }
}
