import Foundation
import Testing
@testable import KeyboardPolicy

private let now = Date(timeIntervalSince1970: 10_000)

private func inputs(_ phase: KeyboardPhase? = .armed, access: Bool = true, lease: TimeInterval = 8,
                    _ edit: (inout KeyboardInputs) -> Void = { _ in }) -> KeyboardInputs {
    var i = KeyboardInputs(now: now)
    i.hasFullAccess = access; i.phase = phase; i.leaseUntil = now.addingTimeInterval(lease)
    i.styleID = "default"; i.availableStyleIDs = ["default", "chat", "acme"]
    edit(&i)
    return i
}

@Suite struct PrimaryActionTests {
    @Test(arguments: KeyboardPhase.allCases)
    func primaryFollowsPhase(phase: KeyboardPhase) {
        let p = KeyboardPresenter.screen(inputs(phase)).primary
        switch phase {
        case .connecting, .listening:
            #expect(p.kind == .stop && p.style == .record && p.title == "Stop" && p.symbol == "stop.fill" && p.isEnabled)
            #expect(p.accessibilityLabel == "Stop dictation")
        case .correcting: #expect(p.kind == .polishing && p.style == .moon && p.title == "Polishing…" && !p.isEnabled)
        case .armed, .finished:
            #expect(p.kind == .start && p.style == .koi && p.title == "Start dictation" && p.symbol == "mic.fill" && p.isEnabled)
        case .idle, .failed:
            #expect(p.kind == .openChirp && p.style == .tonal && p.title == "Open Chirp to start" && p.isEnabled)
            #expect(p.symbol == "arrow.up.forward.app")
        }
    }

    @Test func noSessionOrExpiredLeaseOpensChirp() {
        #expect(KeyboardPresenter.screen(inputs(nil)).primary.kind == .openChirp)
        #expect(KeyboardPresenter.screen(inputs(.armed, lease: 0)).primary.kind == .openChirp)
        #expect(KeyboardPresenter.screen(inputs(.listening, lease: -1)).primary.kind == .openChirp)
        let expired = inputs(.armed) { $0.sessionExpiresAt = now }
        #expect(KeyboardPresenter.screen(expired).primary.kind == .openChirp)
        var noLease = inputs(.armed); noLease.leaseUntil = nil
        #expect(KeyboardPresenter.screen(noLease).primary.kind == .openChirp)
    }

    @Test(arguments: KeyboardPhase.allCases)
    func fullAccessDeniedDisablesEverythingButTyping(phase: KeyboardPhase) {
        let s = KeyboardPresenter.screen(inputs(phase, access: false) { $0.fallback = "x"; $0.requiresRecovery = true })
        #expect(s.primary.kind == .fullAccess && s.primary.style == .tonal && !s.primary.isEnabled && s.primary.symbol == "lock.fill")
        #expect(s.primary.title == "Full Access required")
        #expect(s.chips.isEmpty && !s.endEnabled)
        #expect(s.phaseText == "Needs Full Access" && s.glyph == .warning && s.trailing == nil)
        #expect(s.detail?.contains("Allow Full Access") == true, "ⓘ explains how to turn it on")
    }

    @Test func startPendingDisablesStartAndAllowsCancel() {
        let s = KeyboardPresenter.screen(inputs(.armed) { $0.startPending = true; $0.ownsUtterance = true })
        #expect(s.primary.kind == .start && s.primary.title == "Starting…" && !s.primary.isEnabled)
        #expect(s.chips == [.cancel])
    }

    @Test func fallbackOrRecoveryAddsSecondaryOpenWithoutChangingPrimary() {
        let plain = KeyboardPresenter.screen(inputs(.armed))
        #expect(!plain.chips.contains(.open))
        let fallback = KeyboardPresenter.screen(inputs(.armed) { $0.fallback = "Open Chirp manually." })
        #expect(fallback.chips.contains(.open) && fallback.primary.kind == .start)
        #expect(fallback.phaseText == "Open Chirp" && fallback.detail == "Open Chirp manually.")
        let recover = KeyboardPresenter.screen(inputs(.armed) { $0.requiresRecovery = true })
        #expect(recover.chips.contains(.open) && recover.phaseText == "Text kept in place")
        let none = KeyboardPresenter.screen(inputs(nil) { $0.fallback = "Session unavailable." })
        #expect(none.chips.contains(.open) && none.primary.kind == .openChirp)
    }
}

