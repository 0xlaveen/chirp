import ChirpCore
import Foundation
import Testing
@testable import ChirpIOSCore

/// Live Notes speaker labels on iOS (#201): the chip colours and the notices the app shows about the Mac's model.
@Suite struct SpeakersTests {
    private func luminance(_ c: ChirpColor.RGB) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    private func contrast(_ a: ChirpColor.RGB, _ b: ChirpColor.RGB) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    private func blend(_ top: ChirpColor.RGB, over bottom: ChirpColor.RGB, _ alpha: Double) -> ChirpColor.RGB {
        (top.r * alpha + bottom.r * (1 - alpha), top.g * alpha + bottom.g * (1 - alpha), top.b * alpha + bottom.b * (1 - alpha))
    }

    @Test func thePaletteMatchesTheRosterAndTheChipReadsInBothThemes() {
        #expect(SpeakerPalette.light.count == SpeakerRoster.paletteSize && SpeakerPalette.dark.count == SpeakerRoster.paletteSize)
        typealias Token = (light: ChirpColor.RGB, dark: ChirpColor.RGB)
        let surfaces: [Token] = [ChirpColor.Pond.surface, ChirpColor.Pond.background, ChirpColor.Pond.surfaceRaised]
        for (i, (hue, hueDark)) in zip(SpeakerPalette.light, SpeakerPalette.dark).enumerated() {
            for surface in surfaces {
                // The hue is the chip's dot and tint: a graphic needs 3:1 against what it sits on…
                #expect(contrast(hue, surface.light) >= 3, "light dot \(i)")
                #expect(contrast(hueDark, surface.dark) >= 3, "dark dot \(i)")
                // …and the name, in Pond ink, needs 4.5:1 on the tinted capsule.
                let lightChip = blend(hue, over: surface.light, SpeakerPalette.tint.light)
                let darkChip = blend(hueDark, over: surface.dark, SpeakerPalette.tint.dark)
                #expect(contrast(ChirpColor.Pond.ink.light, lightChip) >= 4.5, "light name \(i)")
                #expect(contrast(ChirpColor.Pond.ink.dark, darkChip) >= 4.5, "dark name \(i)")
            }
        }
    }

    @Test func eachPersonHasADistinctHueAndTheIndexWraps() {
        #expect(Set(SpeakerPalette.light.map { "\($0.r)\($0.g)\($0.b)" }).count == 8)
        #expect(Set(SpeakerPalette.dark.map { "\($0.r)\($0.g)\($0.b)" }).count == 8)
        #expect(SpeakerPalette.color(8) == SpeakerPalette.color(0) && SpeakerPalette.color(-1) == SpeakerPalette.color(7))
    }

    private func health(speakers: Bool?, model: SpeakersModel.State? = nil) -> Health {
        Health(notesSpeakers: speakers, speakersModel: model.map { SpeakersModel(state: $0) })
    }

    @Test func anOlderServerHidesTheFeatureWithAReasonInSettingsAndNeverNags() {
        #expect(!SpeakerNotice.available(nil) && !SpeakerNotice.available(health(speakers: nil)) && SpeakerNotice.available(health(speakers: true)))
        #expect(SpeakerNotice.status(on: true, health: health(speakers: nil), recorderError: "failed") == nil)
        #expect(SpeakerNotice.summary(on: true, health: health(speakers: nil)) == "Update Chirp on your Mac to label speakers")
        // No health yet is not "too old".
        #expect(SpeakerNotice.status(on: true, health: nil, recorderError: nil) == nil)
        #expect(SpeakerNotice.summary(on: true, health: nil) == "On · who said what")
        #expect(SpeakerNotice.summary(on: false, health: health(speakers: true)) == "Off · who said what")
    }

