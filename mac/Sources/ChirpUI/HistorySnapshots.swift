import AppKit
import ChirpCore
import SwiftUI

/// Dictation history in the snapshots: the History window (populated, searched, empty, off), the Settings section and
/// the menu's Recent Dictations. Every dictation is made up; the app icons are drawn here, never read from the system.
@MainActor
extension Snapshots {
    static let historyNow = sampleNow

    /// A fixed stand-in icon per app: a rounded square in the app's colour with its initial.
    static func demoIcon(_ bundleID: String?) -> NSImage? {
        let palette: [String: (NSColor, String)] = [
            "com.tinyspeck.slackmacgap": (NSColor(red: 0.29, green: 0.08, blue: 0.29, alpha: 1), "S"),
            "com.apple.mail": (NSColor(red: 0.13, green: 0.47, blue: 0.95, alpha: 1), "M"),
            "com.apple.TextEdit": (NSColor(red: 0.55, green: 0.57, blue: 0.62, alpha: 1), "T"),
            "com.microsoft.VSCode": (NSColor(red: 0.0, green: 0.47, blue: 0.83, alpha: 1), "C"),
            "com.apple.MobileSMS": (NSColor(red: 0.2, green: 0.78, blue: 0.35, alpha: 1), "M"),
        ]
        guard let bundleID, let (color, letter) = palette[bundleID] else { return nil }
        return NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 4, dy: 4), xRadius: 14, yRadius: 14).fill()
            let text = NSAttributedString(string: letter, attributes: [
                .font: NSFont.systemFont(ofSize: 30, weight: .bold), .foregroundColor: NSColor.white])
            let size = text.size()
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            return true
        }
    }

    static func demoHistory() -> [DictationEntry] {
        func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 900 + n))! }
        func ago(_ minutes: Double) -> Date { historyNow.addingTimeInterval(-minutes * 60) }
        return [
            DictationEntry(id: id(1), date: ago(4), text: "sounds good, I'll push the fix to staging after lunch",
                         raw: "Sounds good. I'll push the fix to staging after lunch.", bundleID: "com.tinyspeck.slackmacgap",
                         appName: "Slack", duration: 3.8, style: "chat"),
            DictationEntry(id: id(2), date: ago(38), text: "Hi Maya,\n\nThanks for the notes from Tuesday. I moved the review to Thursday at 3:30 so everyone can make it. Let me know if that clashes with anything.\n\nBest,\nSam",
                         raw: "hi maya thanks for the notes from tuesday I moved the review to thursday at three thirty so everyone can make it let me know if that clashes with anything best sam",
                         bundleID: "com.apple.mail", appName: "Mail", duration: 14.2, style: "email"),
            DictationEntry(id: id(3), date: ago(95), text: "Check that the retry loop backs off before the third attempt.",
                         bundleID: "com.apple.TextEdit", appName: "TextEdit", duration: 4.1),
            DictationEntry(id: id(4), date: ago(60 * 20), text: "rename the helper to parseHeaders and keep the old name as a deprecated alias",
                         raw: "rename the helper to parse headers and keep the old name as a deprecated alias",
                         bundleID: "com.microsoft.VSCode", appName: "Visual Studio Code", duration: 5.6, style: "code"),
            DictationEntry(id: id(5), date: ago(60 * 22), text: "On my way, ten minutes", bundleID: "com.apple.MobileSMS",
                         appName: "Messages", duration: 1.9),
            DictationEntry(id: id(6), date: ago(60 * 24 * 3), text: "Ship the Kubernetes upgrade on Monday once the canary is green.",
                         raw: "Ship the cooper netties upgrade on Monday once the canary is green.",
                         bundleID: "com.apple.TextEdit", appName: "TextEdit", duration: 4.4, style: "default"),
        ]
    }

    static func demoLearned() -> [LearnedItem] {
        func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 950 + n))! }
        func ago(_ hours: Double) -> Date { historyNow.addingTimeInterval(-hours * 3600) }
        return [
            LearnedItem(id: id(1), correction: .term(heard: "cooper netties", term: "Kubernetes"), bundleID: "com.apple.TextEdit",
                        appName: "TextEdit", state: .active, count: 2, firstSeen: ago(30), lastSeen: ago(1),
                        inserted: "Ship the cooper netties upgrade on Monday.", edited: "Ship the Kubernetes upgrade on Monday."),
            LearnedItem(id: id(2), correction: .term(heard: "and throw pick", term: "Anthropic"), bundleID: "com.apple.TextEdit",
                        appName: "TextEdit", state: .learning, count: 1, firstSeen: ago(3), lastSeen: ago(3),
                        inserted: "Thanks to the and throw pick team.", edited: "Thanks to the Anthropic team."),
            LearnedItem(id: id(3), correction: .style(.lowercaseStart), bundleID: "com.tinyspeck.slackmacgap", appName: "Slack",
                        state: .active, count: 3, firstSeen: ago(48), lastSeen: ago(0.2),
                        inserted: "Sounds good, I'll push it.", edited: "sounds good, I'll push it", said: "sounds good I'll push it"),
            LearnedItem(id: id(4), correction: .style(.noFinalPeriod), bundleID: "com.tinyspeck.slackmacgap", appName: "Slack",
                        state: .off, count: 2, firstSeen: ago(48), lastSeen: ago(0.2),
                        inserted: "Sounds good, I'll push it.", edited: "sounds good, I'll push it", said: "sounds good I'll push it"),
        ]
    }

    static func historyWindow(_ model: HistoryModel, size: CGSize = HistoryViewMetrics.defaultSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.contentViewController = NSHostingController(rootView: HistoryView(model: model))
        window.setContentSize(size)
        return window
    }

    public static var historyScenarios: [Scenario] {
        func window(_ name: String, _ configure: @escaping (HistoryModel) -> Void) -> Scenario {
            Scenario(name: "history-\(name)", window: {
                let model = HistoryModel()
                model.now = { historyNow }
                model.calendar = utcCalendar
                model.icon = { demoIcon($0) }
                model.show(demoHistory())
                configure(model)
                return historyWindow(model)
            })
        }
        var settings = SettingsState()
        settings.launch = .on; settings.serverStatus = "parakeet-mlx:tdt-0.6b-v2"
        settings.about = AboutInfo(version: "0.1.0", build: "1")
        settings.historyCount = 128
        settings.learnedSummary = LearnedText.summary(demoLearned())
        let state = settings
        var off = settings
        off.historyEnabled = false; off.historyCount = 0
        let stateOff = off
        return [
            window("cleaned") { $0.selection = demoHistory()[1].id },
            window("cleaned-teach") { $0.canTeach = true; $0.selection = demoHistory()[1].id; $0.flash = HistoryText.learned(["Kubernetes"]) },
            window("plain") { $0.selection = demoHistory()[2].id },
            window("search") { $0.query = "kubernetes"; $0.selection = demoHistory()[5].id },
            window("no-results") { $0.query = "invoice"; $0.selection = nil },
            window("empty") { $0.show([]) },
            window("off") { $0.enabled = false; $0.show([]) },
            window("deleted") { $0.selection = demoHistory()[0].id; $0.delete(demoHistory()[0].id) },
            Scenario(name: "settings-dictation-history") { settingsWindow(state, .dictation, full: true) },
            Scenario(name: "learned-list") {
                let model = LearnedModel()
                model.icon = { demoIcon($0) }
                model.items = demoLearned()
                return NSHostingView(rootView: LearnedView(model: model))
            },
            Scenario(name: "learned-empty") { NSHostingView(rootView: LearnedView(model: LearnedModel())) },
            hud("learned") { $0.status = "Learned: Kubernetes"; $0.indicator = .sparkle },
            Scenario(name: "history-teach-sheet") {
                let m = HistoryModel()
                var heard = demoHistory()[5]
                heard.text = heard.raw ?? heard.text
                m.beginTeaching(heard)
                m.teachText = "Ship the Kubernetes upgrade on Monday once the canary is green."
                return NSHostingView(rootView: TeachSheet(model: m).background(Color.chirp.background))
            },
            Scenario(name: "settings-dictation-history-off") { settingsWindow(stateOff, .dictation, full: true) },
            Scenario(name: "menu-recent-dictations-submenu") {
                var inputs = MenuInputs()
                inputs.now = historyNow
                inputs.calendar = utcCalendar
                inputs.recentDictations = demoHistory().map {
                    RecentDictation(id: $0.id.uuidString, preview: HistoryText.menuTitle($0, limit: 60), date: $0.date)
                }
                let rows = MenuContent.entries(inputs).first { $0.title == "Recent Dictations" }?.submenu ?? []
                return MenuPanelView(header: nil, entries: rows, native: true)
            },
        ]
    }
}
