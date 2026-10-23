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
        case .connecting, .listening: #expect(p.kind == .stop && p.title == "Stop dictation" && p.isEnabled)
        case .correcting: #expect(p.kind == .polishing && p.title == "Polishing…" && !p.isEnabled)
        case .armed, .finished: #expect(p.kind == .start && p.title == "Start dictation" && p.symbol == "mic.fill" && p.isEnabled)
        case .idle, .failed: #expect(p.kind == .openChirp && p.title == "Open Chirp to start session" && p.isEnabled)
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
        #expect(s.primary.kind == .fullAccess && !s.primary.isEnabled)
        #expect(!s.cancelEnabled && !s.rawEnabled && !s.styleEnabled && !s.endEnabled && !s.showsOpenChirp)
        #expect(s.status == "Dictation needs Full Access" && s.elapsed == nil && s.remaining == nil)
    }

    @Test func startPendingDisablesStartAndAllowsCancel() {
        let s = KeyboardPresenter.screen(inputs(.armed) { $0.startPending = true; $0.ownsUtterance = true })
        #expect(s.primary.kind == .start && s.primary.title == "Starting…" && !s.primary.isEnabled)
        #expect(s.cancelEnabled)
    }

    @Test func fallbackOrRecoveryAddsSecondaryOpenWithoutChangingPrimary() {
        let plain = KeyboardPresenter.screen(inputs(.armed))
        #expect(!plain.showsOpenChirp)
        let fallback = KeyboardPresenter.screen(inputs(.armed) { $0.fallback = "Open Chirp manually." })
        #expect(fallback.showsOpenChirp && fallback.primary.kind == .start)
        #expect(fallback.status == "Open Chirp" && fallback.detail == "Open Chirp manually.")
        let recover = KeyboardPresenter.screen(inputs(.armed) { $0.requiresRecovery = true })
        #expect(recover.showsOpenChirp && recover.status == "Text kept in place")
        let none = KeyboardPresenter.screen(inputs(nil) { $0.fallback = "Session unavailable." })
        #expect(none.showsOpenChirp && none.primary.kind == .openChirp)
    }
}

@Suite struct ControlFlagTests {
    @Test(arguments: KeyboardPhase.allCases, [true, false])
    func controlFlags(phase: KeyboardPhase, final: Bool) {
        for lease in [true, false] {
            let s = KeyboardPresenter.screen(inputs(phase, lease: lease ? 8 : -1) { $0.isFinal = final; $0.ownsUtterance = true })
            let busy = phase == .connecting || phase == .listening || phase == .correcting
            #expect(s.endEnabled == lease)
            #expect(s.cancelEnabled == (lease && busy && !final))
            #expect(s.styleEnabled == (lease && !busy))
            #expect(!s.rawEnabled)
        }
    }

