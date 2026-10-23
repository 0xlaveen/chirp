import AVFoundation
import ChirpCore
import ChirpIOSCore
import Combine
import Foundation
import UIKit

enum SessionAction { case start, stop, toggle, cancel, end }
enum DictationSource { case app, keyboard, companion }

struct AppServices {
    let pairing: PairingStore
    let preferences: PreferenceStore
    let history: HistoryStore
    let bridge: SharedBridge
    let keyboardSetup: KeyboardSetupStore
    init(root: URL, secrets: any SecretStore) throws {
        pairing = try PairingStore(root: root, secrets: secrets)
        preferences = try PreferenceStore(root: root)
        history = try HistoryStore(root: root, secrets: secrets)
        bridge = try SharedBridge(root: root, secrets: secrets, role: .app)
        keyboardSetup = try KeyboardSetupStore(root: root)
    }
    static func production() throws -> Self {
        let config = SharedConfiguration(bundle: .main)
        return try Self(root: config.containerURL(), secrets: KeychainSecretStore(accessGroup: config.keychainAccessGroup))
    }
}

/// Single app-process owner, reused by App Intents. Neither extension captures or streams audio.
@MainActor
final class SessionCoordinator: ObservableObject {
    static let shared = SessionCoordinator()
    @Published private(set) var phase: SessionPhase = .idle
    @Published private(set) var armed = false
    @Published private(set) var working = false
    @Published private(set) var text = ""
    @Published private(set) var raw = ""
    @Published private(set) var words: [WordTiming] = []
    @Published private(set) var health: Health?
    @Published private(set) var paired = false
    @Published private(set) var notice = ""
    @Published private(set) var debugRetention = false
    @Published private(set) var canUseRaw = false
    /// Chirp Keyboard has opened with Full Access at least once (see `KeyboardSetupStore`).
    @Published private(set) var keyboardReady = false
    @Published var preferences = IOSPreferences()
    @Published private(set) var profiles: [CorrectionProfile] = []
    @Published private(set) var diagnostics: [DiagnosticEvent] = []
    private(set) var services: AppServices?
    private let audio: any SessionAudio
    private let http: URLSession
    private let makeStream: (ServerConfig, StartOptions, URLSession) -> StreamSession
    private let requestPermission: () async -> Bool
    private let permissionGranted: () -> Bool
    private let activityBegin: (Bool) throws -> Void
    private let activityActive: () -> Bool
    private let activityUpdate: (String, Bool) async -> Void
    private let activityEnd: () async -> Void
    private let copyText: (String) -> Void
    private let appActive: () -> Bool
    private let now: () -> Date
    private var config: ServerConfig?
    private var generation = UUID()
    private var lifecycle = UUID()
    private var utterance: UUID?
    private var companion: UUID?
    private var utteranceSource: DictationSource?
    private var privateUtterance = false
    private var sequence = 0
    private var lastServerSequence = -1
    private var stream: StreamSession?
    private var ready = false
    private var stopRequested = false
    private var expiresAt: Date?
    private var heartbeat: Task<Void, Never>?
    private var expiry: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var utteranceLimit: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var rawExpiry: Task<Void, Never>?
    private var observation: DarwinObservation?
    private var activityTeardown: Task<Void, Never>?
    private var systemObservers: [NSObjectProtocol] = []
    private var waiters: [UUID: [CheckedContinuation<Void, Error>]] = [:]
    private var historyID: UUID?
    private var startingUtterance = false
    private let signal = DarwinSignal(name: DarwinSignal.bridgeChanged)