@Suite struct ControlFlagTests {
    @Test(arguments: KeyboardPhase.allCases, [true, false])
    func controlFlags(phase: KeyboardPhase, final: Bool) {
        for lease in [true, false] {
            let s = KeyboardPresenter.screen(inputs(phase, lease: lease ? 8 : -1) { $0.isFinal = final; $0.ownsUtterance = true })
            let busy = phase == .connecting || phase == .listening || phase == .correcting
            #expect(s.endEnabled == lease)
            #expect(s.chips.contains(.cancel) == (lease && busy && !final))
            #expect(s.chips.contains(.style) == (lease && !busy))
            #expect(!s.chips.contains(.raw))
        }
    }

    @Test func styleMenuTitlesAndCheckmark() {
        let s = KeyboardPresenter.screen(inputs(.armed) { $0.styleID = "chat" })
        #expect(s.styleItems == [StyleItem(id: "default", title: "Default", isChecked: false),
                                 StyleItem(id: "chat", title: "Chat", isChecked: true),
                                 StyleItem(id: "acme", title: "acme", isChecked: false)])
        #expect(s.styleTitle == "Chat" && s.chips.contains(.style), "the chip names the style, never \"Style:…\"")
        #expect(KeyboardPresenter.screen(inputs(.armed) { $0.styleID = "acme" }).styleTitle == "acme")   // as the menu names it
        let empty = KeyboardPresenter.screen(inputs(.armed) { $0.availableStyleIDs = [] })
        #expect(empty.styleItems.isEmpty && !empty.chips.contains(.style))
    }

    @Test func debugWarning() {
        let debug = KeyboardPresenter.screen(inputs { $0.debugRetention = true })
        #expect(debug.warning == "DEBUG recordings kept on the server")
        #expect(debug.detail?.hasSuffix("DEBUG recordings kept on the server") == true, "the options panel explains the DEBUG notice")
        #expect(debug.topRow == .notReady && debug.phaseText == KeyboardPresenter.debugLine && debug.glyph == .warning)
        #expect(debug.primary.kind == .start, "the mic stays the row's action")
        #expect(KeyboardPresenter.screen(inputs()).warning == nil)
    }

    @Test func sizeClassNeverChangesTheScreen() {
        let wide = KeyboardPresenter.screen(inputs(.armed))
        let compact = KeyboardPresenter.screen(inputs(.armed) { $0.compactHeight = true })
        #expect(compact == wide)
    }
}

@Suite struct RawCountdownTests {
    private func raw(_ left: TimeInterval?, requested: Bool = false, final: Bool = true, owns: Bool = true) -> KeyboardScreen {
        KeyboardPresenter.screen(inputs(.finished) {
            $0.isFinal = final; $0.ownsUtterance = owns; $0.rawRequested = requested
            $0.rawUntil = left.map { now.addingTimeInterval($0) }
        })
    }

    @Test(arguments: [(5.0, 5), (4.2, 5), (4.0, 4), (1.01, 2), (1.0, 1), (0.01, 1)])
    func secondsRoundUp(left: Double, label: Int) {
        let s = raw(left)
        #expect(s.chips.contains(.raw) && s.rawSecondsLeft == label && s.rawTitle == "Use raw (\(label)s)")
    }

    @Test func closedWindowRequestedOrNotOwned() {
        for s in [raw(0), raw(-1), raw(nil), raw(3, requested: true), raw(3, final: false), raw(3, owns: false)] {
            #expect(!s.chips.contains(.raw))
        }
        #expect(raw(0).rawTitle == "Use raw" && raw(0).rawSecondsLeft == nil)
        #expect(raw(3, requested: true).rawSecondsLeft == 3)
    }
}

@Suite struct StatusLineTests {
    @Test func elapsedOnlyWhileRecording() {
        for phase in KeyboardPhase.allCases {
            let s = KeyboardPresenter.screen(inputs(phase) { $0.recordingStartedAt = now.addingTimeInterval(-75) })
            let recording = phase == .connecting || phase == .listening
            #expect(s.elapsed == (recording ? "1:15" : nil))
            #expect(s.trailing == (recording ? "1:15" : nil))
        }
        let s = KeyboardPresenter.screen(inputs(.listening) { $0.recordingStartedAt = now.addingTimeInterval(-3725) })
        #expect(s.elapsed == "1:02:05" && s.phaseText == "Listening…" && s.trailing == "1:02:05")
        #expect(KeyboardPresenter.screen(inputs(.listening)).elapsed == nil)
    }

