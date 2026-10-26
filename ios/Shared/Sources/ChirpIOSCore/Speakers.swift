import ChirpCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Live Notes speaker labels on iOS (#201): the Pond-safe chip colours, and the words the app says about the Mac's
/// speaker model. Names and labels are note content: nothing here logs them.
public enum SpeakerPalette {
    /// Eight hues, each at least 4.5:1 on the light Pond surfaces; the dark set is the same hues lifted for the night
    /// pond. The same table as Android's `SpeakerColors` and the Mac's roster palette (`SpeakerRoster.paletteSize`).
    public static let light: [ChirpColor.RGB] = [0xC2410C, 0x2F7A4F, 0x4F46E5, 0xA21CAF, 0x0F766E, 0x8A5A00, 0x0369A1, 0xBE123C]
        .map(ChirpColor.hex)
    public static let dark: [ChirpColor.RGB] = [0xFF8A4C, 0x7CCB9B, 0xA5B4FC, 0xF0ABFC, 0x5EEAD4, 0xF5C566, 0x7DD3FC, 0xFDA4AF]
        .map(ChirpColor.hex)

    /// How strongly the chip's hue tints its own background (light, dark).
    public static let tint = (light: 0.12, dark: 0.18)

    /// The colour of `index` (a `SpeakerRoster.colorIndex`), light or dark by the current appearance.
    public static func color(_ index: Int) -> Color {
        let i = ((index % light.count) + light.count) % light.count
        return ChirpColor.color(light[i], dark[i])
    }
}

/// What to tell the user about the Mac's speaker model and the labels, in the transcript and in Settings.
public enum SpeakerNotice {
    /// The Mac's server can label speakers (health); an older one cannot.
    public static func available(_ health: Health?) -> Bool { health?.notesSpeakers == true }

    /// Why speakers are not being labelled although the switch is on (nil: nothing to say).
    public static func transcriptNote(on: Bool, health: Health?, recorderError: String?) -> String? {
        guard on else { return nil }
        if health != nil, !available(health) { return "Update Chirp on your Mac to label speakers." }
        let state = health?.speakersModel?.state
        if state == .downloading { return "Downloading the speaker model on your Mac…" }
        if recorderError == "unavailable" || state == .notDownloaded || state == .failed {
            return "The speaker model isn’t on your Mac. Turn Label speakers off and on to download it."
        }
        if recorderError != nil { return "Couldn’t label the last segment’s speakers." }
        return nil
    }

    /// Where the Mac's model stands, for the Settings row while the switch is on (nil: nothing to say yet).
    public static func modelStatus(on: Bool, health: Health?) -> String? {
        guard on, available(health), let state = health?.speakersModel?.state else { return nil }
        switch state {
        case .ready: return "Speaker model ready on your Mac."
        case .downloading: return "Downloading the speaker model on your Mac…"
        case .notDownloaded, .failed: return "The speaker model isn’t on your Mac. Turn Label speakers off and on to download it."
        }
    }

    /// The Settings row's summary line.
    public static func summary(health: Health?) -> String {
        if health != nil, !available(health) { return "Update Chirp on your Mac to label speakers" }
        return "Off by default · who said what"
    }

    /// Turning the switch on needs the user's say-so unless the Mac already has (or is fetching) its model.
    public static func needsConsent(health: Health?) -> Bool {
        let state = health?.speakersModel?.state
        return state != .ready && state != .downloading
    }

    public static let consentTitle = "Label speakers?"
    public static let consentMessage = "Chirp tells voices apart on your Mac to show who said what. This needs a 27 MB speaker model on your Mac, downloaded once from Hugging Face. Voices are compared in your Mac’s memory only and never saved; names stay in this note."
    public static let info = "Shows who said what in the transcript (Person 1, Person 2…; tap a name to rename it) and lets the notes say who owns a to-do. Your Mac tells the voices apart in its memory only: nothing about a voice is saved, on the Mac or on this phone. Turning it on asks before your Mac downloads its 27 MB speaker model."
}

/// What the user can do about a person in the transcript: rename (everywhere in the note, optionally in the notes text
/// too), merge two, separate a merge. Pure edits on a `NotesDocument`, so every rule is unit tested without a screen.
public enum SpeakerFixups {
    /// Names beyond this many characters are not read as speaker labels by the server's structuring (#217).
    public static let maxNameLength = 60

    /// A name as a label can carry it: one line, no colon (a `Name:` line would split there), whitespace collapsed, at most
    /// `maxNameLength` characters. Nil for a blank name, which puts the person back to "Person N".
    public static func cleanName(_ raw: String) -> String? {
        let flat = raw.map { $0 == ":" || $0.isNewline ? " " : $0 }
        let words = String(flat).split(whereSeparator: \.isWhitespace)
        let name = String(words.joined(separator: " ").prefix(maxNameLength)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// Renames `person` throughout the note. With `replaceInNotes`, the old name is also swapped for the new one in the
    /// notes text (whole words); the returned changes are those the editor replays.
    @discardableResult
    public static func rename(_ person: Int, to raw: String, replaceInNotes: Bool, in document: inout NotesDocument) -> [NotesTextChange] {
        let old = document.roster.displayName(person)
        document.renameSpeaker(person, to: cleanName(raw))
        let new = document.roster.displayName(person)
        guard replaceInNotes, new != old else { return [] }
        return document.replaceSpeakerName(old, with: new)?.changes ?? []
    }

    /// How many times the notes say `person`'s current name as a whole word, and the name a rename to `raw` would give
    /// ("Also replace … in the notes (N places)").
    public static func replaceOffer(_ person: Int, renamingTo raw: String, in document: NotesDocument) -> (old: String, new: String, count: Int)? {
        let old = document.roster.displayName(person)
        var preview = document
        preview.renameSpeaker(person, to: cleanName(raw))
        let new = preview.roster.displayName(person)
        let count = document.nameCount(old)
        return new != old && count > 0 ? (old, new, count) : nil
    }

    /// The menu of one person's chip: who they can be merged into, and who was merged into them (to separate).
    public struct Menu: Equatable, Sendable {
        public var name: String
        public var mergeTargets: [Int]
        public var separable: [Int]
    }

    public static func menu(for person: Int, in roster: SpeakerRoster) -> Menu {
        let target = roster.resolve(person)
        return Menu(name: roster.displayName(target), mergeTargets: roster.active.filter { $0 != target },
                    separable: roster.merged(into: target))
    }
}
