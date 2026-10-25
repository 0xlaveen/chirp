import XCTest

/// The Notes library through the real sealed store, with synthetic capture and server responses.
final class ChirpNotesUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }

    @MainActor static func openNotes(_ app: XCUIApplication) {
        let tab = app.tabBars.buttons["Notes"]
        if tab.exists { tab.tap(); return }
        let entry = app.buttons["chirp.notes.open"]
        if entry.waitForExistence(timeout: 2) { entry.tap(); return }
        let sidebar = app.buttons["Notes"]
        if sidebar.exists { sidebar.tap(); return }
        let top = app.buttons.matching(identifier: "note.text").firstMatch
        if top.exists { top.tap() }
    }
    @MainActor static func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    @MainActor static func waitFor(_ element: XCUIElement, _ format: String, timeout: TimeInterval = 15) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)], timeout: timeout) == .completed
    }
    @MainActor static func flip(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }
    @MainActor func screenshot(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    @MainActor private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--chirp-ui-test", "--chirp-notes-library-id", UUID().uuidString] + extra
        app.launch(); Self.openNotes(app)
        XCTAssertTrue(Self.element("chirp.notes.library", in: app).waitForExistence(timeout: 10))
        return app
    }
    @MainActor private func backToLibrary(_ app: XCUIApplication) {
        if UIDevice.current.userInterfaceIdiom != .pad {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            XCTAssertTrue(back.waitForExistence(timeout: 5)); back.tap()
        }
    }
    @MainActor private func menu(_ app: XCUIApplication, action: String) {
        app.buttons["chirp.notes.export"].tap()
        let button = app.buttons[action]
        XCTAssertTrue(button.waitForExistence(timeout: 5)); button.tap()
    }

    @MainActor func testSyntheticRecordPauseResumeStopTranscriptAndExport() {
        let app = launch()
        screenshot("notes-empty", app)
        app.buttons["chirp.notes.record"].firstMatch.tap()
        let status = Self.element("chirp.notes.status", in: app)
        XCTAssertTrue(Self.waitFor(status, "label == 'Recording'"))
        XCTAssertTrue(Self.waitFor(Self.element("chirp.notes.partial", in: app), "label == 'synthetic words'"))
        screenshot("notes-recording", app)
        backToLibrary(app)
        XCTAssertTrue(app.buttons["chirp.notes.recordingRow"].waitForExistence(timeout: 5))
        screenshot("notes-library-recording", app)
        app.buttons["chirp.notes.recordingRow"].tap()
        app.buttons["chirp.notes.pause"].tap()
        XCTAssertTrue(Self.waitFor(status, "label BEGINSWITH 'Paused'"))
        XCTAssertTrue(app.staticTexts["Synthetic words."].waitForExistence(timeout: 15))
        app.buttons["chirp.notes.pause"].tap()
        XCTAssertTrue(Self.waitFor(status, "label == 'Recording'"))
        app.buttons["chirp.notes.stop"].tap()
        XCTAssertTrue(Self.waitFor(status, "label == 'Stopped'"))
        screenshot("notes-stopped", app)
        app.buttons["chirp.notes.edit"].tap()
        let editor = app.textViews["chirp.notes.editor"]
        XCTAssertTrue(Self.waitFor(editor, "value CONTAINS 'Synthetic words.'"))
        screenshot("notes-edit", app)
        app.buttons["chirp.notes.edit"].tap()
        app.buttons["chirp.notes.transcript.open"].tap()
        let transcript = Self.element("chirp.notes.transcript", in: app)
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        Self.flip(Self.element("chirp.notes.raw", in: app))
        XCTAssertTrue(transcript.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'synthetic words'")).firstMatch.waitForExistence(timeout: 5))
        screenshot("notes-transcript", app)
        if UIDevice.current.userInterfaceIdiom != .pad { app.buttons["Done"].tap() }
        else { app.buttons["chirp.notes.transcript.open"].tap() }
        menu(app, action: "chirp.notes.copy")
        XCTAssertTrue(Self.waitFor(Self.element("chirp.notes.notice", in: app), "label CONTAINS 'Copied notes'"))
        backToLibrary(app)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chirp.notes.row.'")).firstMatch.waitForExistence(timeout: 5))
        screenshot("notes-library-after-recording", app)
        app.terminate(); app.launch(); Self.openNotes(app)
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chirp.notes.row.'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The sealed note survives relaunch")
        row.tap()
        XCTAssertTrue(app.buttons["chirp.notes.title"].waitForExistence(timeout: 5))
        menu(app, action: "Delete")
        let undo = app.buttons["chirp.notes.delete.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5)); undo.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap(); menu(app, action: "Delete")
        app.buttons["chirp.notes.menu"].tap(); app.buttons["Recently Deleted"].tap()
        XCTAssertTrue(app.buttons["Restore"].waitForExistence(timeout: 5))
        screenshot("notes-recently-deleted", app)
        app.buttons["Restore"].tap()
        XCTAssertTrue(app.staticTexts["Nothing in Recently Deleted"].waitForExistence(timeout: 5))
    }

    @MainActor func testNotesSettingsAndRotation() {
        let app = launch()
        app.buttons["chirp.notes.menu"].tap(); app.buttons["chirp.notes.settings"].tap()
        let saver = Self.element("chirp.notes.batterySaver", in: app)
        XCTAssertTrue(saver.waitForExistence(timeout: 5)); XCTAssertEqual(saver.value as? String, "1")
        XCTAssertEqual(Self.element("chirp.notes.keepNotes", in: app).value as? String, "1")
        XCTAssertEqual(Self.element("chirp.notes.keepAudio", in: app).value as? String, "0")
        XCTAssertTrue(app.staticTexts["Never"].exists)
        screenshot("notes-settings", app)
        app.buttons["Done"].tap()
        defer { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["chirp.notes.record"].firstMatch.waitForExistence(timeout: 5))
        screenshot("notes-library-landscape", app)
    }

    /// Captures both appearances when e2e-all.sh is run with and without --dark.
    @MainActor func testLibraryReadingSearchTasksAndInspector() {
        let app = launch(["--chirp-notes-gallery"])
        XCTAssertTrue(app.staticTexts["Lantern kickoff"].waitForExistence(timeout: 10))
        screenshot("notes-library-groups", app)
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chirp.notes.row.' AND label CONTAINS 'Lantern kickoff'")).firstMatch
        XCTAssertTrue(row.exists); row.tap()
        XCTAssertTrue(app.staticTexts["Decision:"].exists || app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Keep the launch in March'")).firstMatch.waitForExistence(timeout: 5))
        screenshot("notes-reading", app)
        let task = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Send the updated proposal'")).firstMatch
        if task.exists { task.tap(); XCTAssertEqual(task.value as? String, "Checked") }
        app.buttons["chirp.notes.transcript.open"].tap()
        XCTAssertTrue(app.buttons["chirp.notes.play.0"].waitForExistence(timeout: 5))
        app.buttons["chirp.notes.play.0"].tap()
        screenshot("notes-transcript-audio", app)
        if UIDevice.current.userInterfaceIdiom != .pad { app.buttons["Done"].tap() }
        else { app.buttons["chirp.notes.transcript.open"].tap() }
        app.buttons["chirp.notes.edit"].tap(); screenshot("notes-reading-edit", app)
        app.buttons["chirp.notes.edit"].tap()
        app.buttons["chirp.notes.title"].tap()
        let title = app.textFields["chirp.notes.title.editor"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 64) + "Launch notes")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.buttons["chirp.notes.title"].waitForExistence(timeout: 5))
        backToLibrary(app)
        app.buttons["Search notes"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("March")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Keep the launch in March'")).firstMatch.waitForExistence(timeout: 5))
        screenshot("notes-search", app)
    }

    @MainActor func testAccessibilityLibraryAndDock() {
        let app = launch(["--chirp-notes-gallery", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        screenshot("notes-library-ax5", app)
        app.buttons["chirp.notes.record"].firstMatch.tap()
        XCTAssertTrue(app.buttons["chirp.notes.stop"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["chirp.notes.pause"].isHittable)
        screenshot("notes-dock-ax5", app)
        app.buttons["chirp.notes.stop"].tap()
    }
}