    @Test func remainingFromSessionExpiryOmittedForNever() {
        let timed = KeyboardPresenter.screen(inputs(.armed) { $0.sessionExpiresAt = now.addingTimeInterval(754.2) })
        #expect(timed.remaining == "12:35 left" && timed.trailing == "12:35 left" && timed.phaseText == "Ready")
        let never = KeyboardPresenter.screen(inputs(.armed))
        #expect(never.remaining == nil && never.trailing == nil && never.phaseText == "Ready")
        let both = KeyboardPresenter.screen(inputs(.listening) {
            $0.sessionExpiresAt = now.addingTimeInterval(60); $0.recordingStartedAt = now.addingTimeInterval(-7)
        })
        #expect(both.phaseText == "Listening…" && both.trailing == "0:07", "the elapsed time wins while listening")
        #expect(KeyboardPresenter.screen(inputs(nil) { $0.sessionExpiresAt = now.addingTimeInterval(60) }).remaining == nil)
    }

    @Test(arguments: KeyboardPhase.allCases)
    func everyPhaseHasText(phase: KeyboardPhase) {
        let s = KeyboardPresenter.screen(inputs(phase))
        #expect(!s.phaseText.isEmpty && !(s.detail ?? "").isEmpty)
        #expect(s.phaseText.count <= 24, "one short line in the strip: \(s.phaseText)")
    }

    @Test func clockFormatting() {
        #expect(ClockText.format(0) == "0:00" && ClockText.format(9.9) == "0:09" && ClockText.format(59) == "0:59")
        #expect(ClockText.format(60) == "1:00" && ClockText.format(3599) == "59:59" && ClockText.format(3600) == "1:00:00")
        #expect(ClockText.format(-5) == "0:00" && ClockText.format(.nan) == "0:00" && ClockText.format(.infinity) == "0:00")
    }
}

@Suite struct ErrorGuidanceTests {
    @Test(arguments: KeyboardError.allCases)
    func everyCodeHasShortContentFreeGuidance(code: KeyboardError) {
        #expect(code.guidance.count > 10 && code.guidance.count <= 80)
        for phase in KeyboardPhase.allCases {
            let s = KeyboardPresenter.screen(inputs(phase) { $0.errorCode = code })
            let busy = phase == .connecting || phase == .listening || phase == .correcting
            #expect((s.detail == code.guidance) == !busy)
        }
    }

    @Test func specificGuidance() {
        #expect(KeyboardError.unreachable.guidance.contains("Tailscale"))
        #expect(KeyboardError.auth.guidance.contains("Pair again"))
        #expect(KeyboardError.permission.guidance.contains("Microphone"))
        #expect(KeyboardError.timeout.guidance.contains("too long"))
        #expect(KeyboardError.tooLong.guidance.contains("length"))
        #expect(KeyboardError.interrupted.guidance.contains("interrupted"))
        #expect(KeyboardError.busy.guidance.contains("busy"))
        #expect(KeyboardError.storage.guidance.contains("storage"))
        #expect(Set(KeyboardError.allCases.map(\.guidance)).count == KeyboardError.allCases.count)
    }