    @Test func theStatusLineFollowsTheModelAndTheLastSegment() {
        let ready = health(speakers: true, model: .ready)
        #expect(SpeakerNotice.status(on: false, health: health(speakers: true, model: .failed), recorderError: "failed") == nil)
        #expect(SpeakerNotice.status(on: true, health: ready, recorderError: nil) == nil)
        for state in [SpeakersModel.State.downloading, .notDownloaded] {
            #expect(SpeakerNotice.status(on: true, health: health(speakers: true, model: state), recorderError: nil) == .preparing(size: nil))
        }
        #expect(SpeakerNotice.status(on: true, health: health(speakers: true, model: .notDownloaded), recorderError: nil, requestFailed: true) == .failed)
        #expect(SpeakerNotice.status(on: true, health: health(speakers: true, model: .failed), recorderError: nil) == .failed)
        // A damaged model: the Mac says ready, the segment says it cannot use it.
        #expect(SpeakerNotice.status(on: true, health: ready, recorderError: "unavailable") == .failed)
        #expect(SpeakerNotice.status(on: true, health: ready, recorderError: "failed") == .lastSegment)
    }

    @Test func theStatusLineTextCarriesTheServersOwnSizeAndTheRightButtons() {
        let sized = Health(notesSpeakers: true, speakersModel: SpeakersModel(state: .downloading, sizeBytes: 26_530_309))
        let status = SpeakerNotice.status(on: true, health: sized, recorderError: nil)
        #expect(status?.text == "Getting the speaker model ready (27 MB, once)…")
        #expect(status?.canTurnOff == true && status?.canRetry == false)
        #expect(SpeakerNotice.Status.failed.text == "Couldn’t download the speaker model." && SpeakerNotice.Status.failed.canRetry)
        #expect(SpeakerNotice.Status.lastSegment.canTurnOff == false && SpeakerNotice.Status.lastSegment.canRetry == false)
    }

