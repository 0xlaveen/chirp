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

/// What to tell the user about the Mac's speaker model and the labels, in the note and in Settings. Labels are on by
/// default (#247): the Mac's server fetches its model by itself, so nothing here asks; it only says where things stand.
public enum SpeakerNotice {
    /// The Mac's server can label speakers (health); an older one cannot.
    public static func available(_ health: Health?) -> Bool { health?.notesSpeakers == true }

    /// The one line in the note's banner slot while labels are on but not working yet.
    public enum Status: Equatable, Sendable {
        /// The model is being fetched (or the request is on its way); `size` is the server's own figure ("27 MB").
        case preparing(size: String?)
        /// The fetch failed, the model is damaged, or the request could not reach the Mac.
        case failed
        /// One segment could not be labelled; the next one tries again.
        case lastSegment

        public var text: String {
            switch self {
            case .preparing(let size): return "Getting the speaker model ready (\(size.map { $0 + ", " } ?? "")once)…"
            case .failed: return "Couldn’t download the speaker model."
            case .lastSegment: return "Couldn’t label the last segment’s speakers."
            }
        }
        public var canRetry: Bool { self == .failed }
        public var canTurnOff: Bool { self != .lastSegment }
    }

    /// Why speakers are not being labelled although labels are on (nil: nothing to say). An old server gets no line and
    /// no nag: Settings explains it. A missing model is a model state, never a reason to switch the preference off.
    public static func status(on: Bool, health: Health?, recorderError: String?, requestFailed: Bool = false) -> Status? {
        guard on, available(health) else { return nil }
        let size = health?.speakersModel?.sizeBytes.map { "\(Int((Double($0) / 1_000_000).rounded())) MB" }
        switch health?.speakersModel?.state {
        case .downloading: return .preparing(size: size)
        case .notDownloaded: return requestFailed ? .failed : .preparing(size: size)
        case .failed: return .failed
        case .ready, nil: break
        }
        if recorderError == "unavailable" { return .failed }
        return recorderError == nil ? nil : .lastSegment
    }

    /// Where the Mac's model stands, for the Settings row while labels are on (nil: nothing to say yet).
    public static func modelStatus(on: Bool, health: Health?, requestFailed: Bool = false) -> String? {
        guard on, available(health), let state = health?.speakersModel?.state else { return nil }
        switch state {
        case .ready: return "Speaker model on your Mac: ready"
        case .downloading: return "Speaker model on your Mac: downloading"
        case .notDownloaded: return requestFailed ? "Speaker model on your Mac: couldn’t download" : "Speaker model on your Mac: starting download"
        case .failed: return "Speaker model on your Mac: couldn’t download"
        }
    }

    /// The Settings row's summary line.
    public static func summary(on: Bool, health: Health?) -> String {
        if health != nil, !available(health) { return "Update Chirp on your Mac to label speakers" }
        return on ? "On · who said what" : "Off · who said what"
    }

    public static let info = "Shows who said what in the transcript (Person 1, Person 2…; tap a name to rename it) and lets the notes say who owns a to-do. Saved voices stay on your paired Mac and are shared by your devices. Settings → Notes → Saved voices lets you stop remembering or forget voices. No voiceprint is stored on this phone. The first time, your Mac fetches its speaker model from Hugging Face (once; nothing about you is sent). Turn it off here at any time."
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

/// The sheet edits a value snapshot; only Done changes the sealed note.
public struct SpeakerNamesDraft: Equatable, Sendable {
    public var names: [Int: String]
    public var merges: [Int: Int] = [:]
    public var remember: [Int: Bool] = [:]
    public var replace = true

    public init(_ document: NotesDocument) {
        names = Dictionary(uniqueKeysWithValues: document.namableSpeakers.map { ($0, document.roster.person(id: $0)?.name ?? "") })
    }

    public func preview(_ document: NotesDocument) -> NotesDocument {
        var copy = document
        for id in names.keys.sorted() { copy.renameSpeaker(id, to: SpeakerFixups.cleanName(names[id] ?? "")) }
        for id in merges.keys.sorted() { if let target = merges[id] { copy.mergeSpeaker(id, into: target) } }
        return copy
    }

    public func replacementCount(in document: NotesDocument) -> Int {
        let after = preview(document)
        return document.namableSpeakers.reduce(0) { count, id in
            let old = document.roster.displayName(id)
            return count + (old == after.roster.displayName(id) ? 0 : document.nameCount(old))
        }
    }

    public func apply(to document: inout NotesDocument) -> [NotesTextChange] {
        let before = document
        document = preview(document)
        guard replace else { return [] }
        return before.namableSpeakers.flatMap { id -> [NotesTextChange] in
            let old = before.roster.displayName(id), new = document.roster.displayName(id)
            return old == new ? [] : document.replaceSpeakerName(old, with: new)?.changes ?? []
        }
    }
}