    @Test func failedWithoutCodeIsUnknownAndMatchesDiagnosticRawValues() {
        let s = KeyboardPresenter.screen(inputs(.failed))
        #expect(s.phaseText == "Dictation failed" && s.detail == KeyboardError.unknown.guidance && s.glyph == .warning)
        #expect(KeyboardError.allCases.map(\.rawValue) ==
                ["auth", "busy", "tooLong", "badAudio", "badRequest", "engine", "unreachable", "timeout", "permission", "interrupted", "storage", "unknown",
                                                  "offline", "notFound", "secure"])
        #expect(KeyboardPhase.allCases.map(\.rawValue) == ["idle", "armed", "connecting", "listening", "correcting", "finished", "failed"])
    }

    @Test func aServerDefinedStyleShowsItsIdInTheButtonAsInTheMenu() {
        var i = inputs(.armed); i.availableStyleIDs = ["default", "meeting"]; i.styleID = "meeting"
        let s = KeyboardPresenter.screen(i)
        #expect(s.styleTitle == "meeting" && s.styleItems.map(\.title) == ["Default", "meeting"])
        i.styleID = nil
        #expect(KeyboardPresenter.screen(i).styleTitle == "Default")
    }

    @Test func theStyleMenuMirrorsThePrivateSession() {
        var i = inputs(.armed)
        #expect(!KeyboardPresenter.screen(i).privacyOn)
        i.privacyMode = true
        #expect(KeyboardPresenter.screen(i).privacyOn)
    }

    @Test func anOverLongPromptPointsToStylesLikeTheApp() {
        #expect(KeyboardError.badRequest.guidance.contains("clean-up prompt is too long") && KeyboardError.badRequest.guidance.contains("Styles"))
    }

    @Test func recoveryAndFallbackOutrankErrorGuidance() {
        #expect(KeyboardPresenter.screen(inputs(.failed) { $0.errorCode = .auth; $0.requiresRecovery = true }).phaseText == "Text kept in place")
        #expect(KeyboardPresenter.screen(inputs(.failed) { $0.errorCode = .auth; $0.fallback = "f" }).detail == "f")
    }
}

@Suite struct RecordingClockTests {
    @Test func startsOnFirstObservationAndKeepsIt() {
        var clock = RecordingClock(); let id = UUID()
        clock.observe(phase: .armed, ownedUtterance: id, now: now)
        #expect(clock.startedAt == nil && clock.elapsed(now: now) == nil)
        clock.observe(phase: .connecting, ownedUtterance: id, now: now.addingTimeInterval(1))
        clock.observe(phase: .listening, ownedUtterance: id, now: now.addingTimeInterval(4))
        #expect(clock.startedAt == now.addingTimeInterval(1) && clock.elapsed(now: now.addingTimeInterval(6)) == 5)
    }

    @Test func clearsWhenRecordingEndsOrOwnershipIsLost() {
        for end in [(KeyboardPhase.correcting, UUID?.some(UUID())), (.finished, nil), (.listening, nil), (.idle, nil)] {
            var clock = RecordingClock(); let id = UUID()
            clock.observe(phase: .listening, ownedUtterance: id, now: now)
            clock.observe(phase: end.0, ownedUtterance: end.1 == nil ? nil : id, now: now.addingTimeInterval(1))
            #expect(clock.startedAt == nil)
        }
    }

    @Test func foreignUtteranceNeverStartsAndNewUtteranceRestarts() {
        var clock = RecordingClock()
        clock.observe(phase: .listening, ownedUtterance: nil, now: now)
        #expect(clock.startedAt == nil)
        clock.observe(phase: .listening, ownedUtterance: UUID(), now: now)
        clock.observe(phase: .listening, ownedUtterance: UUID(), now: now.addingTimeInterval(9))
        #expect(clock.startedAt == now.addingTimeInterval(9))
    }

    @Test func elapsedNeverNegative() {
        var clock = RecordingClock()
        clock.observe(phase: .listening, ownedUtterance: UUID(), now: now)
        #expect(clock.elapsed(now: now.addingTimeInterval(-10)) == 0)
    }
}

@Suite struct MetricsTests {
    @Test func iPhoneHidesThePrimaryTitleAndKeepsTouchTargets() {
        let m = KeyboardMetrics.make(width: 393, compactHeight: false)
        #expect(!m.showsPrimaryTitle && m.suggestionHeight >= 36 && m.chromeHeight == m.suggestionHeight)
    }

    @Test func iPadShowsTheTitleAndATallerSuggestionRow() {
        let phone = KeyboardMetrics.make(width: 393, compactHeight: false)
        let pad = KeyboardMetrics.make(width: 820, compactHeight: false)
        #expect(pad.showsPrimaryTitle && pad.inset > phone.inset && pad.suggestionHeight > phone.suggestionHeight)
    }

