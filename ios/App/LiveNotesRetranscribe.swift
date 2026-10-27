import ChirpCore
import ChirpIOSCore
import Foundation
import os
import SwiftUI
import UIKit

// Re-transcribe a note from its kept audio on iPhone and iPad (#287 I): the consent sheet, the progress banner, the
// finish toast with Undo, Restore previous transcript, and the run itself. The engine (in-memory decoding, sockets,
// re-attribution to the existing speaker turns, apply and restore) is ChirpCore's, shared with the Mac.

/// Every re-transcribe string the phone shows (docs/copy.md: "Re-transcribe", "Allow re-transcribing", "Restore").
enum NotesRetranscribeCopy {
    static let action = "Re-transcribe…"
    static let again = "Transcribe again"
    static let tryAgain = "Try again"
    static let restore = "Restore previous transcript"
    static let setting = "Allow re-transcribing"
    static let settingFooter = "Re-transcribe sends a note’s kept audio to your computer again, only when you choose it and confirm, to rebuild its transcript. Turning this off cancels a running one."
    static let send = "Re-transcribe"
    static let sendAnyway = "Re-transcribe anyway"
    static let rebuild = "Also rebuild the notes from the new transcript."
    static let rebuildDetail = "This replaces the notes text, including your edits. You can undo it."
    static let rebuildNeedsCleanup = "Needs clean-up on your computer"
    static let changeModel = "Change the model in Chirp on your computer."
    static let sameModel = "Same model as before. Results change only if clean-up or context changed."
    static let update = "Update Chirp on your computer to re-transcribe"
    static let unreachable = "Can’t reach your computer right now. Try again when it is online."
    static let debugRetention = "Your computer is keeping debug recordings. This audio will be saved there for up to 3 days."
    static let updated = "Transcript updated"
    static let cancelled = "Cancelled. Nothing changed."
    static let paused = "Paused. Open Chirp to finish."
    static let waiting = "Waiting for your computer…"
    static let rebuilt = "Notes rebuilt"
    static let rebuildFailed = "Couldn’t rebuild the notes. Transcript updated."
    static let restored = "Previous transcript restored"
    static let applyDone = "Apply what’s done"
    static let refused = "Your computer refused the connection. Nothing changed. Pair again to continue."
    static let replaceEditsTitle = "Replace your edits?"
    static let replaceEditsMessage = "You edited the notes while Chirp rebuilt them. Rebuilding replaces the notes text, including those edits. You can undo it."
    static let replaceEdits = "Replace Notes"
    static let keepEdits = "Keep My Notes"

    /// Re-transcribe “Weekly sync”?
    static func title(_ note: String) -> String { "Re-transcribe “\(note)”?" }

    /// "8 min 10 s" (the sheet's length).
    static func length(_ seconds: TimeInterval) -> String {
        let s = max(1, Int(seconds.rounded()))
        if s < 60 { return "\(s) s" }
        if s < 3600 { return s % 60 == 0 ? "\(s / 60) min" : "\(s / 60) min \(s % 60) s" }
        return "\(s / 3600) h \(String(format: "%02d", s / 60 % 60)) min"
    }

    /// The sheet's first paragraph: what is sent, where, and that nothing keeps it.
    static func body(audio: TimeInterval, clips n: Int) -> String {
        "Chirp sends this note’s kept audio (\(length(audio)), \(n == 1 ? "1 clip" : "\(n) clips")) to Chirp on your computer. It is transcribed in memory there and not kept. Nothing else receives it."
    }

    /// One gap or segment: "Send this 0:32 clip to your computer to transcribe it again?"
    static func oneClip(_ seconds: TimeInterval) -> String {
        "Send this \(clock(seconds)) clip to your computer to transcribe it again? It is transcribed in memory there and not kept."
    }

