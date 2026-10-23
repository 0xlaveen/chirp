import AppKit
import ChirpCore

/// What the Settings window shows. The window controller reads it from the system; the snapshots pass fixed values.
public struct SettingsState: Sendable {
    public var hotkey: KeyCombo = .controlOptionSpace
    /// "Open Notes" shortcut and "Always show Chirp in the Dock".
    public var openNotesHotkey: KeyCombo = .controlOptionShiftN
    public var alwaysShowInDock = false
    public var activationMode: ActivationMode = .autoStop
    /// Dictation: press Return after inserting (off by default).
    public var autoEnter: AutoEnter = .off
    /// Auto-stop: seconds of quiet that end a dictation.
    public var autoStopSilence = AutoStopDetector.defaultSilence
    public var serverURL = ServerConfig.defaultURL.absoluteString
    public var tokenPresent = true
    public var launch: LaunchState = .off
    /// General: the HUD's word waveform (each word's audio above it). Off by default.
    public var wordWaveform = false
    /// Notes: Live Notes keeps a recovery copy of unsaved notes (on by default).
    public var notesRecoveryCopy = true
    public var soundsEnabled = false
    public var soundPack: SoundPack = .default
    /// 0…1.
    public var soundVolume = SoundTiming.defaultVolume
    /// The user's own files for the Custom pack, as imported.
    public var customStart: CustomSound?
    public var customStop: CustomSound?
    public var micGranted = true
    public var accessibilityGranted = true
    /// The server's state in words ("Connected", "Unreachable", …) and its tone.
    public var serverStatus = "Connected"
    public var serverStatusTone: MenuEntry.Tone = .ok
    /// The server is older than the app: what to say and the button that fixes it; the last fix attempt's result.
    public var serverNotice: ServerNotice?
    public var serverFixMessage: String?
    /// Clean-up: on or off, the default style, the edited style prompts, the raw-first option and the per-app styles.
    public var cleanupEnabled = false
    /// Where clean-up runs, or that the server has it off (under the checkbox), and whether it can be turned on.
    public var cleanupDetail = "Tidies punctuation and wording before the text is inserted."
    public var cleanupAvailable = true
    public var cleanupStyle = CorrectionProfile.defaultID
    /// The prompts the user edited, by style id (only styles that differ from the server's default).
    public var stylePrompts: [String: String] = [:]
    /// The styles with their default prompts, and whether they are live, the last-known copy, or not loaded.
    public var catalog = StyleCatalog.unavailable
    /// The style the prompt editor opens on.
    public var editingStyle = CorrectionProfile.defaultID
    public var insertRawFirst = false
    /// "Use raw" stays on offer for 5 seconds after a cleaned insertion (the hotkey and the menu row).
    public var offerRaw = true
    /// "Show changes after clean-up": the diff highlight and the HUD's Use raw button. Off by default.
    public var showChanges = false
    public var appStyles = AppStyleRule.defaults
    /// The styles the server offers (the built-ins until it says otherwise) and whether it offers any at all.
    public var profiles = CorrectionProfile.builtIn
    public var serverOffersStyles = true
    /// "Keep clean-up model loaded": what the server last said, and where its memory is used ("this Mac" or the host).
    public var keepLoaded = KeepLoadedState()
    public var serverHost = "this Mac"
    /// Some of Live Notes' speaker-label model is on this Mac, complete or not (Remove deletes it).
    public var speakerModelDownloaded = false
    /// Dictation: every input device, the system default among them, and the one the user picked (nil follows the default).
    public var inputs: [AudioInput] = []
    public var defaultInput: AudioInput?
    public var chosenInputUID: String?
    /// About: the version from the app bundle.
    public var about = AboutInfo()

    public init() {}
}

/// The preferences window's toolbar tabs, in order: one per task (start Chirp and fix permissions; how a dictation
/// starts, sounds and where it listens; clean-up; Live Notes; the server and its models; phones; the version).
public enum SettingsTab: String, CaseIterable, Sendable {
    case general, dictation, cleanup, notes, server, devices, about

    public var title: String {
        switch self {
        case .general: "General"
        case .dictation: "Dictation"
        case .cleanup: "Clean-up"
        case .notes: "Notes"
        case .server: "Server"
        case .devices: "Devices"
        case .about: "About"
        }
    }

    /// The toolbar icon (SF Symbol).
    public var symbol: String {
        switch self {
        case .general: "gearshape"
        case .dictation: "mic"
        case .cleanup: "sparkles"
        case .notes: "note.text"
        case .server: "server.rack"
        case .devices: "iphone"
        case .about: "info.circle"
        }
    }
}

/// A tab's content view. It accepts first responder so the window can park focus here instead of on a text field,
/// which would otherwise open selected.
public final class SettingsContentView: NSView {
    override public var acceptsFirstResponder: Bool { true }
}