    @Test(arguments: [393.0, 852.0, 1180.0])
    func compactHeightShrinksTheRow(width: Double) {
        let m = KeyboardMetrics.make(width: width, compactHeight: true)
        let regular = KeyboardMetrics.make(width: width, compactHeight: false)
        #expect(m.suggestionHeight < regular.suggestionHeight)
        #expect(m.showsPrimaryTitle == (width >= 600))
    }
}

@Suite struct KeyboardUndoAndKeptTests {
    func live(_ phase: KeyboardPhase) -> KeyboardInputs {
        let now = Date(timeIntervalSince1970: 1_000)
        var i = KeyboardInputs(now: now)
        i.hasFullAccess = true; i.phase = phase; i.leaseUntil = now.addingTimeInterval(8)
        return i
    }
    @Test func cancelSlotBecomesUndoOnlyAfterAnOwnedFinal() {
        var i = live(.finished); i.ownsUtterance = true; i.isFinal = true; i.undoAvailable = true
        let undo = KeyboardPresenter.screen(i)
        #expect(undo.chips.first == .undo && !undo.chips.contains(.cancel))
        i.undoAvailable = false
        #expect(!KeyboardPresenter.screen(i).chips.contains(.undo) && !KeyboardPresenter.screen(i).chips.contains(.cancel))
        var recording = live(.listening); recording.ownsUtterance = true; recording.undoAvailable = true
        #expect(!KeyboardPresenter.screen(recording).showsUndo && KeyboardPresenter.screen(recording).chips == [.cancel])
    }
    @Test func keptFinalAndNoticesNameWhatHappened() {
        var i = live(.finished); i.kept = true; i.errorCode = .notFound
        let kept = KeyboardPresenter.screen(i)
        #expect(kept.phaseText == "Kept what was heard" && kept.glyph == .warning)
        #expect(kept.detail == KeyboardError.notFound.guidance)
        i.notice = "Dictation removed"
        #expect(KeyboardPresenter.screen(i).phaseText == "Dictation removed")
        var gone = i; gone.leaseUntil = nil
        #expect(KeyboardPresenter.screen(gone).phaseText != "Dictation removed", "Notices need a live session")
    }
}

@Suite struct StripChipsAndConstantHeightTests {
    private func screen(_ phase: KeyboardPhase?, access: Bool = true, _ edit: (inout KeyboardInputs) -> Void = { _ in }) -> KeyboardScreen {
        KeyboardPresenter.screen(inputs(phase, access: access, edit))
    }

    private func finishedScreen(_ edit: (inout KeyboardInputs) -> Void = { _ in }) -> KeyboardScreen {
        screen(.finished) {
            $0.isFinal = true; $0.ownsUtterance = true; $0.undoAvailable = true; $0.rawUntil = now.addingTimeInterval(4)
            $0.undoUntil = now.addingTimeInterval(4)
            edit(&$0)
        }
    }

    @Test func stripGlyphFollowsTheState() {
        #expect(screen(.armed).glyph == .koiDot && screen(.finished).glyph == .koiDot)
        #expect(finishedScreen().glyph == .check, "a landed final shows a check")
        #expect(screen(.connecting).glyph == .ripple && screen(.listening).glyph == .ripple)
        #expect(screen(.correcting).glyph == .moon)
        #expect(screen(.failed).glyph == .warning && screen(.armed) { $0.errorCode = .unreachable }.glyph == .warning)
        #expect(screen(nil).glyph == .idle && screen(.idle).glyph == .idle)
        #expect(screen(.armed) { $0.notice = "Dictation removed" }.glyph == .check)
    }

    @Test func labelsAreTheShortOnesFromTheSpec() {
        #expect(screen(.armed).phaseText == "Ready")
        #expect(screen(.connecting).phaseText == "Connecting…" && screen(.listening).phaseText == "Listening…")
        #expect(screen(.correcting).phaseText == "Polishing…")
        #expect(screen(.finished).phaseText == "Finished")
        #expect(screen(.finished) { $0.kept = true }.phaseText == "Kept what was heard")
        #expect(screen(.failed) { $0.errorCode = .unreachable }.phaseText == "Mac offline")
        #expect(screen(.armed) { $0.errorCode = .unreachable }.phaseText == "Mac offline")
        #expect(screen(nil).phaseText == "No session")
    }