    static func model(_ engine: String?) -> String { "Speech model: \(NotesSpeechModel.displayName(engine))." }
    static func before(_ engine: String?) -> String { "This note was transcribed with: \(NotesSpeechModel.displayName(engine))." }
    static func transcribedWith(_ engine: String?) -> String { "Transcribed with \(NotesSpeechModel.displayName(engine))" }
    static func cleanup(_ on: Bool) -> String { "Clean-up: \(on ? "on" : "off"). " + changeModel }
    /// Clean-up sends text to another host: only text, never audio.
    static func cleanupHost(_ host: String) -> String { "Clean-up sends text to \(host). Audio never goes there." }

    /// "3 of 43 segments have no kept audio and keep their current text."
    static func withoutAudio(_ missing: Int, of total: Int) -> String {
        "\(missing) of \(total) segment\(total == 1 ? "" : "s") \(missing == 1 ? "has" : "have") no kept audio and keep\(missing == 1 ? "s its" : " their") current text."
    }

    /// "Re-transcribing · 12 of 40 · 1:32 of 8:10".
    static func progress(_ p: NotesRetranscribeProgress) -> String {
        "Re-transcribing · \(p.done) of \(p.total) · \(clock(p.audioDone)) of \(clock(p.audioTotal))"
    }

    /// The finish toast: "Transcript updated", or "38 of 40 updated. 2 kept their old text."
    static func finished(updated: Int, of total: Int) -> String {
        guard updated < total else { return self.updated }
        let kept = total - updated
        return "\(updated) of \(total) updated. \(kept) kept \(kept == 1 ? "its" : "their") old text."
    }

    /// Why a run stopped before the end; nothing was applied.
    static func stopped(code: String) -> String {
        code == "busy" ? "Your computer stayed busy. Nothing changed yet." : "Couldn’t reach your computer. Nothing changed yet."
    }

    static func clock(_ seconds: TimeInterval) -> String { ChirpNotesActivityAttributes.ContentState.clock(seconds) }
}

/// What the consent sheet says about one run (#287 §2.2). Built fresh every time: there is no "don't ask again".
struct NotesRetranscribeOffer: Equatable, Identifiable {
    var note: UUID
    var title: String
    /// One segment ("Try again", "Transcribe again"), or nil for the whole note.
    var segment: Int?
    var clips: Int
    var audio: TimeInterval
    var segments: Int
    /// Segments with text but no kept audio: they keep their current text.
    var withoutAudio = 0
    /// The server's engine now, and the one the note was transcribed with (nil: unknown).
    var model: String?
    var before: String?
    /// Health came back: otherwise the sheet says the computer can't be reached and has no send button.
    var reachable = true
    /// The server takes `start.retranscribe` (otherwise the sheet asks to update and has no send button).
    var supported = true
    var debugRetention = false
    var cleanup = false
    /// Clean-up sends text to this host (`correction_leaves_machine`).
    var cleanupHost: String?
    /// Structuring is possible, so the notes can be rebuilt.
    var rebuildAvailable = true
    var rebuild = false
    var id: UUID { note }

    /// Every segment already came from the server's current model.
    var sameModel: Bool { model != nil && before == model }
    var canSend: Bool { reachable && supported }
}

/// The run on screen (one at a time on this device): its progress, a pause in the background, or why it stopped.
struct NotesRetranscribeRun: Equatable {
    var note: UUID
    var progress: NotesRetranscribeProgress
    /// The app went to the background: the clip in flight finished and the rest waits for the foreground.
    var paused = false
    /// Set when the run stopped early (busy, unreachable, refused): the banner shows it with Dismiss, and Apply what’s
    /// done when some clips finished.
    var failure: String?
    var canApplyPartial = false
    /// The server refused the pairing: the banner offers Pair computer.
    var repair = false

    var text: String {
        if let failure { return failure }
        if paused { return NotesRetranscribeCopy.paused }
        return progress.waiting ? NotesRetranscribeCopy.waiting : NotesRetranscribeCopy.progress(progress)
    }
}

/// The toast after a run, a restore or a rebuild ("Transcript updated · Undo").
struct NotesRetranscribeToast: Equatable, Identifiable {
    enum Action: Equatable { case restoreTranscript, undoRebuild }
    var text: String
    var note: UUID
    var action: Action?
    /// Bumped per toast, so a newer one restarts the timer.
    var id: Int
}