    @Test func styleMenuTitlesAndCheckmark() {
        let s = KeyboardPresenter.screen(inputs(.armed) { $0.styleID = "chat" })
        #expect(s.styleItems == [StyleItem(id: "default", title: "Default", isChecked: false),
                                 StyleItem(id: "chat", title: "Chat", isChecked: true),
                                 StyleItem(id: "acme", title: "acme", isChecked: false)])
        #expect(s.styleTitle == "Style: Chat" && s.styleEnabled)
        #expect(KeyboardPresenter.screen(inputs(.armed) { $0.styleID = "acme" }).styleTitle == "Style: Custom")
        let empty = KeyboardPresenter.screen(inputs(.armed) { $0.availableStyleIDs = [] })
        #expect(empty.styleItems.isEmpty && !empty.styleEnabled)
    }

    @Test func globeAndWarning() {
        #expect(KeyboardPresenter.screen(inputs { $0.needsGlobe = true }).showsGlobe)
        #expect(!KeyboardPresenter.screen(inputs()).showsGlobe)
        #expect(KeyboardPresenter.screen(inputs { $0.debugRetention = true }).warning == "DEBUG recordings kept on the server")
        #expect(KeyboardPresenter.screen(inputs()).warning == nil)
    }

    @Test func compactHeightCollapsesDetailOnly() {
        let wide = KeyboardPresenter.screen(inputs(.armed))
        let compact = KeyboardPresenter.screen(inputs(.armed) { $0.compactHeight = true })
        #expect(wide.showsDetail && !compact.showsDetail)
        #expect(compact.detail == wide.detail && compact.status == wide.status)
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
        #expect(s.rawEnabled && s.rawSecondsLeft == label && s.rawTitle == "Use raw (\(label)s)")
    }

    @Test func closedWindowRequestedOrNotOwned() {
        for s in [raw(0), raw(-1), raw(nil), raw(3, requested: true), raw(3, final: false), raw(3, owns: false)] {
            #expect(!s.rawEnabled)
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
        }
        let s = KeyboardPresenter.screen(inputs(.listening) { $0.recordingStartedAt = now.addingTimeInterval(-3725) })
        #expect(s.elapsed == "1:02:05" && s.status == "Listening… · 1:02:05")
        #expect(KeyboardPresenter.screen(inputs(.listening)).elapsed == nil)
    }

    @Test func remainingFromSessionExpiryOmittedForNever() {
        let timed = KeyboardPresenter.screen(inputs(.armed) { $0.sessionExpiresAt = now.addingTimeInterval(754.2) })
        #expect(timed.remaining == "12:35 left" && timed.status == "Session armed · 12:35 left")
        let never = KeyboardPresenter.screen(inputs(.armed))
        #expect(never.remaining == nil && never.status == "Session armed")
        let both = KeyboardPresenter.screen(inputs(.listening) {
            $0.sessionExpiresAt = now.addingTimeInterval(60); $0.recordingStartedAt = now.addingTimeInterval(-7)
        })
        #expect(both.status == "Listening… · 0:07 · 1:00 left")
        #expect(KeyboardPresenter.screen(inputs(nil) { $0.sessionExpiresAt = now.addingTimeInterval(60) }).remaining == nil)
    }

    @Test(arguments: KeyboardPhase.allCases)
    func everyPhaseHasText(phase: KeyboardPhase) {
        let s = KeyboardPresenter.screen(inputs(phase))
        #expect(!s.phaseText.isEmpty && !(s.detail ?? "").isEmpty && s.status.hasPrefix(s.phaseText))
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
        #expect(s.status == "Dictation failed" && s.detail == KeyboardError.unknown.guidance)
        #expect(KeyboardError.allCases.map(\.rawValue) ==
                ["auth", "busy", "tooLong", "badAudio", "badRequest", "engine", "unreachable", "timeout", "permission", "interrupted", "storage", "unknown",
                                                  "offline", "notFound", "secure"])
        #expect(KeyboardPhase.allCases.map(\.rawValue) == ["idle", "armed", "connecting", "listening", "correcting", "finished", "failed"])
    }

    @Test func recoveryAndFallbackOutrankErrorGuidance() {
        #expect(KeyboardPresenter.screen(inputs(.failed) { $0.errorCode = .auth; $0.requiresRecovery = true }).status == "Text kept in place")
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

@Suite struct DeleteRepeatAndMetricsTests {
    @Test func repeatAcceleratesAndHasFloor() {
        let steps = (0..<40).map(KeyRepeat.interval(afterRepeats:))
        #expect(zip(steps, steps.dropFirst()).allSatisfy { $0 >= $1 })
        #expect(steps.first! > steps.last! && steps.last! >= 0.03 && KeyRepeat.initialDelay > steps.first!)
    }

    @Test func iPhonePortraitIsFullWidthPrimary() {
        let m = KeyboardMetrics.make(width: 393, compactHeight: false)
        #expect(m.primaryHeight >= KeyboardMetrics.minimumPrimaryHeight && m.maxPrimaryWidth == nil && m.spacing == 8)
    }

    @Test func iPadCapsPrimaryAndWidensSpacing() {
        let phone = KeyboardMetrics.make(width: 393, compactHeight: false)
        let pad = KeyboardMetrics.make(width: 820, compactHeight: false)
        #expect(pad.maxPrimaryWidth == 440 && pad.spacing > phone.spacing && pad.inset > phone.inset)
        #expect(pad.primaryHeight >= KeyboardMetrics.minimumPrimaryHeight && pad.keyHeight > phone.keyHeight)
    }

    @Test(arguments: [393.0, 852.0, 1180.0])
    func compactHeightKeepsPrimaryAndShrinksKeys(width: Double) {
        let m = KeyboardMetrics.make(width: width, compactHeight: true)
        let regular = KeyboardMetrics.make(width: width, compactHeight: false)
        #expect(m.primaryHeight >= KeyboardMetrics.minimumPrimaryHeight && m.keyHeight < regular.keyHeight)
        #expect(m.maxPrimaryWidth == (width >= 600 ? 440 : nil))
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
        #expect(undo.showsUndo && undo.cancelEnabled)
        i.undoAvailable = false
        #expect(!KeyboardPresenter.screen(i).showsUndo && !KeyboardPresenter.screen(i).cancelEnabled)
        var recording = live(.listening); recording.ownsUtterance = true; recording.undoAvailable = true
        #expect(!KeyboardPresenter.screen(recording).showsUndo && KeyboardPresenter.screen(recording).cancelEnabled)
    }
    @Test func keptFinalAndNoticesNameWhatHappened() {
        var i = live(.finished); i.kept = true; i.errorCode = .notFound
        let kept = KeyboardPresenter.screen(i)
        #expect(kept.phaseText == "Kept what was heard")
        #expect(kept.detail == KeyboardError.notFound.guidance)
        i.notice = "Dictation removed"
        #expect(KeyboardPresenter.screen(i).status.hasPrefix("Dictation removed"))
        var gone = i; gone.leaseUntil = nil
        #expect(!KeyboardPresenter.screen(gone).status.hasPrefix("Dictation removed"), "Notices need a live session")
    }
}