    @Test func settingsShowsWhereTheModelStands() {
        #expect(SpeakerNotice.modelStatus(on: false, health: health(speakers: true, model: .ready)) == nil)
        #expect(SpeakerNotice.modelStatus(on: true, health: nil) == nil && SpeakerNotice.modelStatus(on: true, health: health(speakers: nil)) == nil)
        #expect(SpeakerNotice.modelStatus(on: true, health: health(speakers: true, model: .ready)) == "Speaker model on your Mac: ready")
        #expect(SpeakerNotice.modelStatus(on: true, health: health(speakers: true, model: .downloading)) == "Speaker model on your Mac: downloading")
        #expect(SpeakerNotice.modelStatus(on: true, health: health(speakers: true, model: .failed)) == "Speaker model on your Mac: couldn’t download")
        #expect(SpeakerNotice.modelStatus(on: true, health: health(speakers: true, model: .notDownloaded), requestFailed: true)
                == "Speaker model on your Mac: couldn’t download")
    }

    @Test func labelsAreOnUntilTheUserTurnsThemOff() throws {
        let decode = { (json: String) in try JSONDecoder().decode(NotesPreferences.self, from: Data(json.utf8)) }
        #expect(NotesPreferences().labelSpeakers == nil && NotesPreferences().speakerLabelsOn)
        #expect(try decode("{}").speakerLabelsOn && decode("{}").labelSpeakers == nil)
        var p = NotesPreferences()
        p.labelSpeakers = false
        let off = try JSONDecoder().decode(NotesPreferences.self, from: JSONEncoder().encode(p))
        #expect(off.labelSpeakers == false && !off.speakerLabelsOn)
        p.labelSpeakers = true
        #expect(try JSONDecoder().decode(NotesPreferences.self, from: JSONEncoder().encode(p)).labelSpeakers == true)
        // Only a user's choice is written: an unset choice stays unset through a save.
        #expect(try JSONDecoder().decode(NotesPreferences.self, from: JSONEncoder().encode(NotesPreferences())).labelSpeakers == nil)
    }

    @Test func aLegacyFalseWasEveryoneWhoNeverSwitchedItOnSoItIsClearedOnce() throws {
        let decode = { (json: String) in try JSONDecoder().decode(NotesPreferences.self, from: Data(json.utf8)) }
        // Before the marker the field was a plain `false` for everyone who had not switched labels on.
        #expect(try decode(#"{"labelSpeakers":false}"#).labelSpeakers == nil)
        #expect(try decode(#"{"labelSpeakers":false,"speakerLabelsDefault":1}"#).speakerLabelsOn)
        #expect(try decode(#"{"labelSpeakers":true}"#).labelSpeakers == true)
        // From then on an explicit off is the user's and survives every later load.
        #expect(try decode(#"{"labelSpeakers":false,"speakerLabelsDefault":2}"#).labelSpeakers == false)
        var p = try decode(#"{"labelSpeakers":false}"#)
        p.labelSpeakers = false
        #expect(try decode(String(decoding: JSONEncoder().encode(p), as: UTF8.self)).labelSpeakers == false)
    }

    // MARK: fix-ups

    private func note() -> NotesDocument {
        var d = NotesDocument(startedAt: Date(timeIntervalSince1970: 0),
                              text: "## Plan\n- [ ] **Person 2** to send the spec\n- Person 1 agreed with Person 2.\n")
        d.append(NotesSegment(id: 0, offset: 0, raw: "we ship friday ok", text: "We ship Friday. OK."))
        d.attachServerTurns([ServerTurn(speaker: 0, start: 0, text: "We ship Friday."), ServerTurn(speaker: 1, start: 2, text: "OK.")],
                            generation: "g", toSegment: 0)
        return d
    }

    @Test func namesAreOneLineWithoutColonsAndAtMostSixtyCharacters() {
        #expect(SpeakerFixups.cleanName("  Maya  ") == "Maya")
        #expect(SpeakerFixups.cleanName("Anne\nMarie: Smith") == "Anne Marie Smith")
        #expect(SpeakerFixups.cleanName(" \n ") == nil && SpeakerFixups.cleanName(":") == nil)
        #expect(SpeakerFixups.cleanName(String(repeating: "é", count: 80))?.count == 60)
        #expect(SpeakerFixups.cleanName("José") == "José")
    }

    @Test func aRenameReachesTheTranscriptTheExportAndWhatStructuringReads() throws {
        var d = note()
        #expect(SpeakerFixups.rename(2, to: "Maya", replaceInNotes: false, in: &d).isEmpty)
        #expect(d.labelledText(d.segments[0]) == "Person 1: We ship Friday.\nMaya: OK.")
        #expect(try #require(d.nextStructureRequest()).transcript == "Person 1: We ship Friday.\nMaya: OK.")
        #expect(d.exportMarkdown().contains("Maya:") && d.text.contains("Person 2"))
    }

    @Test func replaceInNotesSwapsEveryWholeWordMention() {
        var d = note()
        let offer = SpeakerFixups.replaceOffer(2, renamingTo: "Maya", in: d)
        #expect(offer?.old == "Person 2" && offer?.new == "Maya" && offer?.count == 2)
        let changes = SpeakerFixups.rename(2, to: "Maya", replaceInNotes: true, in: &d)
        #expect(changes.count == 2 && d.text.contains("**Maya** to send") && d.text.contains("agreed with Maya."))
        #expect(d.text.contains("Person 1"))
        // No offer for a blank name that leaves "Person 2", or when the notes never say it.
        #expect(SpeakerFixups.replaceOffer(2, renamingTo: "  ", in: note()) == nil)
        #expect(SpeakerFixups.replaceOffer(2, renamingTo: "Maya", in: d) == nil)
    }

    @Test func blankGoesBackToPersonN() {
        var d = note()
        SpeakerFixups.rename(2, to: "Maya", replaceInNotes: false, in: &d)
        SpeakerFixups.rename(2, to: "", replaceInNotes: false, in: &d)
        #expect(d.roster.displayName(2) == "Person 2")
    }

    @Test func theMenuListsMergeTargetsAndSeparableMerges() {
        var d = note()
        #expect(SpeakerFixups.menu(for: 1, in: d.roster) == .init(name: "Person 1", mergeTargets: [2], separable: []))
        d.mergeSpeaker(2, into: 1)
        #expect(SpeakerFixups.menu(for: 1, in: d.roster) == .init(name: "Person 1", mergeTargets: [], separable: [2]))
        // Asking about the merged person speaks for whoever stands for them now.
        #expect(SpeakerFixups.menu(for: 2, in: d.roster).name == "Person 1")
        d.separateSpeaker(2)
        #expect(SpeakerFixups.menu(for: 2, in: d.roster) == .init(name: "Person 2", mergeTargets: [1], separable: []))
    }
}