/// The run's working parts the controller keeps besides what it publishes.
@MainActor
final class NotesRetranscribeWork {
    var task: Task<Void, Never>?
    var gate: NotesRetranscribeGate?
    var staged: (note: UUID, result: NotesRetranscribeResult)?
    var rebuildTask: Task<Void, Never>?
    var pendingRebuild: (note: UUID, result: NotesRebuild.Result)?
    var endBackground: (() -> Void)?
    var toasts = 0
    static let log = Logger(subsystem: "dev.chirp.ios", category: "notes")
}

/// Holds the next clip while the app is in the background (#287 §2.3): the clip in flight finishes under a background
/// task, then the run waits here until the app is in front again. Cancelling the run lets a waiting clip go.
final class NotesRetranscribeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var onBlocked: (@Sendable () -> Void)?

    /// Later clips wait; `blocked` runs once a clip is waiting (nothing is in flight any more).
    func close(blocked: @escaping @Sendable () -> Void) { lock.withLock { closed = true; onBlocked = blocked } }

    func open() {
        let resumed = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            closed = false; onBlocked = nil
            defer { waiters.removeAll() }
            return Array(waiters.values)
        }
        resumed.forEach { $0.resume() }
    }

    func pass() async {
        let key = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let (waits, blocked) = lock.withLock { () -> (Bool, (@Sendable () -> Void)?) in
                    guard closed, !Task.isCancelled else { return (false, nil) }
                    waiters[key] = c
                    return (true, onBlocked)
                }
                if waits { blocked?() } else { c.resume() }
            }
        } onCancel: {
            lock.withLock { waiters.removeValue(forKey: key) }?.resume()
        }
    }
}

extension LiveNotesController {
    /// Re-transcribe… shows for the open note: allowed, it kept audio, it is not recording, no run is going.
    var canRetranscribe: Bool {
        preferences.allowRetranscribe && library != nil && selectedAudioBytes > 0 && !state.isActive
            && recordingID != document.id && retranscribeRun == nil
    }

    /// A run holds the open note: its transcript is read-only, and Continue recording and Delete audio wait.
    var isRetranscribing: Bool { retranscribeRun?.note == document.id }

    /// Restore previous transcript shows: a re-transcribe kept a version, and no run holds the note.
    var canRestoreTranscript: Bool { document.previousTranscript != nil && !state.isActive && !isRetranscribing }

    /// The toast belongs to the open note.
    var visibleRetranscribeToast: NotesRetranscribeToast? { retranscribeToast?.note == document.id ? retranscribeToast : nil }

    /// Re-transcribe… (the whole note) or one segment (Try again, Transcribe again): the sheet, filled in from the note
    /// as stored and the server's health now.
    func offerRetranscribe(segment: Int? = nil) async {
        guard preferences.allowRetranscribe, retranscribeRun == nil, let library else { return }
        let id = document.id
        await settleJournal()
        await refreshHealth()
        guard document.id == id, !state.isActive, let stored = try? await library.record(id) else { return }
        let note = stored.document
        let clips = NotesRetranscriber.clips(for: note, only: segment)
        guard !clips.isEmpty else { return }
        let health = deps.server() == nil ? nil : self.health
        let withAudio = Set(note.audio.map(\.id))
        let spoken = note.segments.filter { !$0.isGap && !$0.text.isEmpty }
        let options = notesStartOptions(health: health)
        retranscribeOffer = NotesRetranscribeOffer(
            note: id, title: NoteMeta.displayTitle(document), segment: segment, clips: clips.count, audio: clips.reduce(0) { $0 + $1.duration },
            segments: note.segments.count, withoutAudio: spoken.filter { !withAudio.contains($0.id) }.count,
            model: health?.engine, before: note.transcribedWith, reachable: health != nil,
            supported: health?.supportsRetranscribe == true, debugRetention: health?.debugRetention == true,
            cleanup: options.correction, cleanupHost: options.correction && health?.correctionLeavesMachine == true ? health?.correctionHost : nil,
            rebuildAvailable: preferences.structureEnabled(health: health) && health?.notesStructure == true,
            rebuild: preferences.retranscribeRebuild)
    }

