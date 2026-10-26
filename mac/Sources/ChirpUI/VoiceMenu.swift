import ChirpCore
import SwiftUI

/// Live Notes voice profiles in the window (issue #18 M3): the "Maya?" suggestion beside a chip, and the chip menu's
/// Remember / Update / Yes / Not items. A name changes only when the user picks one.

/// This document's voice-profile view, by person (after merges). Empty while "Recognize saved voices" is off.
public struct SpeakerVoiceState: Equatable, Sendable {
    public var enabled = false
    /// A saved name Chirp thinks this person may be.
    public var suggestions: [Int: String] = [:]
    /// People confirmed as, or remembered into, a saved voice.
    public var linked: [Int: String] = [:]
    /// Named people with enough speech to remember.
    public var canRemember: Set<Int> = []
    /// Seconds of each person's voice heard so far.
    public var seconds: [Int: TimeInterval] = [:]
    /// The names of the saved voices, most recently updated first (the Name speakers sheet offers them first).
    public var saved: [String] = []

    public init(enabled: Bool = false) { self.enabled = enabled }
}

extension NotesSession {
    /// What the window shows about voices now.
    func voiceState() -> SpeakerVoiceState {
        guard voices.enabled else { return SpeakerVoiceState() }
        let document = recorder.document
        let prints = recorder.speakers?.voiceprints ?? [:]
        let heard = SpeakerVoices.personVoices(document, prints)
        var s = SpeakerVoiceState(enabled: true)
        s.saved = voices.profiles.sorted { $0.updated > $1.updated }.map(\.name)
        s.suggestions = voices.suggestions(document, prints).mapValues(\.name)
        for person in document.roster.active {
            if let profile = voices.link(person) { s.linked[person] = profile.name }
            s.seconds[person] = heard[person]?.seconds ?? 0
            if voices.canRemember(person, in: document, prints) { s.canRemember.insert(person) }
        }
        return s
    }

    func voicesChanged() {
        if !voices.enabled { recorder.speakers?.attachEmbedder(nil) }
        self.sync()
        onVoicesChange?()
    }

    /// The chip menu's voice items.
    func editVoices(_ edit: SpeakerEdit) {
        let document = recorder.document
        let prints = recorder.speakers?.voiceprints ?? [:]
        let heard = SpeakerVoices.personVoices(document, prints)
        switch edit {
        case .acceptVoice(let person):
            guard let profile = voices.suggestions(document, prints)[person] else { return }
            voices.accept(person, profile)
            editSpeakers(.rename(person, to: profile.name))
        case .declineVoice(let person):
            guard let profile = voices.suggestions(document, prints)[person] else { return }
            voices.decline(person, profile)
            self.sync()
        case .rememberVoice(let person):
            guard let name = document.roster.person(id: person)?.name, voices.canRemember(person, in: document, prints) else { return }
            (confirmRememberVoice ?? { _, done in done(false) })(name) { [weak self] agreed in
                guard let self, agreed else { return }
                let voice = SpeakerVoices.personVoices(self.recorder.document, self.recorder.speakers?.voiceprints ?? [:])[person]
                let saved = (try? self.voices.remember(person, name: name, voice: voice)) != nil
                self.notice(saved ? VoiceText.saved(name) : VoiceText.notSaved(name))
            }
        case .updateVoice(let person):
            guard let profile = voices.link(person) else { return }
            let updated = (try? voices.update(person, voice: heard[person])) != nil
            notice(updated ? VoiceText.updated(profile.name) : VoiceText.notSaved(profile.name))
        default: break
        }
    }

    private func notice(_ text: String) {
        chirpLog.info("\(VoiceLog.profiles(saved: self.voices.profiles.count, suggestions: self.model.voices.suggestions.count), privacy: .public)")
        model.speakerBanner = SpeakerBanner(document: recorder.document.id, kind: .notice(text))
        self.sync()
    }
}

/// The voice items' words.
public enum VoiceText {
    public static func saved(_ name: String) -> String { "Saved \(name)'s voice in this Mac's Keychain." }
    public static func updated(_ name: String) -> String { "Updated \(name)'s saved voice from this session." }
    public static func notSaved(_ name: String) -> String { "Could not save \(name)'s voice to the Keychain." }
    public static func remember(_ name: String) -> String { "Remember This Voice as “\(name)”…" }
    public static func needs(_ seconds: TimeInterval) -> String {
        "Needs \(Int(VoiceMatch.enrolSeconds)) s of their speech (\(Int(seconds)) s so far)"
    }
    public static let nameFirst = "Name this speaker to remember their voice"
    public static let consentTitle = "Remember this voice?"
    public static func consentDetail(_ name: String) -> String {
        "Chirp saves \(name)'s voiceprint (numbers, not audio) in this Mac's Keychain, and suggests their name when it hears them in Live Notes. It never leaves this Mac. Forget it any time in Settings › Notes."
    }
    public static let consentTick = "This person agreed to be recognised"
}

/// The chip menu's voice items (shown while "Recognize saved voices" is on).
struct VoiceMenuItems: View {
    let model: NotesModel
    let person: Int

    var body: some View {
        let v = model.voices
        if v.enabled {
            Divider()
            if let name = v.suggestions[person] {
                Button("Yes, This Is \(name)") { model.onSpeakerEdit(.acceptVoice(person)) }
                Button("Not \(name)") { model.onSpeakerEdit(.declineVoice(person)) }
            }
            if let name = v.linked[person] {
                Button("Update \(name)'s Saved Voice From This Session") { model.onSpeakerEdit(.updateVoice(person)) }
            } else if let name = model.document.roster.person(id: person)?.name {
                Button(VoiceText.remember(name)) { model.onSpeakerEdit(.rememberVoice(person)) }
                    .disabled(!v.canRemember.contains(person))
                if !v.canRemember.contains(person) { Text(VoiceText.needs(v.seconds[person] ?? 0)) }
            } else if v.suggestions[person] == nil {
                Text(VoiceText.nameFirst)
            }
        }
    }
}

/// "Maya?" beside a chip: a saved voice Chirp may have recognised. A click confirms it (renames, for this session).
struct VoiceSuggestionChip: View {
    let model: NotesModel
    let person: Int
    let name: String

    var body: some View {
        Button { model.onSpeakerEdit(.acceptVoice(person)) } label: {
            Text(name + "?")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Recognised from a saved voice. Click to name this speaker \(name).")
        .accessibilityLabel("Suggested name: \(name)")
        .accessibilityHint("Names this speaker \(name)")
    }
}