    @Test func theFixLivesBehindTheInfoButton() {
        let failed = screen(.failed) { $0.errorCode = .unreachable }
        #expect(failed.detail == KeyboardError.unreachable.guidance && failed.phaseText.count < failed.detail!.count)
        #expect(screen(.armed).detail == "Microphone stays active in Chirp. Idle audio is discarded. End session turns it off.")
    }

    @Test func everyErrorHasAShortCause() {
        for code in KeyboardError.allCases {
            #expect(!code.cause.isEmpty && code.cause.count <= 28 && code.cause != code.guidance)
        }
        #expect(Set(KeyboardError.allCases.map(\.cause)).count == KeyboardError.allCases.count)
    }

    @Test func chipsAppearOnlyWhenTheyApply() {
        #expect(screen(.armed).chips == [.style])
        #expect(screen(.listening).chips == [.cancel])
        #expect(screen(.correcting).chips == [.cancel], "Polishing can still be cancelled")
        #expect(screen(nil).chips.isEmpty)
        let cleaned = screen(.finished) {
            $0.isFinal = true; $0.ownsUtterance = true; $0.undoAvailable = true; $0.rawUntil = now.addingTimeInterval(4)
        }
        #expect(cleaned.chips == [.undo, .raw, .style] && cleaned.rawTitle == "Use raw (4s)")
        #expect(screen(.finished) { $0.isFinal = true; $0.ownsUtterance = true }.chips == [.style], "Undo only after a final")
    }