    /// The sheet's Re-transcribe.
    func startRetranscribe(_ offer: NotesRetranscribeOffer) {
        retranscribeOffer = nil
        guard retranscribeRun == nil, offer.canSend, preferences.allowRetranscribe, let library, let config = deps.server() else { return }
        if offer.segment == nil, offer.rebuild != preferences.retranscribeRebuild { rememberRebuildChoice(offer.rebuild) }
        let id = offer.note, health = self.health, store = library.store
        let gate = NotesRetranscribeGate()
        let make = deps.retranscribeStream ?? deps.makeStream, http = deps.http
        // The sealed clip is opened and decoded in memory only (no plaintext file); in the background the next clip
        // waits at the gate.
        let runner = NotesRetranscriber(
            makeSession: { make(config, $0, http) }, options: notesStartOptions(health: health), health: health,
            audio: { clip in
                await gate.pass()
                try Task.checkCancellation()
                return try NotesAudioDecoder.decode(try await store.audioData(id, segment: clip.segment))
            },
            wait: deps.sleep)
        runner.onProgress = { [weak self] progress in
            Task { @MainActor in
                guard let self, self.retranscribeRun?.note == id, self.retranscribeRun?.failure == nil else { return }
                self.retranscribeRun?.progress = progress
            }
        }
        let rebuild = offer.segment == nil && offer.rebuild && offer.rebuildAvailable
        let body = noteDocument(id)?.text
        retranscribeToast = nil
        retranscribeWork.gate = gate
        retranscribeRun = NotesRetranscribeRun(
            note: id, progress: NotesRetranscribeProgress(done: 0, total: offer.clips, audioDone: 0, audioTotal: offer.audio))
        if background { retranscribeBackground(true) }
        retranscribeWork.task = Task { [weak self] in
            let stored = try? await library.record(id)
            let clips = stored.map { NotesRetranscriber.clips(for: $0.document, only: offer.segment) } ?? []
            // The note went away before the first clip: nothing to send, nothing changes.
            let result = clips.isEmpty ? NotesRetranscribeResult(end: .cancelled) : await runner.run(clips)
            await self?.finishRetranscribe(id, result: result, rebuild: rebuild ? body : nil)
        }
    }

    /// `rebuild` is the body when the run started: the rebuild replaces it silently only if it still reads the same.
    private func finishRetranscribe(_ id: UUID, result: NotesRetranscribeResult, rebuild: String?) async {
        retranscribeWork.task = nil
        retranscribeWork.gate = nil
        endRetranscribeBackground()
        NotesRetranscribeWork.log.info("\(result.logLine, privacy: .public)")
        switch result.end {
        case .cancelled:
            retranscribeRun = nil
            retranscribeToastShow(NotesRetranscribeCopy.cancelled, note: id)
        case .auth:
            retranscribeRun?.failure = NotesRetranscribeCopy.refused
            retranscribeRun?.repair = true
        case .stopped(let code):
            retranscribeWork.staged = (id, result)
            retranscribeRun?.failure = NotesRetranscribeCopy.stopped(code: code)
            retranscribeRun?.canApplyPartial = !result.segments.isEmpty
        case .finished:
            await applyRetranscription(id, result: result, rebuild: rebuild)
        }
    }

    /// One revision of the note: every staged segment at once, then the toast (and the rebuild when asked for).
    private func applyRetranscription(_ id: UUID, result: NotesRetranscribeResult, rebuild: String?) async {
        retranscribeRun = nil
        retranscribeWork.staged = nil
        guard !result.segments.isEmpty else {
            retranscribeToastShow(NotesRetranscribeCopy.finished(updated: 0, of: result.total), note: id)
            return
        }
        var updated = 0
        guard updateNote(id, { updated = $0.applyRetranscription(result.segments) }), updated > 0 else { return }
        await settleJournal()
        retranscribeToastShow(NotesRetranscribeCopy.finished(updated: updated, of: result.total), note: id, action: .restoreTranscript)
        if let rebuild { startRebuild(id, body: rebuild) }
    }