/// The Settings window content, plain AppKit on purpose: the Command Line Tools toolchain has no SwiftUI macro
/// plugins (@State etc.). One view per toolbar tab (`SettingsTab`): labels right-aligned in one column and controls
/// left-aligned in a second, with help text below its control and a little more space between groups of rows. Every
/// tab is as wide as the widest (so the window keeps its width and its toolbar), with the form centred and each tab
/// as tall as its content. All controls live here and are exposed so the owner can attach targets and actions.
@MainActor
public final class SettingsForm {
    static let margin: CGFloat = 20
    static let controlWidth: CGFloat = 340
    /// Extra space above the first row of a group.
    static let groupSpacing: CGFloat = 12
    /// Narrowest a tab may be: room for the seven toolbar tabs (they need about 420 pt) without an overflow chevron.
    static let minimumWidth: CGFloat = 440

    /// One content view per tab, holding its body (a grid, or the About view) with a 20 pt margin above and below.
    private var tabViews: [SettingsTab: SettingsContentView] = [:]
    private var bodies: [SettingsTab: NSView] = [:]
    public let hotkey = NSPopUpButton(frame: .zero, pullsDown: false)
    public let recorder = HotkeyRecorder()
    public let openNotes = NotesShortcutControls()
    /// Under the hotkey: how it works, or why the last recording was refused.
    public let hotkeyHelp = SettingsForm.help("")
    /// Fn/Globe has a separate macOS action that the user must turn off in Keyboard settings.
    public let fnKeyHelp = SettingsForm.help("To use fn / 🌐 without opening emoji or another macOS action, open System Settings → Keyboard and set “Press 🌐 key to” to “Do Nothing”.")
    public let keyboardSettingsButton = NSButton(title: "Open Keyboard Settings…", target: nil, action: nil)
    private var fnKeySetupRow: NSGridRow?
    /// Auto-stop or hold to talk, and (auto-stop only) how long a pause ends the dictation.
    public let mode = NSPopUpButton(frame: .zero, pullsDown: false)
    public let silence = NSPopUpButton(frame: .zero, pullsDown: false)
    /// Press Return after inserting: Off, Always, or in chat apps only.
    public let autoEnter = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modeHelp = SettingsForm.help("")
    private var shownHotkey = KeyCombo.controlOptionSpace
    public let sounds = NSButton(checkboxWithTitle: "Play start and stop sounds", target: nil, action: nil)
    /// Sounds: the pack, ▶ previews, the volume, and (for the Custom pack) the user's files.
    public let soundPack = NSPopUpButton(frame: .zero, pullsDown: false)
    public let previewStart = NSButton(title: "▶ Start", target: nil, action: nil)
    public let previewStop = NSButton(title: "▶ Stop", target: nil, action: nil)
    public let volume = NSSlider(value: SoundTiming.defaultVolume * 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    public let chooseStart = NSButton(title: "Choose…", target: nil, action: nil)
    public let removeStart = NSButton(title: "Remove", target: nil, action: nil)
    public let chooseStop = NSButton(title: "Choose…", target: nil, action: nil)
    public let removeStop = NSButton(title: "Remove", target: nil, action: nil)
    /// Under the start file: the 0.3 s rule, or why the last import failed.
    public let customStartHelp = SettingsForm.help("")
    private let packHelp = SettingsForm.help("")
    private let volumeLabel = NSTextField(labelWithString: "")
    private let startFile = NSTextField(labelWithString: "")
    private let stopFile = NSTextField(labelWithString: "")
    private var customStartSound: CustomSound?
    private var customStopSound: CustomSound?
    private var soundError: String?
    /// The Start sound and Stop sound rows of the Dictation grid, shown only for the Custom pack.
    private var customRows: [Int] = []
    private var soundsGrid: NSGridView { grids[.dictation]! }
    /// Dictation: the input device, as in the menu's Microphone submenu.
    public let microphone = NSPopUpButton(frame: .zero, pullsDown: false)
    private var shownMicrophones: [String]?
    public let serverURL = NSTextField(string: "")
    public let launch = NSButton(checkboxWithTitle: "Launch Chirp at login", target: nil, action: nil)
    /// General: the HUD's word waveform.
    public let wordWaveform = NSButton(checkboxWithTitle: "Word waveform overlay", target: nil, action: nil)
    /// Notes: Live Notes' recovery copy of unsaved notes.
    public let notesRecoveryCopy = NSButton(checkboxWithTitle: NotesStatus.recoverySwitch, target: nil, action: nil)
    /// General: reopens the setup walk-through.
    public let setupButton = NSButton(title: "Set Up Chirp…", target: nil, action: nil)
    /// Server: puts the chirp-server doctor command on the pasteboard.
    public let doctorButton = NSButton(title: "Copy Doctor Command", target: nil, action: nil)
    public let modelsButton = NSButton(title: "Manage Local Models…", target: nil, action: nil)
    /// Devices: opens the pairing window (Tailscale check and QR code).
    public let pairButton = NSButton(title: "Pair a Phone…", target: nil, action: nil)
    /// Notes: deletes Live Notes' on-device speaker model (shown beside its status while it is on this Mac).
    public let removeSpeakerModel = NSButton(title: "Remove", target: nil, action: nil)
    private let speakerStatus = StatusLine()
    private let speakerHelp = SettingsForm.help("")
    /// Notes: brings the Notes window forward.
    public let notesButton = NSButton(title: "Open Notes Window", target: nil, action: nil)
    /// About: the icon, the version and Third-Party Notices….
    public let about: AboutView
    /// Server: "Restart server" or "Use Chirp’s managed server instead", shown only for an out-of-date server.
    public let serverFixButton = NSButton(title: ServerFix.restart.buttonTitle, target: nil, action: nil)
    private let serverDetail = SettingsForm.help("")
    public let micButton = NSButton(title: "Fix…", target: nil, action: nil)
    public let accessibilityButton = NSButton(title: "Fix…", target: nil, action: nil)
    /// Under the checkbox: what it does, or why the last change failed.
    public let launchHelp = SettingsForm.help("")
    /// Clean-up: default style, style prompts, raw-first and the per-app table.
    public let cleanupEnabled = NSButton(checkboxWithTitle: "Clean up dictated text", target: nil, action: nil)
    public let style = NSPopUpButton(frame: .zero, pullsDown: false)
    public let prompts = StylePromptsEditor()
    public let insertRawFirst = NSButton(checkboxWithTitle: "Insert raw immediately, then replace with cleaned", target: nil, action: nil)
    public let showChanges = NSButton(checkboxWithTitle: "Show changes after clean-up", target: nil, action: nil)
    public let offerRaw = NSButton(checkboxWithTitle: "Offer “Use raw” for 5 seconds after clean-up", target: nil, action: nil)
    public let appStyles = AppStylesTable()
    /// Clean-up: keeps the server's clean-up model in memory. Its state, memory cost and any error sit under it.
    public let keepLoaded = NSButton(checkboxWithTitle: KeepLoaded.title, target: nil, action: nil)
    private let keepLoadedStatus = StatusLine()
    private let keepLoadedHelp = SettingsForm.help("")
    private let keepLoadedError = SettingsForm.help("")
    private let styleHelp = SettingsForm.help("")
    private let cleanupHelp = SettingsForm.help("")
    private var grids: [SettingsTab: NSGridView] = [:]
    private var shownProfileIDs: [String] = []
    private var shownCatalog: StyleCatalog?
    private let tokenStatus = StatusLine()
    private let tokenHelp = SettingsForm.help("")
    private let serverStatus = StatusLine()
    private let micStatus = StatusLine()
    private let accessibilityStatus = StatusLine()
    private var launchUnavailable = false

    public init(_ state: SettingsState, icon: NSImage? = nil, onNotices: (() -> Void)? = nil) {
        about = AboutView(icon: icon, info: state.about, onNotices: onNotices)
        recorder.onStatusChange = { [weak self] _ in self?.refreshHotkeyHelp() }
        serverURL.placeholderString = ServerConfig.defaultURL.absoluteString
        serverURL.font = MenuStyle.font
        serverURL.lineBreakMode = .byTruncatingMiddle
        serverURL.widthAnchor.constraint(equalToConstant: Self.controlWidth).isActive = true
        for button in [micButton, accessibilityButton, removeSpeakerModel] { button.bezelStyle = .rounded; button.controlSize = .small }
        micStatus.accessory = micButton
        serverFixButton.bezelStyle = .rounded; serverFixButton.controlSize = .small
        serverFixButton.setAccessibilityLabel("Fix the out-of-date server")
        serverStatus.accessory = serverFixButton
        serverDetail.isHidden = true
        let serverStack = NSStackView(views: [serverStatus, serverDetail])
        serverStack.orientation = .vertical
        serverStack.alignment = .leading
        serverStack.spacing = 4
        accessibilityStatus.accessory = accessibilityButton
        speakerStatus.accessory = removeSpeakerModel
        micButton.setAccessibilityLabel("Fix Microphone access")
        accessibilityButton.setAccessibilityLabel("Fix Accessibility access")
        removeSpeakerModel.setAccessibilityLabel("Remove the speaker model")
        speakerStatus.setAccessibilityLabel("Speaker model")
        microphone.setAccessibilityLabel("Microphone")
        (microphone.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingTail
        microphone.widthAnchor.constraint(lessThanOrEqualToConstant: Self.controlWidth).isActive = true

        for button in [setupButton, doctorButton, modelsButton, pairButton, notesButton] { button.bezelStyle = .rounded }
        setupButton.setAccessibilityLabel("Set up Chirp")
        keyboardSettingsButton.bezelStyle = .rounded
        keyboardSettingsButton.controlSize = .small

        func row(_ title: String, _ control: NSView, help: NSTextField? = nil) -> [NSView] {
            var content = control
            if let help {
                let stack = NSStackView(views: [control, help])
                stack.orientation = .vertical
                stack.alignment = .leading
                stack.spacing = 4
                content = stack
            }
            return [Self.label(title), content]
        }

        func stack(_ views: [NSView]) -> NSStackView {
            let stack = NSStackView(views: views)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 4
            return stack
        }

        build(.general, [
            row("Startup:", launch, help: launchHelp),
            row("Dock:", openNotes.alwaysInDock),
            row("Permissions:", stack([micStatus, accessibilityStatus]),
                help: Self.help("The microphone lets Chirp hear you; Accessibility lets it insert text into other apps and send ⌘V.")),
            row("Setup:", setupButton, help: Self.help("Check the permissions and the server, and try a dictation.")),
        ], groups: [2])

        let hotkeyRow = NSStackView(views: [hotkey, recorder])
        hotkeyRow.orientation = .horizontal
        hotkeyRow.spacing = 10
        let packRow = NSStackView(views: [soundPack, previewStart, previewStop])
        packRow.orientation = .horizontal
        packRow.spacing = 8
        let volumeRow = NSStackView(views: [volume, volumeLabel])
        volumeRow.orientation = .horizontal
        volumeRow.spacing = 8
        build(.dictation, [
            row("Hotkey:", hotkeyRow, help: hotkeyHelp),
            row("", stack([fnKeyHelp, keyboardSettingsButton])),
            row("Mode:", mode, help: modeHelp),
            row("Auto-stop:", silence),
            row("Microphone:", microphone, help: Self.help("Follows the system default unless you pick one. Applies from the next dictation.")),
            row("Overlay:", wordWaveform, help: Self.help("Draws each word's audio above it as you speak, so you can see what was heard.")),
            row("Return:", autoEnter, help: Self.help("Sends a chat message after inserting. Hold ⇧ when you stop to skip it. Chat apps are those set to the Chat style.")),
            row("Sounds:", sounds, help: Self.help("Quiet sounds when dictation starts and stops. Off keeps Chirp silent.")),
            row("Pack:", packRow, help: packHelp),
            row("Volume:", volumeRow),
            row("Start sound:", Self.fileRow(startFile, choose: chooseStart, remove: removeStart), help: customStartHelp),
            row("Stop sound:", Self.fileRow(stopFile, choose: chooseStop, remove: removeStop),
                help: Self.help("Plays after you stop talking, up to \(SoundTiming.stopLimit) s.")),
        ], groups: [4, 7], customRows: [10, 11])
        fnKeySetupRow = grids[.dictation]?.row(at: 1)

        build(.cleanup, [
            row("Clean-up:", cleanupEnabled, help: cleanupHelp),
            row("Style:", style, help: styleHelp),
            row("Prompts:", prompts.view),
            row("Per-app:", appStyles.view, help: Self.help("The frontmost app when you start dictating picks the style. Other apps use the default style.")),
            row("Insertion:", insertRawFirst, help: Self.help("Swaps in the cleaned text in place where Chirp can verify the insert; elsewhere it inserts once.")),
            row("Review:", showChanges, help: Self.help("Off: the cleaned text is inserted at once. On: the HUD highlights what changed and keeps a Use raw button.")),
            row("Undo:", offerRaw, help: Self.help("Puts the original words back, with ⌃⌥Z or from the menu.")),
        ], groups: [4])

        let notesShortcut = NSTextField(labelWithString: MenuContent.notesHotkeyTitle)
        notesShortcut.font = MenuStyle.font
        build(.notes, [
            row("Shortcut:", notesShortcut,
                help: Self.help("Starts and stops Live Notes from any app. It is fixed; if another app owns it, use Start Notes in the menu.")),
            row("Open Notes:", openNotes.shortcutView),
            row("Recovery:", notesRecoveryCopy, help: Self.help(NotesStatus.recoveryHelp)),
            row("Speakers:", stack([speakerStatus, speakerHelp])),
            row("Window:", notesButton,
                help: Self.help("Structure notes, Auto-reorganize and Label speakers are switches in the window's footer, so you can change them while you record.")),
        ], groups: [2])

        let keepLoadedStack = stack([keepLoaded, keepLoadedStatus, keepLoadedHelp, keepLoadedError])
        keepLoadedError.textColor = .systemRed
        keepLoadedError.isHidden = true
        keepLoadedStatus.setAccessibilityLabel("Clean-up model status")
        build(.server, [
            row("URL:", serverURL),
            row("Token:", tokenStatus, help: tokenHelp),
            row("Status:", serverStack),
            row("Clean-up:", keepLoadedStack),
            row("Models:", modelsButton, help: Self.help("Download speech and local Qwen models, see progress, and start this Mac's server.")),
            row("Doctor:", doctorButton, help: Self.help("Copies the command that checks the server, to run in Terminal.")),
        ], groups: [3])

        build(.devices, [
            row("Phone:", pairButton, help: Self.help("Shows a QR code for Chirp on Android or iPhone. The phone reaches this Mac’s server over your tailnet only.")),
        ])

        place(.about, about)
        for m in ActivationMode.allCases {
            mode.addItem(withTitle: m.title)
            mode.lastItem?.representedObject = m.rawValue
        }
        for m in AutoEnter.allCases {
            autoEnter.addItem(withTitle: m.title)
            autoEnter.lastItem?.representedObject = m.rawValue
        }
        for seconds in AutoStopDetector.silenceChoices {
            silence.addItem(withTitle: "After \(seconds.formatted(.number.precision(.fractionLength(0...1)))) s of quiet")
            silence.lastItem?.representedObject = seconds
        }
        refreshHotkeyHelp()
        configureSoundControls()
        apply(state, full: true)
        // Every tab takes the shared width, below required so a body that grows still keeps its margins.
        let width = commonWidth
        for view in tabViews.values {
            let c = view.widthAnchor.constraint(equalToConstant: width)
            c.priority = .defaultHigh
            c.isActive = true
        }
    }

    private func configureSoundControls() {
        for pack in SoundPack.allCases {
            soundPack.addItem(withTitle: pack.title)
            soundPack.lastItem?.representedObject = pack.rawValue
        }
        for b in [previewStart, previewStop, chooseStart, removeStart, chooseStop, removeStop] {
            b.bezelStyle = .rounded
            b.controlSize = .small
        }
        previewStart.setAccessibilityLabel("Preview the start sound")
        previewStop.setAccessibilityLabel("Preview the stop sound")
        chooseStart.setAccessibilityLabel("Choose a start sound file")
        chooseStop.setAccessibilityLabel("Choose a stop sound file")
        removeStart.setAccessibilityLabel("Remove the custom start sound")
        removeStop.setAccessibilityLabel("Remove the custom stop sound")
        soundPack.setAccessibilityLabel("Sound pack")
        volume.isContinuous = true
        volume.setAccessibilityLabel("Volume")
        volume.widthAnchor.constraint(equalToConstant: 200).isActive = true
        volumeLabel.font = MenuStyle.font
        volumeLabel.alignment = .right
        volumeLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true
        for f in [startFile, stopFile] {
            f.font = MenuStyle.font
            f.lineBreakMode = .byTruncatingMiddle
            f.widthAnchor.constraint(equalToConstant: 170).isActive = true
        }
    }

    /// The label under the slider follows it live.
    public func setVolume(_ fraction: Double) {
        volume.doubleValue = fraction * 100
        volumeLabel.stringValue = "\(SoundTiming.percent(volume: fraction))%"
    }

    /// The Custom rows show only for the Custom pack.
    public func showPack(_ pack: SoundPack) {
        if let i = soundPack.itemArray.firstIndex(where: { $0.representedObject as? String == pack.rawValue }) { soundPack.selectItem(at: i) }
        packHelp.stringValue = pack.detail
        for index in customRows { soundsGrid.row(at: index).isHidden = pack != .custom }
    }

    /// Shows the imported files (name and length) and the trimming warning; `error` replaces the warning once.
    public func setCustomSounds(start: CustomSound?, stop: CustomSound?, error: String? = nil) {
        customStartSound = start
        customStopSound = stop
        soundError = error
        startFile.stringValue = start.map { "\($0.displayName) · \(SoundTiming.durationText($0.duration))" } ?? "None (uses Chirp)"
        stopFile.stringValue = stop.map { "\($0.displayName) · \(SoundTiming.durationText($0.duration))" } ?? "None (uses Chirp)"
        startFile.textColor = start == nil ? .secondaryLabelColor : .labelColor
        stopFile.textColor = stop == nil ? .secondaryLabelColor : .labelColor
        removeStart.isEnabled = start != nil
        removeStop.isEnabled = stop != nil
        if let error {
            customStartHelp.stringValue = error
            customStartHelp.textColor = .systemRed
        } else if let start, SoundTiming.isTrimmed(.start, duration: start.duration) {
            customStartHelp.stringValue = "\(SoundTiming.longStartWarning) Yours is \(SoundTiming.durationText(start.duration))."
            customStartHelp.textColor = MenuStyle.textColor(.warning)
        } else {
            customStartHelp.stringValue = SoundTiming.longStartWarning
            customStartHelp.textColor = .secondaryLabelColor
        }
    }

    /// Lays `rows` out as `tab`'s content: a grid whose `groups` rows start a new group (a little more space above).
    private func build(_ tab: SettingsTab, _ rows: [[NSView]], groups: [Int] = [], customRows custom: [Int] = []) {
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        for index in groups { grid.row(at: index).topPadding = Self.groupSpacing }
        grids[tab] = grid
        customRows = custom.isEmpty ? customRows : custom
        place(tab, grid)
    }

    /// `body` centred across the tab, 20 pt below its top and above its bottom, and at least 20 pt from each side.
    private func place(_ tab: SettingsTab, _ body: NSView) {
        body.translatesAutoresizingMaskIntoConstraints = false
        let view = SettingsContentView()
        view.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: view.topAnchor, constant: Self.margin),
            view.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: Self.margin),
            body.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            body.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: Self.margin),
        ])
        bodies[tab] = body
        tabViews[tab] = view
    }

    /// The content of `tab`.
    public func view(for tab: SettingsTab) -> SettingsContentView { tabViews[tab]! }

    /// The size `tab` needs: as wide as the widest tab (and the toolbar), as tall as its own body plus the margins.
    /// Measured on the bodies, not the content views, because the window sizes the content view (its fitting size
    /// would then just echo the size it was given).
    public func fittingSize(for tab: SettingsTab) -> NSSize {
        NSSize(width: commonWidth, height: bodies[tab]!.fittingSize.height + 2 * Self.margin)
    }

    private var commonWidth: CGFloat {
        max(SettingsTab.allCases.map { bodies[$0]!.fittingSize.width }.max()! + 2 * Self.margin, Self.minimumWidth)
    }

    /// Fills the window. The periodic refresh passes `full: false` so it only follows the server and permission
    /// states and never overwrites what the user is typing or a login-item error shown under the checkbox.
    public func apply(_ s: SettingsState, full: Bool = false) {
        if full {
            fillHotkeyMenu(selecting: s.hotkey)
            openNotes.show(s.openNotesHotkey, alwaysInDock: s.alwaysShowInDock)
            showMode(s.activationMode, silence: s.autoStopSilence)
            autoEnter.selectItem(at: AutoEnter.allCases.firstIndex(of: s.autoEnter) ?? 0)
            sounds.state = s.soundsEnabled ? .on : .off
            showPack(s.soundPack)
            setVolume(s.soundVolume)
            setCustomSounds(start: s.customStart, stop: s.customStop)
            serverURL.stringValue = s.serverURL
            launch.state = s.launch == .on ? .on : .off
            launch.isEnabled = s.launch != .unavailable
            wordWaveform.state = s.wordWaveform ? .on : .off
            notesRecoveryCopy.state = s.notesRecoveryCopy ? .on : .off
            launchUnavailable = s.launch == .unavailable
            setLaunchError(nil)
            style.controlSize = .regular
            cleanupEnabled.state = s.cleanupEnabled ? .on : .off
            offerRaw.state = s.offerRaw ? .on : .off
            fillStyleMenu(s.profiles, selecting: s.cleanupStyle, offered: s.serverOffersStyles)
            prompts.configure(catalog: s.catalog, overrides: s.stylePrompts, selecting: s.editingStyle)
            shownCatalog = s.catalog
            insertRawFirst.state = s.insertRawFirst ? .on : .off
            showChanges.state = s.showChanges ? .on : .off
            appStyles.setProfiles(s.profiles)
            appStyles.setRules(s.appStyles)
        } else if s.profiles.map(\.id) != shownProfileIDs {
            // The server's style list arrived after the window opened: follow it without touching what is being edited.
            let current = style.selectedItem?.representedObject as? String ?? s.cleanupStyle
            fillStyleMenu(s.profiles, selecting: current, offered: s.serverOffersStyles)
            appStyles.setProfiles(s.profiles)
        }
        if !full, s.catalog != shownCatalog {
            // The server's prompts arrived (or it went away) after the window opened. Edits are saved as they are
            // made, so reloading from the saved ones loses nothing.
            prompts.configure(catalog: s.catalog, overrides: s.stylePrompts)
            shownCatalog = s.catalog
        }
        showKeepLoaded(s.keepLoaded, host: s.serverHost)
        cleanupHelp.stringValue = s.cleanupDetail
        cleanupEnabled.isEnabled = s.cleanupAvailable
        tokenStatus.set(symbol: s.tokenPresent ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                        tone: s.tokenPresent ? .ok : .warning, text: "~/.config/chirp/token")
        tokenHelp.stringValue = s.tokenPresent ? "Chirp sends this token with every request."
                                               : "No token yet — start chirp-server once to create it."
        serverStatus.set(symbol: "circle.fill", tone: s.serverNotice == nil ? s.serverStatusTone : .warning,
                         text: s.serverNotice == nil ? s.serverStatus : ServerNotice.statusText)
        serverFixButton.title = s.serverNotice?.fix?.buttonTitle ?? ServerFix.restart.buttonTitle
        serverFixButton.isHidden = s.serverNotice?.fix == nil
        serverFixButton.isEnabled = s.serverFixMessage?.hasSuffix("…") != true
        let detail = [s.serverNotice?.message, s.serverFixMessage].compactMap { $0 }.joined(separator: "\n")
        serverDetail.stringValue = detail
        serverDetail.isHidden = detail.isEmpty
        modelsButton.isEnabled = ServerConfig.load(urlString: s.serverURL).isLoopback
        fillMicrophoneMenu(s.inputs, defaultInput: s.defaultInput, chosen: s.chosenInputUID)
        speakerStatus.set(symbol: s.speakerModelDownloaded ? "checkmark.circle.fill" : "circle", tone: s.speakerModelDownloaded ? .ok : .normal,
                          text: s.speakerModelDownloaded ? "Speaker model on this Mac" : "Speaker model not downloaded")
        removeSpeakerModel.isHidden = !s.speakerModelDownloaded
        speakerHelp.stringValue = s.speakerModelDownloaded
            ? "Labels who is talking in Live Notes, on this Mac. Removing it turns labels off until you download it again."
            : "Live Notes downloads it only when you turn on Label speakers in the Notes window, and asks first."
        micStatus.set(symbol: s.micGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                      tone: s.micGranted ? .ok : .warning, text: s.micGranted ? "Microphone allowed" : "Microphone not allowed")
        accessibilityStatus.set(symbol: s.accessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                                tone: s.accessibilityGranted ? .ok : .warning,
                                text: s.accessibilityGranted ? "Accessibility allowed" : "Accessibility not allowed")
        micButton.isHidden = s.micGranted
        accessibilityButton.isHidden = s.accessibilityGranted
    }

    /// The "Keep clean-up model loaded" switch, its status and help, or why it is unavailable; the periodic refresh
    /// calls this too, so it only sets what changed.
    public func showKeepLoaded(_ state: KeepLoadedState, host: String) {
        let p = KeepLoadedPresentation(state, host: host)
        keepLoaded.state = p.isOn ? .on : .off
        keepLoaded.isEnabled = p.isEnabled
        keepLoaded.setAccessibilityHelp(p.help)
        keepLoadedHelp.stringValue = p.help
        keepLoadedStatus.isHidden = p.status == nil
        if let status = p.status {
            switch p.statusTone {
            case .ok: keepLoadedStatus.set(symbol: "circle.fill", tone: .ok, text: status)
            case .busy: keepLoadedStatus.set(symbol: "circle.fill", tone: .warning, text: status)
            case .idle: keepLoadedStatus.set(symbol: "circle", tone: .normal, text: status)
            }
            keepLoadedStatus.setAccessibilityLabel("Clean-up model: \(status)")
        }
        keepLoadedError.isHidden = p.error == nil
        if let error = p.error {
            keepLoadedError.stringValue = error
            keepLoadedError.setAccessibilityLabel("Error: \(error)")
        }
    }

    /// The presets, plus the recorded shortcut when one is in use, with `current` selected.
    public func fillHotkeyMenu(selecting current: KeyCombo) {
        shownHotkey = current
        refreshHotkeyHelp()
        hotkey.removeAllItems()
        for combo in KeyCombo.presets + (current.isCustom ? [current] : []) {
            hotkey.addItem(withTitle: combo.isCustom ? "\(combo.title) (custom)" : combo.title)
            hotkey.lastItem?.representedObject = combo.id
        }
        if let index = hotkey.itemArray.firstIndex(where: { $0.representedObject as? String == current.id }) {
            hotkey.selectItem(at: index)
        }
    }

    /// Follow System Default (naming the default), then every input with the picked one selected; a picked device
    /// that is unplugged shows the default, as the menu does. Rebuilt only when something changed, so the periodic
    /// refresh never disturbs it.
    public func fillMicrophoneMenu(_ inputs: [AudioInput], defaultInput: AudioInput?, chosen: String?) {
        let key = [defaultInput?.name ?? "", chosen ?? ""] + inputs.map { "\($0.uid)\t\($0.name)" }
        guard key != shownMicrophones, let menu = microphone.menu else { return }
        shownMicrophones = key
        menu.removeAllItems()
        // Items go straight into the menu: `addItem(withTitle:)` would merge two devices with the same name.
        menu.addItem(NSMenuItem(title: defaultInput.map { "Follow System Default (\($0.name))" } ?? "Follow System Default", action: nil, keyEquivalent: ""))
        if !inputs.isEmpty { menu.addItem(.separator()) }
        for input in inputs {
            let item = NSMenuItem(title: input.name, action: nil, keyEquivalent: "")
            item.representedObject = input.uid
            menu.addItem(item)
        }
        let picked = InputSelection.resolve(chosen: chosen, available: inputs)
        microphone.selectItem(at: picked.flatMap { p in menu.items.firstIndex { $0.representedObject as? String == p.uid } } ?? 0)
        microphone.isEnabled = !inputs.isEmpty || defaultInput != nil
    }

    /// The styles, with `current` selected (an id the server no longer lists stays selectable, so it is not silently changed).
    public func fillStyleMenu(_ profiles: [CorrectionProfile], selecting current: String, offered: Bool = true) {
        var list = profiles
        if !list.contains(where: { $0.id == current }) {
            list.append(CorrectionProfile(id: current, name: CorrectionProfile.displayName(for: current)))
        }
        shownProfileIDs = profiles.map(\.id)
        style.removeAllItems()
        for p in list {
            style.addItem(withTitle: p.name)
            style.lastItem?.representedObject = p.id
            style.lastItem?.toolTip = p.description
        }
        if let i = list.firstIndex(where: { $0.id == current }) { style.selectItem(at: i) }
        let chosen = list.first { $0.id == current }
        var text = chosen?.description ?? ""
        if chosen?.rewrites == true { text += (text.isEmpty ? "" : " ") + "May restructure your text." }
        if !offered { text = "This server does not offer styles yet; update chirp-server to use them." }
        styleHelp.stringValue = text
    }

    /// Selects `mode` and the auto-stop pause (the nearest offered one), which only matters in auto-stop.
    public func showMode(_ m: ActivationMode, silence seconds: TimeInterval) {
        if let i = mode.itemArray.firstIndex(where: { $0.representedObject as? String == m.rawValue }) { mode.selectItem(at: i) }
        modeHelp.stringValue = m.help
        let nearest = AutoStopDetector.silenceChoices.enumerated().min { abs($0.element - seconds) < abs($1.element - seconds) }
        if let nearest { silence.selectItem(at: nearest.offset) }
        silence.isEnabled = m == .autoStop
    }

    private func refreshHotkeyHelp() {
        fnKeySetupRow?.isHidden = !(shownHotkey.isModifierOnly && shownHotkey.modifiers == ModifierKeys.fn)
        hotkeyHelp.textColor = .secondaryLabelColor
        switch recorder.status {
        case .idle:
            hotkeyHelp.stringValue = shownHotkey.isModifierOnly
                ? "Only on its own; with another key (\(HotKeyValidation.modifierSymbols(shownHotkey.modifiers))←) it does nothing. Esc cancels."
                : "Any key combination, or a modifier alone like ⌥. Esc cancels."
        case .recording: hotkeyHelp.stringValue = "Press the shortcut, or press and release a modifier such as ⌥. Esc gives up."
        case .rejected(let why):
            hotkeyHelp.stringValue = why.reason
            hotkeyHelp.textColor = .systemRed
        }
    }

    /// Shows why toggling launch at login failed under the checkbox; nil restores the usual help text.
    public func setLaunchError(_ message: String?) {
        if let message {
            launchHelp.stringValue = "Couldn’t change it: \(message)"
            launchHelp.textColor = .systemRed
        } else {
            launchHelp.stringValue = launchUnavailable ? "Available when Chirp runs from its app bundle."
                                                       : "Opens Chirp when you log in."
            launchHelp.textColor = .secondaryLabelColor
        }
    }

    // MARK: pieces

    /// A file's name and length, then Choose… and Remove.
    private static func fileRow(_ name: NSTextField, choose: NSButton, remove: NSButton) -> NSView {
        let stack = NSStackView(views: [name, choose, remove])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    private static func label(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = MenuStyle.font
        f.alignment = .right
        return f
    }

    /// What the server says about clean-up: where it runs, or that it is off.
    public static func cleanupDetail(health: Health?) -> (text: String, available: Bool) {
        guard let h = health else { return ("Needs the server. Tidies punctuation and wording before the text is inserted.", true) }
        if !h.correctionAvailable { return ("The server has clean-up turned off; see the README to enable it.", false) }
        if h.correctionLeavesMachine == true { return ("Sends the text to \(h.correctionHost ?? "a remote LLM") to tidy it.", true) }
        return ("Runs on this Mac: tidies punctuation and wording before the text is inserted.", true)
    }

    /// Secondary-colour help text under a control, wrapped to the control column's width.
    static func help(_ text: String) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text)
        f.font = MenuStyle.secondaryFont
        f.textColor = .secondaryLabelColor
        f.preferredMaxLayoutWidth = controlWidth
        return f
    }
}

/// A status symbol, a label and an optional trailing button (hidden when it has nothing to fix).
@MainActor
private final class StatusLine: NSStackView {
    private let icon = NSImageView()
    private let text = NSTextField(labelWithString: "")
    var accessory: NSView? { didSet { if let accessory { addArrangedSubview(accessory) } } }

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 6
        text.font = MenuStyle.font
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        icon.setAccessibilityElement(false)
        addArrangedSubview(icon)
        addArrangedSubview(text)
        setCustomSpacing(10, after: text)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    func set(symbol: String, tone: MenuEntry.Tone, text string: String) {
        icon.image = MenuStyle.symbol(symbol, tone: tone)
        icon.contentTintColor = tone == .normal ? .tertiaryLabelColor : nil
        text.stringValue = string
    }
}