    /// The heights come from `KeyboardMetrics`, the rows from the presenter: every state lays out the same two rows
    /// (Chirp's state takes over the suggestion row, never adds one), so the keyboard is the same height in every state.
    @Test(arguments: [(393.0, false), (393.0, true), (852.0, true), (820.0, false), (1180.0, false), (320.0, false)])
    func heightIsIdenticalInEveryState(width: Double, compact: Bool) {
        let metrics = KeyboardMetrics.make(width: width, compactHeight: compact)
        var heights = Set<Double>()
        var states = 0
        for phase in [KeyboardPhase?.none] + KeyboardPhase.allCases.map(Optional.some) {
            for access in [true, false] { for final in [true, false] { for error in [KeyboardError?.none, .unreachable, .auth] {
                for debug in [true, false] { for fallback in [true, false] {
                    let s = screen(phase, access: access) {
                        $0.isFinal = final; $0.ownsUtterance = final; $0.undoAvailable = final; $0.errorCode = error
                        $0.debugRetention = debug; $0.fallback = fallback ? "Open Chirp manually." : nil
                        $0.rawUntil = final ? now.addingTimeInterval(3) : nil; $0.compactHeight = compact
                        $0.recordingStartedAt = now.addingTimeInterval(-9); $0.sessionExpiresAt = now.addingTimeInterval(300)
                    }
                    #expect(s.rows == [.top, .keys])
                    #expect(Set(s.chips).count == s.chips.count && s.chips.count <= 4)
                    #expect(s.showsSuggestions == (s.topRow == .suggestions) && !s.actionChips.contains(.style))
                    if s.showsSuggestions { #expect(s.actionChips.isEmpty, "idle suggestions share the row with nothing else") }
                    heights.insert(metrics.chromeHeight); states += 1
                }}
            }}}
        }
        #expect(states > 100 && heights.count == 1)
    }

    @Test func chromeIsOneRowTheHeightOfTheSuggestionBar() {
        let m = KeyboardMetrics.make(width: 393, compactHeight: false)
        #expect(m.chromeHeight == m.suggestionHeight)
        #expect(m.chromeHeight <= 48, "one row, as on Android; nothing stacked above the suggestions")
        #expect(KeyboardMetrics.make(width: 393, compactHeight: true).chromeHeight < m.chromeHeight)
    }

    @Test func rowFitsItsTouchTargetsAndTextCaps() {
        for (width, compact) in [(393.0, false), (393.0, true), (820.0, false), (1180.0, true)] {
            let m = KeyboardMetrics.make(width: width, compactHeight: compact)
            #expect(m.suggestionHeight >= 36 && KeyboardMetrics.minimumPrimaryWidth >= 44 && KeyboardMetrics.controlWidth >= 44)
            #expect(KeyboardMetrics.maxRowTextPoints <= m.suggestionHeight / 2, "the largest text still fits the row")
        }
    }

    /// The top row, as Android's strip does it: suggestions only when idle; every other state replaces them.
    @Test func theRowFollowsTheStateLikeAndroid() {
        #expect(screen(.armed).topRow == .suggestions && screen(.armed).showsStyle)
        #expect(screen(.finished).topRow == .suggestions, "a finished session without a result to act on is idle again")
        #expect(screen(.listening).topRow == .dictating && screen(.connecting).topRow == .dictating)
        #expect(screen(.listening).actionChips == [.cancel])
        #expect(screen(.armed) { $0.startPending = true; $0.ownsUtterance = true }.topRow == .dictating)
        #expect(screen(.armed) { $0.startPending = true; $0.ownsUtterance = true }.phaseText == "Starting…")
        #expect(screen(.correcting).topRow == .polishing)
        let cleaned = finishedScreen()
        #expect(cleaned.topRow == .finished && cleaned.actionChips == [.undo, .raw] && !cleaned.showsSuggestions)
        #expect(screen(.armed) { $0.notice = "Dictation removed" }.topRow == .notice)
        #expect(screen(.listening) { $0.notice = "Dictation removed" }.topRow == .dictating, "dictating wins over a stale notice")
    }

    @Test func notReadyStatesAreOneMessageAndOneAction() {
        for s in [screen(nil), screen(.idle), screen(.failed) { $0.errorCode = .unreachable },
                  screen(.armed) { $0.errorCode = .unreachable }, screen(.armed, access: false),
                  screen(.armed) { $0.fallback = "Open Chirp manually." }, screen(.armed) { $0.requiresRecovery = true }] {
            #expect(s.topRow == .notReady && !s.showsSuggestions)
            #expect(!s.phaseText.isEmpty && s.phaseText.count <= 28, "one short message")
            #expect(s.detail != nil, "the long guidance is behind ⋯")
        }
        let none = screen(nil)
        #expect(none.primary.kind == .openChirp && none.primary.rowTitle == "Open Chirp")
        #expect(screen(.armed, access: false).primary.kind == .fullAccess)
        let offline = screen(.armed) { $0.errorCode = .unreachable }
        #expect(offline.primary.kind == .start && offline.primary.rowTitle == nil, "the mic retries")
    }

    @Test func undoAndRawCountDownInTheSameRow() {
        let s = finishedScreen()
        #expect(s.topRow == .finished && s.chips == [.undo, .raw, .style])
        #expect(s.undoTitle == "Undo (4s)" && s.undoSecondsLeft == 4 && s.rawTitle == "Use raw (4s)")
        let later = finishedScreen { $0.undoUntil = now.addingTimeInterval(0.2); $0.rawUntil = now.addingTimeInterval(0.2) }
        #expect(later.undoTitle == "Undo (1s)" && later.rawTitle == "Use raw (1s)", "seconds round up to 1 before the window closes")
        #expect(finishedScreen { $0.undoUntil = nil }.undoTitle == "Undo")
    }

    @Test func typingKeepsTheSuggestionsInAPassiveNotReadyState() {
        for s in [screen(nil) { $0.typing = true }, screen(.idle) { $0.typing = true }, screen(.armed, access: false) { $0.typing = true }] {
            #expect(s.topRow == .suggestions && s.showsSuggestions, "typing needs the word suggestions")
            #expect(s.detail != nil, "⋯ stays for the long guidance")
        }
        #expect(screen(nil) { $0.typing = true }.primary.kind == .openChirp, "the small icon is still Open Chirp")
        // Something that needs attention keeps its message even while typing.
        #expect(screen(.failed) { $0.errorCode = .unreachable; $0.typing = true }.topRow == .notReady)
        #expect(screen(.armed) { $0.fallback = "Open Chirp manually."; $0.typing = true }.topRow == .notReady)
        #expect(screen(.armed) { $0.requiresRecovery = true; $0.typing = true }.topRow == .notReady)
        #expect(screen(nil).topRow == .notReady, "and without typing the message is back")
    }

    @Test func remainingTimeIsADetailNotARowLabel() {
        let s = screen(.armed) { $0.sessionExpiresAt = now.addingTimeInterval(252) }
        #expect(s.remaining == "4:12 left" && s.topRow == .suggestions)
        #expect(s.phaseText == "Ready" && !s.phaseText.contains("left"))
    }
}