    /// The error banner's Apply what’s done.
    func applyRetranscribedPartial() {
        guard let staged = retranscribeWork.staged else { return }
        Task { await applyRetranscription(staged.note, result: staged.result, rebuild: nil) }
    }

    /// Cancel: the clip in flight is cancelled and everything staged goes. The note is exactly as before.
    func cancelRetranscribe() {
        if let task = retranscribeWork.task { task.cancel(); return }
        dismissRetranscribe()
    }

    /// Dismiss on the error banner: nothing applies.
    func dismissRetranscribe() {
        retranscribeWork.staged = nil
        if let run = retranscribeRun {
            retranscribeRun = nil
            retranscribeToastShow(NotesRetranscribeCopy.cancelled, note: run.note)
        }
    }

    /// The note was deleted (`id`) or the setting turned off (nil): a run on it stops without applying anything.
    func cancelRetranscribe(note id: UUID?) {
        let pending = retranscribeWork.pendingRebuild?.note
        guard id == nil || retranscribeRun?.note == id || pending == id else { return }
        retranscribeWork.rebuildTask?.cancel()
        retranscribeWork.rebuildTask = nil
        retranscribeWork.pendingRebuild = nil
        confirmingRebuild = nil
        guard id == nil || retranscribeRun?.note == id else { return }
        if let task = retranscribeWork.task { task.cancel() } else { dismissRetranscribe() }
    }

    /// The toast's Undo and Restore previous transcript: the kept version swaps back in.
    func restorePreviousTranscript() {
        let id = document.id
        guard retranscribeRun?.note != id else { return }
        var swapped = false
        guard updateNote(id, { swapped = $0.restorePreviousTranscript() }), swapped else { return }
        retranscribeToastShow(NotesRetranscribeCopy.restored, note: id)
        Task { await settleJournal() }
    }

    func dismissRetranscribeToast() { retranscribeToast = nil }

