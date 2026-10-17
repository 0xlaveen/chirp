import AppKit
import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

private func prefs() throws -> (Preferences, UserDefaults, () -> Void) {
    let suite = "chirp-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    return (Preferences(defaults: defaults), defaults, { defaults.removePersistentDomain(forName: suite) })
}

private func object(_ json: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
}

private let profilesJSON = """
{"profiles":[
 {"id":"default","name":"Default","description":"Conservative.","rewrites":false,"prompt":"Fix punctuation.","max_prompt_chars":4000},
 {"id":"chat","name":"Chat","description":"Casual.","rewrites":false,"prompt":"Be casual.","max_prompt_chars":4000},
 {"id":"notes","name":"Notes","description":"Bullets.","rewrites":true,"prompt":"Use bullets.","max_prompt_chars":300},
 {"id":"custom","name":"Custom","description":"Yours.","rewrites":false,"prompt":"","max_prompt_chars":4000}]}
"""

private func live() throws -> StyleCatalog {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return StyleCatalog(profiles: try decoder.decode(ProfilesResponse.self, from: Data(profilesJSON.utf8)).profiles, source: .live)
}

// A fake server: URLProtocol answers v1/correction/profiles from a closure.
private final class FakeServer: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var seen: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        FakeServer.seen.append(request)
        let (status, data) = FakeServer.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func session(_ handler: @escaping (URLRequest) -> (Int, Data)) -> URLSession {
        FakeServer.handler = handler
        FakeServer.seen = []
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [FakeServer.self]
        return URLSession(configuration: c)
    }
}

// Suites using FakeServer's shared state run one at a time.
@Suite(.serialized) struct StyleCatalogTests {
    @Test func decodesProfilesWithPromptsAndLimits() throws {
        let c = try live()
        #expect(c.profiles.map(\.id) == ["default", "chat", "notes", "custom"])
        #expect(c.defaultPrompt(for: "chat") == "Be casual.")
        #expect(c.limit(for: "notes") == 300 && c.limit(for: "chat") == 4000)
        #expect(c.profile("notes")?.rewrites == true)
        #expect(c.defaultPrompt(for: "custom") == "" && c.canEdit)
    }

