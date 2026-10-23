import Foundation

/// Where a voice edit is.
public enum NotesVoiceEditStatus: Equatable, Sendable {
    case idle
    /// Capturing the instruction; `heard` is the live partial.
    case listening(heard: String)
    /// The instruction is in (or its final is on the way, `instruction` empty) and the edit runs.
    case editing(instruction: String)
    /// The last edit ended, at `at` (the chip and the note time out from there).
    case done(NotesEditOutcome, at: TimeInterval)

    public var isListening: Bool { if case .listening = self { true } else { false } }
    public var isBusy: Bool { if case .idle = self { false } else if case .done = self { false } else { true } }
}

/// Live Notes' command mode (#97): the Edit by Voice button (or ⇧⌘E) starts it, pressing again ends it, Esc cancels.
/// What is said meanwhile goes to its own socket, never the transcript: while recording the recorder diverts capture
/// to it (and back after), otherwise the session opens the microphone just for it. The final is the instruction, sent
/// to `/v1/notes/edit` through the recorder's pass slot and applied as one undo step only to unchanged notes.
/// An explicit start and end was chosen over a wake phrase (false triggers, and the words would already be in a
/// segment's clean-up) and over holding a key (the dictation key's tap already starts and stops Notes in this window).
@MainActor
public final class NotesVoiceEdit {
    /// A command ends by itself after this long.
    public static let maxListen: TimeInterval = 20
    /// How long the instruction's final may take after the end.
    public static let finalTimeout: TimeInterval = 10

    public private(set) var status: NotesVoiceEditStatus = .idle { didSet { if status != oldValue { onChange?() } } }
    public var onChange: (() -> Void)?
    /// Opens the microphone for a command while Notes is not recording, its frames to the session; false on failure.
    public var openMicrophone: (StreamSession) -> Bool = { _ in false }
    public var closeMicrophone: () -> Void = {}
    /// The editor's selection when the command ends (nil or empty: the whole notes).
    public var selection: () -> NSRange? = { nil }

    private let recorder: NotesRecorder
    private let makeSession: (StartOptions) -> StreamSession
    private let now: () -> TimeInterval
    private let sleep: @Sendable (Duration) async -> Void
    private var session: StreamSession?
    private var diverted = false
    private var microphone = false
    private var heard = ""
    private var final: String?
    /// The command socket failed or closed before its final.
    private var dropped = false
    private var finalWaiter: CheckedContinuation<Void, Never>?
    private var listenTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private var run = 0

    public init(recorder: NotesRecorder, makeSession: @escaping (StartOptions) -> StreamSession,
                now: @escaping () -> TimeInterval, sleep: @escaping @Sendable (Duration) async -> Void) {
        self.recorder = recorder
        self.makeSession = makeSession
        self.now = now
        self.sleep = sleep
    }

    /// The button can start a command: the server edits and nothing else is in the way.
    public var canStart: Bool { recorder.canEdit && !status.isBusy && recorder.state != .stopping && recorder.state != .starting }

    /// The button and ⇧⌘E: start a command, or end the one listening.
    public func toggle() {
        if status.isListening { Task { await finish() } } else { start() }
    }

    public func start() {
        guard canStart else { return }
        run += 1
        let myRun = run
        heard = ""
        final = nil
        dropped = false
        // The raw words are enough for an instruction, and the clean-up model stays free for the edit.
        var options = recorder.options
        options.correction = false
        options.wordTimings = false
        let session = makeSession(options)
        self.session = session
        status = .listening(heard: "")
        eventsTask = Task {
            for await event in session.events {
                guard self.run == myRun else { return }
                if self.handle(event) { return }
            }
            guard self.run == myRun else { return }
            self.ended(nil)
        }
        Task {
            await session.open()
            guard self.run == myRun, self.status.isListening else { return }
            if self.recorder.divert(to: session) {
                self.diverted = true
            } else if !self.recorder.state.isActive, self.openMicrophone(session) {
                self.microphone = true
            } else {
                await self.abandon(.failed("busy"))
                return
            }
        }
        listenTask = Task {
            await sleep(.seconds(Self.maxListen))
            guard !Task.isCancelled, self.run == myRun, self.status.isListening else { return }
            await self.finish()
        }
    }

    /// End listening: capture goes back to the notes (or the microphone closes), the final arrives, the edit runs.
    public func finish() async {
        guard status.isListening, let session else { return }
        let myRun = run
        listenTask?.cancel()
        status = .editing(instruction: "")
        await release()
        await session.stop()
        if final == nil, !dropped {
            let sleep = self.sleep
            let timeout = Task {
                await sleep(.seconds(Self.finalTimeout))
                guard !Task.isCancelled, self.run == myRun else { return }
                self.resumeWaiter()
            }
            await withCheckedContinuation { finalWaiter = $0 }
            timeout.cancel()
        }
        guard run == myRun else { return }
        await session.close()
        let instruction = (final ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else {
            status = .done(final == nil ? .failed(dropped ? "connection" : "timeout") : .nothing("not_heard"), at: now())
            return
        }
        status = .editing(instruction: instruction)
        recorder.edit(instruction, selection: selection()) { [weak self] outcome in
            guard let self, self.run == myRun else { return }
            self.status = .done(outcome, at: self.now())
        }
    }

    /// Esc: the command is dropped (its words go nowhere) and capture goes back to the notes.
    public func cancel() {
        guard status.isListening else { return }
        Task { await abandon(nil) }
    }

    /// The chip or note went away.
    public func dismiss() {
        if case .done = status { status = .idle }
    }

    private func abandon(_ outcome: NotesEditOutcome?) async {
        run += 1
        listenTask?.cancel()
        eventsTask?.cancel()
        await release()
        if let session { await session.cancel() }
        session = nil
        status = outcome.map { .done($0, at: now()) } ?? .idle
    }

    private func release() async {
        if diverted {
            diverted = false
            await recorder.endDivert()
        }
        if microphone {
            microphone = false
            closeMicrophone()
        }
    }

    /// True once the command socket is done.
    private func handle(_ event: StreamEvent) -> Bool {
        switch event {
        case .message(.partial(_, let text, _, _)):
            heard = text
            if status.isListening { status = .listening(heard: text) }
            return false
        case .message(.final(let f)):
            ended(f.text)
            return true
        case .message(.error), .closed:
            ended(nil)
            return true
        default:
            return false
        }
    }

    /// The command socket is done: with its final's text, or nil when it failed or closed first.
    private func ended(_ text: String?) {
        guard final == nil, !dropped else { return }
        if let text { final = text } else { dropped = true }
        if finalWaiter != nil {
            resumeWaiter()
        } else if status.isListening {
            // It ended while still listening (a drop, the 120 s cap): end the command with what it has.
            Task { await self.finish() }
        }
    }

    private func resumeWaiter() {
        let w = finalWaiter
        finalWaiter = nil
        w?.resume()
    }
}