    private func retranscribeToastShow(_ text: String, note: UUID, action: NotesRetranscribeToast.Action? = nil) {
        retranscribeWork.toasts += 1
        retranscribeToast = NotesRetranscribeToast(text: text, note: note, action: action, id: retranscribeWork.toasts)
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    // MARK: rebuild

    private func startRebuild(_ id: UUID, body: String) {
        retranscribeWork.rebuildTask = Task { [weak self] in
            guard let self, let document = self.noteDocument(id) else { return }
            let result = await NotesRebuild.run(document, structure: self.structureCall())
            guard !Task.isCancelled else { return }
            self.retranscribeWork.rebuildTask = nil
            guard let result else {
                self.retranscribeToastShow(NotesRetranscribeCopy.rebuildFailed, note: id, action: .restoreTranscript)
                return
            }
            NotesRetranscribeWork.log.info("notes retranscribe rebuild windows=\(result.windows, privacy: .public) structured=\(result.structured, privacy: .public)")
            if self.rebuildNote(id, result, ifBody: body) {
                self.retranscribeToastShow(NotesRetranscribeCopy.rebuilt, note: id, action: .undoRebuild)
            } else {
                // The body changed during the run (the late-AI rule): ask before replacing those edits.
                self.retranscribeWork.pendingRebuild = (id, result)
                self.confirmingRebuild = id
            }
        }
    }

    /// "Replace your edits?": Replace Notes applies the rebuild anyway; Keep My Notes drops it.
    func confirmRebuild(_ replace: Bool) {
        confirmingRebuild = nil
        guard let pending = retranscribeWork.pendingRebuild else { return }
        retranscribeWork.pendingRebuild = nil
        guard replace, rebuildNote(pending.note, pending.result, ifBody: nil) else { return }
        retranscribeToastShow(NotesRetranscribeCopy.rebuilt, note: pending.note, action: .undoRebuild)
    }

    // MARK: background

    /// In the background the clip in flight finishes under a background task, then the run pauses ("Paused. Open Chirp
    /// to finish.") until the app is in front again.
    func retranscribeBackground(_ inBackground: Bool) {
        guard let gate = retranscribeWork.gate else { return }
        if inBackground {
            gate.close { [weak self] in Task { @MainActor in self?.retranscribePaused() } }
            retranscribeWork.endBackground?()
            retranscribeWork.endBackground = deps.backgroundTask { [weak self] in self?.endRetranscribeBackground() }
        } else {
            gate.open()
            endRetranscribeBackground()
            retranscribeRun?.paused = false
        }
    }

    private func retranscribePaused() {
        guard background, retranscribeWork.gate != nil else { return }
        retranscribeRun?.paused = true
        endRetranscribeBackground()
    }

    private func endRetranscribeBackground() {
        retranscribeWork.endBackground?()
        retranscribeWork.endBackground = nil
    }
}

// MARK: views

/// The consent and options sheet, shown every time (the per-action consent, #287 §4).
struct RetranscribeSheet: View {
    @ObservedObject var notes: LiveNotesController
    let offer: NotesRetranscribeOffer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(NotesRetranscribeCopy.title(offer.title)).font(ChirpType.h2).foregroundStyle(Color.chirp.ink)
                        .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("chirp.notes.retranscribe.title")
                    if !offer.reachable {
                        Label(NotesRetranscribeCopy.unreachable, systemImage: "wifi.exclamationmark").fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("chirp.notes.retranscribe.unreachable")
                    } else if !offer.supported {
                        Label(NotesRetranscribeCopy.update, systemImage: "arrow.down.circle").fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("chirp.notes.retranscribe.update")
                    } else {
                        Text(offer.segment == nil ? NotesRetranscribeCopy.body(audio: offer.audio, clips: offer.clips)
                             : NotesRetranscribeCopy.oneClip(offer.audio))
                            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("chirp.notes.retranscribe.body")
                        VStack(alignment: .leading, spacing: 6) {
                            Text(NotesRetranscribeCopy.model(offer.model))
                            Text(NotesRetranscribeCopy.before(offer.before)).foregroundStyle(Color.chirp.inkMuted)
                            if offer.sameModel { Text(NotesRetranscribeCopy.sameModel).foregroundStyle(Color.chirp.inkMuted) }
                            Text(NotesRetranscribeCopy.cleanup(offer.cleanup)).foregroundStyle(Color.chirp.inkMuted)
                        }.font(.subheadline).fixedSize(horizontal: false, vertical: true)
                        if offer.segment == nil {
                            Toggle(isOn: Binding(get: { notes.retranscribeOffer?.rebuild ?? false },
                                                 set: { notes.retranscribeOffer?.rebuild = $0 })) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(NotesRetranscribeCopy.rebuild)
                                    Text(offer.rebuildAvailable ? NotesRetranscribeCopy.rebuildDetail : NotesRetranscribeCopy.rebuildNeedsCleanup)
                                        .font(.footnote).foregroundStyle(Color.chirp.inkMuted)
                                }.fixedSize(horizontal: false, vertical: true)
                            }
                            .disabled(!offer.rebuildAvailable).accessibilityIdentifier("chirp.notes.retranscribe.rebuild")
                            if offer.withoutAudio > 0 {
                                Text(NotesRetranscribeCopy.withoutAudio(offer.withoutAudio, of: offer.segments))
                                    .font(.subheadline.italic()).foregroundStyle(Color.chirp.inkMuted).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if let host = offer.cleanupHost {
                            Label(NotesRetranscribeCopy.cleanupHost(host), systemImage: "arrow.up.right.circle")
                                .font(.subheadline).foregroundStyle(Color.chirp.inkMuted).fixedSize(horizontal: false, vertical: true)
                        }
                        if offer.debugRetention {
                            PondBanner(kind: .error, title: NotesRetranscribeCopy.debugRetention)
                                .accessibilityElement(children: .combine).accessibilityIdentifier("chirp.notes.retranscribe.debug")
                        }
                    }
                    if offer.canSend {
                        Button { notes.startRetranscribe(notes.retranscribeOffer ?? offer) } label: {
                            Text(offer.debugRetention ? NotesRetranscribeCopy.sendAnyway : NotesRetranscribeCopy.send).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
                        .tint(offer.debugRetention ? Color.chirp.record : Color.chirp.koi).foregroundStyle(Color.chirp.onKoi)
                        .padding(.top, 4).accessibilityIdentifier("chirp.notes.retranscribe.send")
                    }
                }.padding(24).frame(maxWidth: 560, alignment: .leading).frame(maxWidth: .infinity)
            }
            .background(Color.chirp.background)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { notes.retranscribeOffer = nil }.accessibilityIdentifier("chirp.notes.retranscribe.cancel")
                }
            }
        }
        .tint(Color.chirp.koi)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

