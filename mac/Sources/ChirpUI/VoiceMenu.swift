import ChirpCore
import SwiftUI

/// Saved names are applied automatically. The checkmark distinguishes recognition from a name typed in this note.
public struct SpeakerVoiceState: Equatable, Sendable {
    public var enabled = false
    public var linked: [Int: String] = [:]
    public var recognised: Set<Int> = []
    public var canRemember: Set<Int> = []
    public var seconds: [Int: TimeInterval] = [:]
    public var saved: [String] = []
    public init(enabled: Bool = false) { self.enabled = enabled }
}

extension NotesSession {
    func voiceState() -> SpeakerVoiceState {
        guard voices.enabled else { return SpeakerVoiceState() }
        let document = recorder.document
        let heard = SpeakerVoices.personClips(document, recorder.speakers?.voiceClips ?? [:])
        var state = SpeakerVoiceState(enabled: true)
        state.saved = voices.profiles.sorted { $0.updated > $1.updated }.map(\.name)
        state.recognised = voices.recognised
        for person in document.roster.active {
            if let profile = voices.link(person) { state.linked[person] = profile.name }
            state.seconds[person] = heard[person].map(SpeakerVoices.seconds) ?? 0
            if state.seconds[person, default: 0] >= VoiceMatch.enrolSeconds { state.canRemember.insert(person) }
        }
        return state
    }

    func voicesChanged() {
        recorder.speakers?.collectVoiceClips(voices.enabled)
        if let error = voices.error {
            model.speakerBanner = SpeakerBanner(document: recorder.document.id, kind: .notice(error))
        }
        sync()
        onVoicesChange?()
    }

    /// The task holds no audio after the request finishes; changes to the note or speaker names win over late matches.
    func processVoices() {
        guard voiceProcessingTask == nil, voices.hasWork(recorder.document, clips: recorder.speakers?.voiceClips ?? [:]) else { return }
        voiceProcessingTask = Task { [weak self] in
            guard let self else { return }
            await self.processSavedVoices()
            self.voiceProcessingTask = nil
            self.sync()
        }
    }

    public func waitForSavedVoices() async {
        if let task = voiceProcessingTask { await task.value }
        processVoices()
        await voiceProcessingTask?.value
    }

    func processSavedVoices() async {
        let document = recorder.document
        let matches = await voices.process(document, clips: recorder.speakers?.voiceClips ?? [:])
        guard recorder.document.id == document.id else { return }
        for match in matches {
            guard recorder.document.roster.person(id: match.person) == document.roster.person(id: match.person),
                  recorder.document.roster.person(id: match.person)?.name == nil,
                  recorder.document.roster.resolve(match.person) == match.person else { continue }
            voices.accept(match)
            recorder.editSpeakers { $0.renameSpeaker(match.person, to: match.name); return [] }
        }
        if !matches.isEmpty { sync() }
    }

    func editVoices(_ edit: SpeakerEdit) {
        switch edit {
        case .declineVoice(let person):
            voices.decline(person)
            recorder.editSpeakers { $0.renameSpeaker(person, to: ""); return [] }
        case .rememberVoice(let person), .updateVoice(let person):
            voices.name(person, recorder.document.roster.person(id: person)?.name)
        default: break
        }
        sync()
    }
}

public enum VoiceText {
    public static func needs(_ seconds: TimeInterval) -> String {
        "Remembered after \(Int(VoiceMatch.enrolSeconds)) s of their speech (\(Int(seconds)) s so far)"
    }
    public static let nameFirst = "Name this speaker to remember their voice"
    public static let consentTitle = "Remembering voices"
    public static func consentDetail(_ name: String, local: Bool) -> String {
        "Chirp will recognise \(name)’s voice in later notes on your devices. Saved voices stay on \(MacServerCopy.place(local: local)). Manage them in Saved voices."
    }
}

struct VoiceMenuItems: View {
    let model: NotesModel
    let person: Int
    var body: some View {
        let voices = model.voices
        if voices.enabled {
            Divider()
            if let name = voices.linked[person] {
                if voices.recognised.contains(person) {
                    Button("Not \(name)") { model.onSpeakerEdit(.declineVoice(person)) }
                }
                Button("Update \(name)’s voice") { model.onSpeakerEdit(.updateVoice(person)) }
                    .disabled(!voices.canRemember.contains(person))
            } else if model.document.roster.person(id: person)?.name != nil {
                Button("Remember voice") { model.onSpeakerEdit(.rememberVoice(person)) }
                if !voices.canRemember.contains(person) { Text(VoiceText.needs(voices.seconds[person] ?? 0)) }
            } else { Text(VoiceText.nameFirst) }
        }
    }
}
