import XCTest

/// Live Notes with synthetic sockets and capture (`--chirp-ui-test`): Record, the live partial, Pause, structured notes,
/// Resume, Stop, the transcript with Show raw, Copy and New. On iPad notes and transcript are side by side.
final class ChirpNotesUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }

    @MainActor static func openNotes(_ app: XCUIApplication) {
        // iPad: the Notes tab (iPadOS 27's top tab strip is buttons named by symbol). iPhone: the Dictate tab's toolbar.
        let tab = app.tabBars.buttons["Notes"]
        if tab.exists { tab.tap(); return }
        let entry = app.buttons["chirp.notes.open"]
        if entry.waitForExistence(timeout: 3) { entry.tap(); return }
        let topTab = app.buttons.matching(identifier: "note.text").firstMatch
        XCTAssertTrue(topTab.waitForExistence(timeout: 5), "No way into Live Notes")
        topTab.tap()
    }

    @MainActor static func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor static func waitFor(_ element: XCUIElement, _ format: String, timeout: TimeInterval = 15) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)], timeout: timeout) == .completed
    }

    /// SwiftUI's iOS 27 toggle row is one element; its switch sits at the trailing edge.
    @MainActor static func flip(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }

    @MainActor func screenshot(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor func testSyntheticRecordPauseResumeStopTranscriptAndExport() {
        let app = XCUIApplication()
        app.launchArguments = ["--chirp-ui-test"]
        app.launch()
        Self.openNotes(app)
        let record = app.buttons["chirp.notes.record"]
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        record.tap()
        let status = Self.element("chirp.notes.status", in: app)
        XCTAssertTrue(Self.waitFor(status, "label == 'Recording'"), status.label)
        XCTAssertTrue(Self.waitFor(Self.element("chirp.notes.partial", in: app), "label == 'synthetic words'"))
        XCTAssertTrue(Self.element("chirp.notes.elapsed", in: app).exists)
        screenshot("Live Notes recording", app)

        app.buttons["chirp.notes.pause"].tap()
        XCTAssertTrue(Self.waitFor(status, "label BEGINSWITH 'Paused'"), status.label)
        let editor = app.textViews["chirp.notes.editor"]
        XCTAssertTrue(Self.waitFor(editor, "value CONTAINS 'Synthetic words.'"), String(describing: editor.value))
        XCTAssertTrue((editor.value as? String)?.contains("## Synthetic notes") == true)

        app.buttons["chirp.notes.pause"].tap()
        XCTAssertTrue(Self.waitFor(status, "label == 'Recording'"), status.label)
        app.buttons["chirp.notes.stop"].tap()
        XCTAssertTrue(Self.waitFor(status, "label == 'Stopped'"), status.label)
        XCTAssertTrue(app.buttons["chirp.notes.record"].waitForExistence(timeout: 5))
        screenshot("Live Notes structured", app)

        let split = Self.element("chirp.notes.split", in: app)
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertTrue(split.exists, "iPad shows notes and transcript side by side")
            XCTAssertTrue(editor.exists)
        } else {
            XCTAssertFalse(split.exists)
            app.buttons["Transcript"].tap()
        }
        let transcript = Self.element("chirp.notes.transcript", in: app)
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        XCTAssertTrue(transcript.staticTexts["Synthetic words. Synthetic words."].waitForExistence(timeout: 5)
                      || transcript.staticTexts["Synthetic words."].exists)
        Self.flip(Self.element("chirp.notes.raw", in: app))
        XCTAssertTrue(transcript.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'synthetic words'")).firstMatch.waitForExistence(timeout: 5))
        screenshot("Live Notes transcript raw", app)

        app.buttons["chirp.notes.export"].tap()
        app.buttons["chirp.notes.copy"].tap()
        XCTAssertTrue(Self.waitFor(Self.element("chirp.notes.notice", in: app), "label == 'Copied notes and transcript.'", timeout: 5))

        app.buttons["chirp.notes.new"].tap()
        let discard = app.buttons["Discard and start new"]
        XCTAssertTrue(discard.waitForExistence(timeout: 5))
        discard.tap()
        if UIDevice.current.userInterfaceIdiom != .pad { app.buttons["Notes"].tap() }
        XCTAssertTrue(Self.waitFor(editor, "value == '' OR value == nil", timeout: 5) || (editor.value as? String)?.isEmpty == true)
        XCTAssertTrue(Self.waitFor(status, "label == 'Ready to record'", timeout: 5), status.label)
    }

    @MainActor func testNotesSettingsAndRotation() {
        let app = XCUIApplication()
        app.launchArguments = ["--chirp-ui-test"]
        app.launch()
        Self.openNotes(app)
        app.buttons["chirp.notes.settings"].tap()
        let saver = Self.element("chirp.notes.batterySaver", in: app)
        XCTAssertTrue(saver.waitForExistence(timeout: 5))
        XCTAssertEqual(saver.value as? String, "1")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Structuring runs on your Mac.'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(Self.element("chirp.notes.recoveryCopy", in: app).value as? String, "1")
        screenshot("Live Notes settings", app)
        app.buttons["Done"].tap()
        defer { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["chirp.notes.record"].waitForExistence(timeout: 5))
        screenshot("Live Notes landscape", app)
    }
}