    init(services: AppServices? = nil, audio: (any SessionAudio)? = nil,
         http: URLSession = SafeHTTPSession.make(),
         makeStream: @escaping (ServerConfig, StartOptions, URLSession) -> StreamSession = { StreamSession(config: $0, options: $1, urlSession: $2) },
         requestPermission: @escaping () async -> Bool = { await AVAudioApplication.requestRecordPermission() },
         permissionGranted: @escaping () -> Bool = { AVAudioApplication.shared.recordPermission == .granted },
         activityBegin: @escaping (Bool) throws -> Void = { try ChirpLiveActivity.begin(debugRetention: $0) },
         activityActive: @escaping () -> Bool = { ChirpLiveActivity.isActive },
         activityUpdate: @escaping (String, Bool) async -> Void = { await ChirpLiveActivity.update(phase: $0, debugRetention: $1) },
         activityEnd: @escaping () async -> Void = { await ChirpLiveActivity.end() },
         copyText: @escaping (String) -> Void = { UIPasteboard.general.string = $0 },
         appActive: @escaping () -> Bool = { UIApplication.shared.applicationState == .active },
         now: @escaping () -> Date = Date.init,
         production: Bool = true) {
        #if DEBUG
        self.audio = audio ?? SimulatorFileAudio.fromArguments() ?? MicrophoneCapture()
        #else
        self.audio = audio ?? MicrophoneCapture()
        #endif
        self.http = http; self.makeStream = makeStream; self.requestPermission = requestPermission; self.permissionGranted = permissionGranted
        self.activityBegin = activityBegin; self.activityActive = activityActive
        self.activityUpdate = activityUpdate; self.activityEnd = activityEnd; self.copyText = copyText; self.appActive = appActive; self.now = now
        do {
            let stores = try services ?? (production ? AppServices.production() : nil)
            self.services = stores
            preferences = try stores?.preferences.load() ?? IOSPreferences()
            config = try stores?.pairing.load()
            paired = config != nil
            try stores?.bridge.endSession()
        } catch { notice = SessionFailure.storage.localizedDescription }
        refreshSetup()
        guard production else { return }
        observation = signal.observe { [weak self] in Task { @MainActor in self?.processCommands() } }
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification,
                     AVAudioSession.mediaServicesWereResetNotification] {
            systemObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                if name == AVAudioSession.routeChangeNotification,
                   let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                   AVAudioSession.RouteChangeReason(rawValue: raw) == .categoryChange { return }
                if name == AVAudioSession.interruptionNotification,
                   let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                   AVAudioSession.InterruptionType(rawValue: raw) == .ended { return }
                MainActor.assumeIsolated {
                    guard let self, self.armed else { return }
                    let ticket = self.lifecycle
                    Task { @MainActor in
                        guard self.armed, self.lifecycle == ticket else { return }
                        self.endSession(code: .interrupted)
                    }
                }
            })
        }
    }

    func pair(link: String) async {
        guard !working, !armed, let services else { return }
        working = true
        let ticket = lifecycle
        defer { working = false }
        do {
            let credentials = try PairingLink.parse(link)
            let checked = try await services.pairing.verifyAndSave(credentials, session: http)
            guard ticket == lifecycle else { return }
            config = try services.pairing.load(); paired = config != nil
            applyHealth(checked)
            notice = "Mac verified and pairing saved."
            await loadProfiles()
        } catch { notice = "Could not verify pairing. Check the link, Tailscale and your Mac."; record(.auth) }
    }

    func forgetPairing() {
        endSession()
        do { try services?.pairing.clear(); config = nil; paired = false; health = nil; profiles = [] }
        catch { notice = SessionFailure.storage.localizedDescription }
        preferences.correction = false; preferences.consentHost = nil; savePreferences()
    }

    func checkConnection() async {
        guard let config, !working else { return }
        working = true
        let ticket = lifecycle
        defer { working = false }
        do {
            let checked = try await config.fetchHealth(session: http)
            guard ticket == lifecycle else { return }
            guard checked.ok, checked.ready == true, checked.engine != nil else { throw SessionFailure.connection }
            applyHealth(checked); notice = "Mac connection verified."
            await loadProfiles()
        } catch { notice = SessionFailure.connection.localizedDescription; if armed { endSession(code: .unreachable) } }
    }

    private func applyHealth(_ value: Health) {
        let changed = health?.correctionLeavesMachine != value.correctionLeavesMachine || health?.correctionHost != value.correctionHost
        if changed || !value.correctionAvailable {
            preferences.correction = false; preferences.consentHost = nil; savePreferences()
        }
        health = value; debugRetention = value.debugRetention == true
    }
    var pairedHost: String { config?.host ?? "" }

    func loadProfiles() async {
        guard let config else { return }
        let ticket = lifecycle
        struct Response: Decodable { let profiles: [CorrectionProfile] }
        do {
            var request = config.authorized(URLRequest(url: config.baseURL.appendingPathComponent("v1/correction/profiles")))
            request.timeoutInterval = 10
            let (data, response) = try await http.data(for: request)
            guard ticket == lifecycle else { return }
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 256 * 1024 else { throw SessionFailure.connection }
            let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
            let fetched = try decoder.decode(Response.self, from: data).profiles
            guard fetched.count <= 32 else { throw SessionFailure.connection }
            profiles = fetched
            if !profiles.contains(where: { $0.id == preferences.styleID }) { preferences.styleID = "default"; savePreferences() }
        } catch { profiles = []; notice = "Style prompts unavailable. Check your Mac connection." }
    }

    var cleanupDisclosure: String {
        guard let health, health.correctionAvailable else { return "Mac has clean-up off." }
        if health.correctionLeavesMachine == false { return "Clean-up runs on your Mac." }
        if health.correctionLeavesMachine == true, let host = health.correctionHost, !host.isEmpty { return "Sends final text to \(host). Audio stays on your Mac." }
        return "Clean-up destination is unknown. Clean-up is unavailable."
    }
    var cleanupCanEnable: Bool {
        guard let health, health.correctionAvailable else { return false }
        return health.correctionLeavesMachine == false || (health.correctionLeavesMachine == true && health.correctionHost?.isEmpty == false)
    }
    func setCleanup(_ enabled: Bool) {
        preferences.correction = enabled && cleanupCanEnable
        preferences.consentHost = enabled && health?.correctionLeavesMachine == true ? health?.correctionHost : nil
        savePreferences()
    }
    func selectStyle(_ id: String) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        preferences.styleID = id; savePreferences(); publishState()
    }
    func editPrompt(_ text: String, profile: CorrectionProfile) {
        preferences.prompts[profile.id] = CorrectionProfile.clampPrompt(text, limit: min(4000, profile.maxPromptChars))
        savePreferences()
    }
    func resetPrompt(_ id: String) { preferences.prompts.removeValue(forKey: id); savePreferences() }
    func savePreferences() {
        if preferences.privacyMode { privateUtterance = true }
        do { try services?.preferences.save(preferences) }
        catch { notice = SessionFailure.storage.localizedDescription; record(.storage) }
    }

    func armSession() async throws {
        if armed { try reconcileOrThrow(); return }
        guard !working, let config, services != nil else { throw SessionFailure.setup }
        working = true
        let ticket = lifecycle
        defer { working = false }
        guard await requestPermission() else { throw SessionFailure.permission }
        guard ticket == lifecycle else { throw SessionFailure.cancelled }
        let checked: Health
        do { checked = try await config.fetchHealth(session: http) }
        catch { throw SessionFailure.connection }
        guard ticket == lifecycle, checked.ok, checked.ready == true, checked.engine != nil else { throw SessionFailure.connection }
        applyHealth(checked)
        await activityTeardown?.value
        guard ticket == lifecycle else { throw SessionFailure.cancelled }
        try activityBegin(debugRetention)
        do {
            try audio.arm { [weak self] in Task { @MainActor in
                guard let self, self.armed, self.lifecycle == ticket else { return }
                self.endSession(code: .interrupted)
            } }
        } catch { await activityEnd(); throw SessionFailure.audio }
        armed = true; generation = UUID(); expiresAt = preferences.sessionDuration.seconds.map { now().addingTimeInterval($0) }
        setPhase(.armed)
        guard armed else { throw SessionFailure.storage }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                do {
                    try self.reconcileOrThrow()
                    await self.activityUpdate(self.phase.rawValue, self.debugRetention)
                    guard !Task.isCancelled, self.armed else { return }
                    self.publishState(); self.processCommands()
                }
                catch { self.endSession(code: .interrupted); return }
            }
        }
        if let seconds = preferences.sessionDuration.seconds {
            expiry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                self?.endSession(code: .timeout)
            }
        }
    }

    func begin(source: DictationSource = .app, id: UUID = UUID()) async throws {
        guard !startingUtterance, stream == nil else { throw SessionFailure.setup }
        startingUtterance = true
        defer { startingUtterance = false }
        let ticket = lifecycle
        let wasArmed = armed
        try await armSession()
        guard ticket == lifecycle else { throw SessionFailure.cancelled }
        if wasArmed, let config {
            let checked: Health
            do { checked = try await config.fetchHealth(session: http) }
            catch { endSession(code: .unreachable); throw SessionFailure.connection }
            guard ticket == lifecycle, armed else { throw SessionFailure.cancelled }
            guard checked.ok, checked.ready == true, checked.engine != nil else { endSession(code: .unreachable); throw SessionFailure.connection }
            applyHealth(checked)
        }
        try reconcileOrThrow()
        guard stream == nil, let config else { throw SessionFailure.setup }
        clearUtterance()
        utterance = id; companion = source == .companion ? id : nil; utteranceSource = source
        privateUtterance = preferences.privacyMode
        var options = StartOptions(client: "ios", correction: health.map { preferences.permitsCorrection(health: $0) } ?? false,
                                   correctionProfile: preferences.styleID, wordTimings: true)
        if let prompt = preferences.prompts[preferences.styleID] {
            let limit = profiles.first { $0.id == preferences.styleID }?.maxPromptChars ?? 4000
            options.correctionPrompt = CorrectionProfile.clampPrompt(prompt, limit: min(4000, limit))
        }
        let session = makeStream(config, options, http)
        stream = session
        do {
            try audio.begin(stream: session, onFailure: { [weak self] in Task { @MainActor in
                guard let self, self.armed, self.lifecycle == ticket, self.utterance == id else { return }
                self.endSession(code: .interrupted)
            } }, onLimit: { [weak self] in Task { @MainActor in
                guard let self, self.armed, self.lifecycle == ticket, self.utterance == id else { return }
                self.stopDictation()
            } })
        } catch { endSession(code: .interrupted); throw SessionFailure.audio }
        setPhase(.connecting)
        guard armed, utterance == id else { throw SessionFailure.storage }
        eventTask = Task { [weak self] in
            await session.open()
            for await event in session.events {
                guard !Task.isCancelled, let self, self.utterance == id, self.stream === session, self.armed else { return }
                self.receive(event, id: id)
            }
        }
        utteranceLimit = Task { [weak self] in
            // Leave one second for converter delay and scheduling before the protocol's hard 120s cap.
            try? await Task.sleep(for: .seconds(119))
            guard !Task.isCancelled, self?.utterance == id else { return }
            self?.stopDictation()
        }
    }

    func stopDictation() {
        guard let stream, !stopRequested else { return }
        stopRequested = true
        audio.finish() // serialized against tap conversion; trailing PCM is queued before stream.stop.
        utteranceLimit?.cancel()
        if ready { Task { await stream.stop() } }
        notice = "Finishing…"
        startDeadline(seconds: 20)
    }

    func cancelDictation() {
        let previous = stream
        clearUtterance(error: SessionFailure.cancelled)
        if let previous { Task { await previous.cancel() } }
        setPhase(armed ? .armed : .idle)
        // Publishing nil utterance ownership purges the previous utterance's encrypted results.
    }

    func endSession(code: DiagnosticCode? = nil) {
        lifecycle = UUID()
        armed = false
        audio.disarm()
        let previous = stream
        clearUtterance(error: SessionFailure.expired)
        heartbeat?.cancel(); heartbeat = nil; expiry?.cancel(); expiry = nil; expiresAt = nil
        generation = UUID(); phase = .idle
        if let code { record(code); notice = code == .timeout ? "Session ended." : "Session interrupted. Open Chirp to start again." }
        else { notice = "Session ended. Microphone off." }
        if let previous { Task { await previous.cancel() } }
        activityTeardown = Task { await activityEnd() }
        do { try services?.bridge.endSession(); signal.post() } catch { notice = SessionFailure.storage.localizedDescription }
    }

    func refreshSetup() { keyboardReady = (try? services?.keyboardSetup.fullAccessSeenAt()) != nil }

    func reconcile() { if armed { do { try reconcileOrThrow(); processCommands() } catch { endSession(code: .interrupted) } } }
    private func reconcileOrThrow() throws {
        guard armed else { throw SessionFailure.expired }
        if let expiresAt, now() >= expiresAt { endSession(code: .timeout); throw SessionFailure.expired }
        guard activityActive() else { throw SessionFailure.audio }
        guard permissionGranted() else { throw SessionFailure.permission }
    }

    private func receive(_ event: StreamEvent, id: UUID) {
        switch event {
        case .closed(let reason):
            if reason != nil {
                if phase == .correcting, !raw.isEmpty {
                    complete(FinalResult(text: raw), id: id)
                    notice = "Connection lost during clean-up. Kept original."
                    record(.unreachable)
                }
                else { endSession(code: .unreachable) }
            }
        case .message(let message):
            switch message {
            case .ready(_, _, let debug):
                guard !ready else { return }
                ready = true; debugRetention = debug; audio.ready()
                setPhase(.listening)
                if stopRequested, let stream { Task { await stream.stop() } }
            case .partial(let seq, let value, _, let timings):
                guard ready, !stopRequested, seq > lastServerSequence else { return }
                lastServerSequence = seq; text = value; words = timings ?? []
                publishResult(.partial, text: value)
            case .correcting(let seq, let value, _, let timings):
                guard ready, stopRequested, seq > lastServerSequence else { return }
                lastServerSequence = seq; raw = value; text = value; words = timings ?? []
                setPhase(.correcting); publishResult(.correcting, text: value, raw: value); startDeadline(seconds: 12)
            case .final(let result):
                guard ready, stopRequested else { return }
                complete(result, id: id)
            case .error(let code, _): endSession(code: DiagnosticCode.server(code))
            case .unknown: break
            }
        }
    }

    private func complete(_ result: FinalResult, id: UUID) {
        guard utterance == id, armed else { return }
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            cancelDictation(); notice = SessionFailure.noResult.localizedDescription; return
        }
        audio.discard(); deadline?.cancel(); utteranceLimit?.cancel()
        let finishedStream = stream; stream = nil
        if let finishedStream { Task { await finishedStream.close() } }
        text = result.text; raw = result.raw; words = result.words ?? []
        canUseRaw = result.canUseRaw
        setPhase(.finished)
        guard armed, utterance == id else { return }
        publishResult(.final, text: result.text, raw: result.raw)
        guard armed, utterance == id else { return }
        if !privateUtterance, !preferences.privacyMode {
            do { historyID = try services?.history.record(text: result.text, raw: result.raw, corrected: result.corrected)?.id }
            catch { notice = SessionFailure.storage.localizedDescription; record(.storage) }
        }
        if companion == id { copyText(result.text); companion = nil; notice = "Copied final text." }
        else { notice = result.corrected ? "Cleaned. Copy or share when ready." : "Finished. Copy or share when ready." }
        for waiter in waiters.removeValue(forKey: id) ?? [] { waiter.resume() }
        rawExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, self?.utterance == id else { return }
            self?.canUseRaw = false
        }
    }

    private func startDeadline(seconds: Double) {
        deadline?.cancel()
        let id = utterance
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.utterance == id else { return }
            if self.phase == .correcting, !self.raw.isEmpty, let id {
                let fallback = self.raw
                self.complete(FinalResult(text: fallback), id: id)
                self.notice = "Clean-up timed out. Kept original."
            } else { self.endSession(code: .timeout) }
        }
    }
    private func clearUtterance(error: Error = SessionFailure.cancelled) {
        eventTask?.cancel(); eventTask = nil; deadline?.cancel(); deadline = nil
        utteranceLimit?.cancel(); utteranceLimit = nil; rawExpiry?.cancel(); rawExpiry = nil
        audio.discard(); stream = nil; utterance = nil; companion = nil; utteranceSource = nil
        text = ""; raw = ""; words = []; canUseRaw = false; ready = false; stopRequested = false
        sequence = 0; lastServerSequence = -1; historyID = nil
        let pending = waiters; waiters.removeAll()
        for group in pending.values { for waiter in group { waiter.resume(throwing: error) } }
    }
    func useRaw() {
        guard canUseRaw, phase == .finished else { return }
        text = raw; canUseRaw = false; publishResult(.raw, text: raw, raw: raw)
        if let historyID {
            do { _ = try services?.history.useRaw(id: historyID) }
            catch { notice = SessionFailure.storage.localizedDescription; record(.storage) }
        }
    }
    func copy() { guard !text.isEmpty, phase == .finished else { return }; copyText(text); notice = "Copied." }

    /// Cold setup and permission requests need Chirp on screen; an armed session starts from anywhere.
    var needsForegroundToStart: Bool { !armed && !appActive() }

    func perform(action: SessionAction) async throws -> String {
        switch action {
        case .start:
            guard !needsForegroundToStart else { throw SessionFailure.setup }
            try await begin(source: .companion)
            return "Recording. Stop Chirp to copy the final text."
        case .stop:
            guard let id = utterance, stream != nil else { throw SessionFailure.noResult }
            let copies = companion == id // Only a companion-owned utterance copies; keyboard/app paths never copy.
            stopDictation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in waiters[id, default: []].append(continuation) }
            return copies ? "Copied. Paste with ⌘V." : "Dictation finished."
        case .toggle:
            // One action for a hardware-keyboard shortcut: start in an armed session, or stop and copy.
            if utterance != nil, stream != nil {
                // Keyboard dictation is never copied, so the shortcut leaves it to Chirp Keyboard.
                guard utteranceSource != .keyboard else { return "Chirp Keyboard is dictating. Stop it in the keyboard." }
                return try await perform(action: .stop)
            }
            _ = try await perform(action: .start)
            return "Recording. Run Toggle Chirp dictation again to stop and copy."
        case .cancel: cancelDictation(); return "Dictation cancelled."
        case .end: endSession(); return "Session ended. Microphone off."
        }
    }

    private func setPhase(_ value: SessionPhase) {
        phase = value; publishState()
        let expected = lifecycle
        Task { if expected == lifecycle { await activityUpdate(value.rawValue, debugRetention) } }
    }
    private func publishState() {
        guard armed, let services else { return }
        do {
            try services.bridge.publish(BridgeState(generation: generation, phase: phase, utteranceID: utterance,
                leaseUntil: now().addingTimeInterval(8), sessionExpiresAt: expiresAt, debugRetention: debugRetention,
                privacyMode: preferences.privacyMode, styleID: preferences.styleID,
                availableStyleIDs: profiles.isEmpty ? ["default"] : profiles.map(\.id)))
            signal.post()
        } catch { endSession(code: .storage) }
    }
    private func publishResult(_ kind: BridgeResultKind, text: String, raw: String? = nil) {
        guard let utterance, armed, let services else { return }
        sequence += 1
        do {
            try services.bridge.publish(BridgeResult(generation: generation, utteranceID: utterance, kind: kind,
                text: text, raw: raw, sequence: sequence, createdAt: now(), expiresAt: now().addingTimeInterval(8)))
            signal.post()
        } catch { endSession(code: .storage) }
    }
    private func processCommands() {
        guard armed, let services else { return }
        do {
            try reconcileOrThrow()
            for command in try services.bridge.takeCommands(generation: generation) {
                switch command.action {
                case .start:
                    guard stream == nil, let id = command.utteranceID else { continue }
                    let expected = generation
                    Task {
                        guard armed, expected == generation else { return }
                        do { try await begin(source: .keyboard, id: id) }
                        catch { notice = "Dictation unavailable. Finish the current utterance first." }
                    }
                case .stop: if command.utteranceID == utterance { stopDictation() }
                case .cancel: if command.utteranceID == utterance { cancelDictation() }
                case .end: endSession(); return
                case .useRaw: if command.utteranceID == utterance { useRaw() }
                case .style(let id): if stream == nil { selectStyle(id) }
                case .privacy(let enabled): preferences.privacyMode = enabled; savePreferences(); publishState()
                }
            }
        } catch { endSession(code: .storage) }
    }
    private func record(_ code: DiagnosticCode) {
        diagnostics.append(DiagnosticEvent(phase: phase, code: code))
        diagnostics = Array(diagnostics.suffix(200))
    }
    func show(_ error: Error) {
        notice = (error as? SessionFailure)?.localizedDescription ?? "Unable to start. Open Chirp and check microphone, connection and Live Activity settings."
    }
    var diagnosticText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let events = (try? DiagnosticExport.data(events: diagnostics)) ?? Data("[]".utf8)
        return "Chirp \(version) · iOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)\n" + String(decoding: events, as: UTF8.self)
    }
}