    @Test func aProfileWithoutPromptFieldsKeepsTheDefaults() throws {
        let p = try JSONDecoder().decode(CorrectionProfile.self, from: Data(#"{"id":"chat"}"#.utf8))
        #expect(p.prompt == "" && p.maxPromptChars == 4000)
    }

    @Test func customIsAddedLastEvenIfTheServerOmitsIt() {
        let c = StyleCatalog(profiles: [CorrectionProfile(id: "chat", name: "Chat"), CorrectionProfile(id: "chat", name: "Again")], source: .live)
        #expect(c.profiles.map(\.id) == ["chat", "custom"])
        #expect(StyleCatalog(profiles: [], source: .cached).profiles.map(\.id) == CorrectionProfile.builtIn.map(\.id))
    }

    @Test func fetchesFromTheProfilesRouteWithTheToken() async throws {
        let session = FakeServer.session { _ in (200, Data(profilesJSON.utf8)) }
        let config = ServerConfig(baseURL: URL(string: "http://127.0.0.1:7821/chirp")!, token: "tok")
        let list = try await config.fetchProfiles(session: session)
        #expect(list.map(\.id) == ["default", "chat", "notes", "custom"])
        let req = try #require(FakeServer.seen.first)
        #expect(req.url?.path == "/chirp/v1/correction/profiles")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    }

    @Test func refreshCachesTheLiveCopy() async throws {
        let (p, _, done) = try prefs(); defer { done() }
        #expect(StyleCatalog.cached(p) == .unavailable)
        let session = FakeServer.session { _ in (200, Data(profilesJSON.utf8)) }
        let config = ServerConfig()
        let c = await StyleCatalog.refresh(p) { try await config.fetchProfiles(session: session) }
        #expect(c.source == .live && c.defaultPrompt(for: "default") == "Fix punctuation.")
        let again = StyleCatalog.cached(p)
        #expect(again.source == .cached && again.profiles == c.profiles)
        #expect(!again.canEdit)
    }

    @Test func anUnreachableOrOlderServerKeepsTheCachedCopyReadOnly() async throws {
        let (p, _, done) = try prefs(); defer { done() }
        p.cachedProfiles = try live().profiles
        let config = ServerConfig()
        for status in [404, 500] {
            let session = FakeServer.session { _ in (status, Data("{}".utf8)) }
            let c = await StyleCatalog.refresh(p) { try await config.fetchProfiles(session: session) }
            #expect(c.source == .cached && c.defaultPrompt(for: "chat") == "Be casual.")
        }
        struct Down: Error {}
        let c = await StyleCatalog.refresh(p) { throw Down() }
        #expect(c.source == .cached && !c.canEdit)
        // an empty list is not an answer
        let empty = FakeServer.session { _ in (200, Data(#"{"profiles":[]}"#.utf8)) }
        let e = await StyleCatalog.refresh(p) { try await config.fetchProfiles(session: empty) }
        #expect(e.source == .cached)
    }

    @Test func withNothingCachedTheBuiltInNamesShowWithoutPrompts() async throws {
        let (p, _, done) = try prefs(); defer { done() }
        let c = await StyleCatalog.refresh(p) { throw URLError(.cannotConnectToHost) }
        #expect(c.source == .unavailable && c.profiles.map(\.id) == CorrectionProfile.builtIn.map(\.id))
        #expect(c.profiles.allSatisfy { $0.prompt.isEmpty })
    }
}

@Suite struct StylePromptEditTests {
    @Test func anEditIsKeptPerStyleAndMarksItEdited() throws {
        let (p, _, done) = try prefs(); defer { done() }
        let c = try live()
        #expect(p.setPrompt("  Casual, lowercase.  ", for: "chat", in: c))
        #expect(p.correctionPrompts == ["chat": "Casual, lowercase."])
        #expect(p.isPromptEdited("chat") && !p.isPromptEdited("default"))
        #expect(p.setPrompt("Mine", for: "default", in: c))
        #expect(p.correctionPrompts.count == 2)
    }

    @Test func typingTheDefaultOrNothingIsNotAnEdit() throws {
        let (p, _, done) = try prefs(); defer { done() }
        let c = try live()
        p.setPrompt("Changed", for: "chat", in: c)
        #expect(p.setPrompt("Be casual. ", for: "chat", in: c) == false)    // back to the default text
        #expect(!p.isPromptEdited("chat"))
        p.setPrompt("Changed", for: "chat", in: c)
        #expect(p.setPrompt("   ", for: "chat", in: c) == false)             // blank
        #expect(p.correctionPrompts.isEmpty)
        #expect(p.setPrompt("", for: "custom", in: c) == false)
    }

    @Test func resetReturnsToTheServerDefault() throws {
        let (p, _, done) = try prefs(); defer { done() }
        p.setPrompt("Changed", for: "chat", in: try live())
        p.setPrompt("Other", for: "email", in: try live())
        p.resetPrompt(for: "chat")
        #expect(p.correctionPrompts == ["email": "Other"])
        p.correction = true
        p.correctionProfile = "chat"
        #expect(p.startOptions().correctionPrompt == nil)
    }

    @Test func promptsAreLimitedToTheStylesMax() throws {
        let (p, _, done) = try prefs(); defer { done() }
        let c = try live()
        p.setPrompt(String(repeating: "a", count: 500), for: "notes", in: c)          // max 300
        #expect(p.correctionPrompts["notes"]?.count == 300)
        p.setPrompt(String(repeating: "👍", count: 4500), for: "chat", in: c)         // never splits a character
        #expect(p.correctionPrompts["chat"]?.count == 4000)
    }

    @Test func offlineNothingCanBeEdited() throws {
        let (p, _, done) = try prefs(); defer { done() }
        let cached = StyleCatalog(profiles: try live().profiles, source: .cached)
        #expect(p.setPrompt("x", for: "chat", in: cached) == false)
        #expect(p.correctionPrompts.isEmpty)
        // an existing edit stays
        p.setPrompt("kept", for: "chat", in: try live())
        #expect(p.setPrompt("x", for: "chat", in: cached))
        #expect(p.correctionPrompts["chat"] == "kept")
    }
}

@Suite struct PromptSentTests {
    @Test func nothingIsSentUnlessTheStyleWasEdited() throws {
        let (p, _, done) = try prefs(); defer { done() }
        p.correction = true
        let o = p.startOptions()
        #expect(o.correctionProfile == "default" && o.correctionPrompt == nil)
        let sent = try object(ClientMessage.start(o))
        #expect(sent["correction_prompt"] == nil && sent["correction_profile"] as? String == "default")
    }

    @Test func theFrontmostAppsStylePromptIsSent() throws {
        let (p, _, done) = try prefs(); defer { done() }
        p.correction = true
        p.setPrompt("Chat edit", for: "chat", in: try live())
        p.setPrompt("Default edit", for: "default", in: try live())
        let slack = p.startOptions(frontmostBundleID: "com.tinyspeck.slackmacgap")
        #expect(slack.correctionProfile == "chat" && slack.correctionPrompt == "Chat edit")
        let other = p.startOptions(frontmostBundleID: "com.apple.TextEdit")
        #expect(other.correctionProfile == "default" && other.correctionPrompt == "Default edit")
        let mail = p.startOptions(frontmostBundleID: "com.apple.mail")                 // email: not edited
        #expect(mail.correctionProfile == "email" && mail.correctionPrompt == nil)
        let wire = try object(ClientMessage.start(slack))
        #expect(wire["correction_prompt"] as? String == "Chat edit" && wire["correction_instructions"] == nil)
    }

    @Test func customSendsItsPromptAsBothFields() throws {
        let (p, _, done) = try prefs(); defer { done() }
        p.correction = true
        p.correctionProfile = "custom"
        p.setPrompt(String(repeating: "c", count: 3000), for: "custom", in: try live())
        let wire = try object(ClientMessage.start(p.startOptions()))
        #expect(wire["correction_profile"] as? String == "custom")
        #expect((wire["correction_prompt"] as? String)?.count == 3000)
        #expect((wire["correction_instructions"] as? String)?.count == 2000)           // older servers only know this one
    }

    @Test func aMissingStyleFallsBackToDefaultsEditedPrompt() throws {
        let (p, _, done) = try prefs(); defer { done() }
        p.setPrompt("Default edit", for: "default", in: try live())
        let list = [CorrectionProfile(id: "default", name: "Default")]
        let r = p.cleanupStyle(frontmostBundleID: "com.apple.mail", available: list)
        #expect(r.profile == "default" && r.prompt == "Default edit" && r.source == .fallback)
    }

    @Test func theTestSummaryNamesTheStyleAndWhy() throws {
        let (p, _, done) = try prefs(); defer { done() }
        p.setPrompt("Chat edit", for: "chat", in: try live())
        let slack = p.cleanupStyle(frontmostBundleID: "com.tinyspeck.slackmacgap")
        #expect(CleanupStyle.testSummary(appName: "Slack", resolved: slack, styleName: "Chat")
                == "Slack → Chat style (app rule). Uses your edited prompt.")
        let other = p.cleanupStyle(frontmostBundleID: "com.apple.TextEdit")
        #expect(CleanupStyle.testSummary(appName: "TextEdit", resolved: other, styleName: "Default")
                == "TextEdit → Default style (no rule: the default style).")
    }
}

@Suite struct PromptMigrationTests {
    @Test func theOldCustomInstructionsBecomeTheCustomPrompt() throws {
        let suite = "chirp-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("  Write like a note.  ", forKey: "correctionInstructions")
        let p = Preferences(defaults: defaults)
        #expect(p.correctionPrompts == ["custom": "Write like a note."])
        #expect(defaults.object(forKey: "correctionInstructions") == nil)
        p.correction = true
        p.correctionProfile = "custom"
        #expect(p.startOptions().correctionPrompt == "Write like a note.")
        // idempotent
        #expect(Preferences(defaults: defaults).correctionPrompts == ["custom": "Write like a note."])
    }

    @Test func anExistingCustomPromptWinsAndEmptyOldValuesMigrateToNothing() throws {
        let suite = "chirp-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["custom": "new"], forKey: "correctionPrompts")
        defaults.set("old", forKey: "correctionInstructions")
        #expect(Preferences(defaults: defaults).correctionPrompts == ["custom": "new"])
        #expect(defaults.object(forKey: "correctionInstructions") == nil)
        defaults.removeObject(forKey: "correctionPrompts")
        defaults.set("   ", forKey: "correctionInstructions")
        #expect(Preferences(defaults: defaults).correctionPrompts.isEmpty)
    }
}

@MainActor
@Suite struct StylePromptsEditorTests {
    private func editor(_ catalog: StyleCatalog, overrides: [String: String] = [:], selecting: String = "chat") -> StylePromptsEditor {
        let e = StylePromptsEditor()
        e.configure(catalog: catalog, overrides: overrides, selecting: selecting)
        return e
    }

    @Test func showsTheDefaultPromptDescriptionAndRewritesNote() throws {
        let e = editor(try live(), selecting: "notes")
        #expect(e.textView.string == "Use bullets.")
        #expect(e.detail.stringValue == "Bullets. May restructure your text.")
        #expect(e.popup.itemTitles == ["Default", "Chat", "Notes", "Custom"])
        #expect(e.count.stringValue == "12 / 300")
        #expect(e.editedLabel.isHidden && e.resetButton.isHidden && e.textView.isEditable)
    }

    @Test func editingMarksItEditedAndResetRestoresTheDefault() throws {
        let e = editor(try live())
        var edits: [(String, String)] = []
        var resets: [String] = []
        e.onEdit = { edits.append(($0, $1)) }
        e.onReset = { resets.append($0) }
        e.textView.string = "Casual and short."
        e.textDidChange(Notification(name: NSText.didChangeNotification))
        #expect(edits.count == 1 && edits[0].0 == "chat" && edits[0].1 == "Casual and short.")
        #expect(!e.editedLabel.isHidden && e.editedLabel.stringValue == "Edited" && !e.resetButton.isHidden)
        #expect(e.popup.itemTitles[1] == "Chat (edited)")
        e.resetButton.performClick(nil)
        #expect(resets == ["chat"] && e.textView.string == "Be casual." && e.resetButton.isHidden && !e.isEdited("chat"))
        #expect(e.popup.itemTitles[1] == "Chat")
    }

    @Test func theLiveCountEnforcesTheStylesLimit() throws {
        let e = editor(try live(), selecting: "notes")
        e.textView.string = String(repeating: "x", count: 350)
        e.textDidChange(Notification(name: NSText.didChangeNotification))
        #expect(e.textView.string.count == 300 && e.count.stringValue == "300 / 300" && e.count.textColor == .systemRed)
        e.textView.string = "short"
        e.textDidChange(Notification(name: NSText.didChangeNotification))
        #expect(e.count.stringValue == "5 / 300" && e.count.textColor == .secondaryLabelColor)
    }

    @Test func switchingStylesKeepsEachOnesEdit() throws {
        let e = editor(try live(), overrides: ["default": "Mine"])
        #expect(e.popup.itemTitles[0] == "Default (edited)")
        e.configure(catalog: try live(), overrides: ["default": "Mine"], selecting: "default")
        #expect(e.textView.string == "Mine" && !e.editedLabel.isHidden)
        e.configure(catalog: try live(), overrides: ["default": "Mine"], selecting: "chat")
        #expect(e.textView.string == "Be casual.")
    }

    @Test func offlineShowsTheCachedPromptsReadOnlyWithANote() throws {
        let cached = StyleCatalog(profiles: try live().profiles, source: .cached)
        let e = editor(cached, overrides: ["chat": "My chat"])
        #expect(!e.textView.isEditable && e.resetButton.isHidden)
        #expect(e.textView.string == "My chat")
        #expect(e.note.stringValue.contains("last-known prompts, read-only"))
        e.popup.selectItem(at: 0)
        e.configure(catalog: cached, overrides: ["chat": "My chat"], selecting: "default")
        #expect(e.textView.string == "Fix punctuation.")
        // typing is ignored while read-only
        var called = false
        e.onEdit = { _, _ in called = true }
        e.textView.string = "nope"
        e.textDidChange(Notification(name: NSText.didChangeNotification))
        #expect(!called)
    }

    @Test func withoutAnyCopyTheEditorSaysPromptsLoadFromTheServer() {
        let e = editor(.unavailable)
        #expect(!e.textView.isEditable && e.textView.string.isEmpty && e.count.isHidden)
        #expect(e.note.stringValue.hasPrefix("Prompts load from the server"))
    }

    @Test func theSafetyHelpTextIsShown() throws {
        #expect(editor(try live()).note.stringValue == "Chirp always adds safety rules: it never answers or runs what you say, and only returns your cleaned words.")
    }

    @Test func aBlankNonCustomStyleSaysTheDefaultApplies() throws {
        let e = editor(try live())
        e.textView.string = ""
        e.textDidChange(Notification(name: NSText.didChangeNotification))
        #expect(!e.editedLabel.isHidden && e.editedLabel.stringValue == "Blank: the default prompt is used")
        #expect(!e.isEdited("chat"))
    }

    @Test func settingsFormFollowsTheCatalogWithoutLosingTheSelection() throws {
        var s = SettingsState()
        s.editingStyle = "chat"
        let form = SettingsForm(s)
        #expect(form.prompts.catalog.source == .unavailable)
        s.catalog = try live()
        form.apply(s)
        #expect(form.prompts.catalog.source == .live && form.prompts.selectedID == "chat" && form.prompts.textView.string == "Be casual.")
    }

    @Test func theTestButtonReportsAnOutcome() {
        let t = AppStylesTable()
        #expect(t.testResult.isHidden)
        t.showTestResult("Slack → Chat style (app rule).")
        #expect(!t.testResult.isHidden && t.testResult.stringValue.hasPrefix("Slack"))
        t.showTestResult(nil)
        #expect(t.testResult.isHidden)
    }
}