/// The banner at the top of the transcript (and the iPhone note) while a run lasts, or after it stopped early.
struct RetranscribeBanner: View {
    @ObservedObject var notes: LiveNotesController
    let run: NotesRetranscribeRun
    var pair: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: run.failure != nil ? "exclamationmark.triangle.fill" : run.paused ? "pause.circle" : "waveform")
                    .foregroundStyle(run.failure != nil ? Color.chirp.record : Color.chirp.koi).accessibilityHidden(true)
                Text(run.text).font(.subheadline.monospacedDigit()).foregroundStyle(Color.chirp.ink)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("chirp.notes.retranscribe.status")
            }
            if run.failure == nil {
                ProgressView(value: run.progress.fraction).progressViewStyle(.linear).tint(Color.chirp.koi)
                    .accessibilityLabel("Re-transcribing, \(run.progress.done) of \(run.progress.total)")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { Spacer(minLength: 0); buttons }
                VStack(alignment: .leading, spacing: 8) { buttons }
            }
        }
        .padding(12)
        .background(Color.chirp.koiContainer.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chirp.notes.retranscribe.banner")
    }

    @ViewBuilder private var buttons: some View {
        if run.failure == nil {
            Button("Cancel") { notes.cancelRetranscribe() }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                .accessibilityIdentifier("chirp.notes.retranscribe.stop")
        } else {
            if run.repair { Button("Pair computer", action: pair).buttonStyle(.bordered).buttonBorderShape(.capsule) }
            if run.canApplyPartial {
                Button(NotesRetranscribeCopy.applyDone) { notes.applyRetranscribedPartial() }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                    .accessibilityIdentifier("chirp.notes.retranscribe.apply")
            }
            Button("Dismiss") { notes.dismissRetranscribe() }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                .accessibilityIdentifier("chirp.notes.retranscribe.dismiss")
        }
    }
}

/// "Transcript updated · Undo" above the dock, for a few seconds. Restore previous transcript stays in the menus after.
struct RetranscribeToastView: View {
    @ObservedObject var notes: LiveNotesController
    let toast: NotesRetranscribeToast
    var undoRebuild: () -> Void
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    var body: some View {
        HStack(spacing: 12) {
            Text(toast.text).font(.subheadline).foregroundStyle(Color.chirp.ink).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("chirp.notes.retranscribe.toast")
            if let action = toast.action {
                Button("Undo") {
                    notes.dismissRetranscribeToast()
                    switch action {
                    case .restoreTranscript: notes.restorePreviousTranscript()
                    case .undoRebuild: undoRebuild()
                    }
                }.font(.subheadline.weight(.semibold)).accessibilityIdentifier("chirp.notes.retranscribe.undo")
            }
            Button("Dismiss", systemImage: "xmark") { notes.dismissRetranscribeToast() }.labelStyle(.iconOnly).font(.subheadline)
                .foregroundStyle(Color.chirp.inkMuted)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Color.chirp.surfaceRaised, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.chirp.inkMuted.opacity(0.2)))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .frame(maxWidth: 560)
        .accessibilityElement(children: .contain)
        .task(id: toast.id) {
            try? await Task.sleep(for: .seconds(voiceOver ? 20 : 8))
            if !Task.isCancelled, notes.retranscribeToast?.id == toast.id { notes.dismissRetranscribeToast() }
        }
    }
}
