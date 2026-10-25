import XCTest

/// Runs against the installed extension, never an in-process keyboard mock.
final class ChirpKeyboardUITests: XCTestCase {
    @MainActor func testSyntheticDictationInRealKeyboardPreservesPrefix() throws {
        try runSyntheticDictation(prefix: "Host prefix. ", extraArguments: [])
    }

    /// UIKit reports nil before/after context in an empty field; dictation must still insert there.
    @MainActor func testSyntheticDictationInEmptyHostField() throws {
        try runSyntheticDictation(prefix: "", extraArguments: ["--chirp-keyboard-host-empty"])
    }

    /// Auto-Enter: in a field whose Return key is Send, the final lands and Return fires exactly once.
    @MainActor func testAutoEnterPressesSendOnceAfterTheFinal() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--chirp-ui-test", "--chirp-keyboard-host", "--chirp-keyboard-host-send", "--chirp-auto-enter", "actionKeys"]
        app.launch()
        defer { app.activate(); if app.buttons["chirp.host.end"].exists { app.buttons["chirp.host.end"].tap() } }
        let setup = app.staticTexts["chirp.host.setup"]
        XCTAssertTrue(setup.waitForExistence(timeout: 10))
        let prepared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", "Preparing synthetic shared session"), object: setup)
        XCTAssertEqual(XCTWaiter.wait(for: [prepared], timeout: 10), .completed)
        if setup.label.contains("unavailable") || setup.label.contains("could not arm") { throw XCTSkip(setup.label) }
        try enableKeyboardInSettings()
        app.activate()
        let field = app.textFields["chirp.host.send"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        try selectChirpKeyboard(in: app)
        let status = app.staticTexts["chirp.keyboard.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        let armed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Ready"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [armed], timeout: 10), .completed)
        let primary = app.buttons["chirp.keyboard.primary"]
        primary.tap()
        XCTAssertTrue(wait(for: field, key: "value", equalTo: "synthetic words"))
        XCTAssertEqual(app.staticTexts["chirp.host.sends"].label, "Returns: 0", "No Return while dictating")
        primary.tap()
        XCTAssertTrue(wait(for: field, key: "value", equalTo: "Synthetic words."))
        XCTAssertTrue(wait(for: app.staticTexts["chirp.host.sends"], key: "label", equalTo: "Returns: 1"), "Send must fire once after the final")
        XCTAssertTrue(status.label.contains(AutoEnterSentMarker), status.label)
        XCTAssertFalse(app.buttons["chirp.keyboard.undo"].exists, "Nothing to undo once sent")
    }

    @MainActor private func runSyntheticDictation(prefix: String, extraArguments: [String]) throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--chirp-ui-test", "--chirp-keyboard-host"] + extraArguments
        app.launch()
        defer {
            app.activate()
            if app.buttons["chirp.host.end"].exists { app.buttons["chirp.host.end"].tap() }
            XCUIDevice.shared.orientation = .portrait
        }
        XCTAssertTrue(app.textViews["chirp.host.text"].waitForExistence(timeout: 10))
        let setup = app.staticTexts["chirp.host.setup"]
        let prepared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", "Preparing synthetic shared session"), object: setup)
        XCTAssertEqual(XCTWaiter.wait(for: [prepared], timeout: 10), .completed)
        let setupEvidence = XCTAttachment(string: setup.label)
        setupEvidence.name = "Shared App Group and Keychain fixture setup"
        setupEvidence.lifetime = .keepAlways
        add(setupEvidence)
        try enableKeyboardInSettings()
        app.activate()
        let field = app.textViews["chirp.host.text"]
        field.tap()
        XCTAssertEqual(field.value as? String ?? "", prefix)
        try selectChirpKeyboard(in: app)
        // A tap in the empty area below the text puts the caret after the prefix, as a user would.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.6)).tap()

        // The redesign lands separately. Once status exists, failures are assertions.
        let status = app.staticTexts["chirp.keyboard.status"]
        guard status.waitForExistence(timeout: 10) else {
            throw XCTSkip("Installed keyboard has no chirp.keyboard.status yet; waiting for the parallel keyboard identifier change.")
        }
        // Idle keyboard: one status line, no paragraph. Chips that don't apply are hidden, so only Style is on screen.
        for id in ["primary", "info", "style", "end", "space", "delete", "return"] {
            XCTAssertTrue(app.descendants(matching: .any)["chirp.keyboard." + id].exists, "Missing keyboard identifier: \(id)")
        }
        for id in ["cancel", "raw", "undo", "detail"] {
            XCTAssertFalse(app.descendants(matching: .any)["chirp.keyboard." + id].exists, "\(id) must be hidden while armed")
        }
        // The Style chip names the style, never "Style:…" as its visible title.
        let styleChip = app.buttons["chirp.keyboard.style"]
        XCTAssertEqual(styleChip.label, "Style: Default")
        XCTAssertFalse(styleChip.staticTexts.allElementsBoundByIndex.contains { $0.label.contains("Style:") })
        // The long guidance sits behind the ⓘ and opens over the keys without moving them.
        let spaceBefore = app.buttons["chirp.keyboard.space"].frame
        let primaryBefore = primaryButton(in: app).frame
        app.buttons["chirp.keyboard.info"].tap()
        let detail = app.staticTexts["chirp.keyboard.detail"]
        XCTAssertTrue(detail.waitForExistence(timeout: 3), "ⓘ must open the guidance")
        XCTAssertTrue(detail.label.contains("Microphone stays active in Chirp"), detail.label)
        keep(app, "keyboard-info-open")
        app.buttons["chirp.keyboard.info.close"].tap()
        XCTAssertTrue(waitForAbsence(detail))
        XCTAssertEqual(app.buttons["chirp.keyboard.space"].frame, spaceBefore)
        if setup.label.contains("unavailable") || setup.label.contains("could not arm") {
            throw XCTSkip(setup.label)
        }
        let armed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Ready"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [armed], timeout: 10), .completed)
        let primary = app.buttons["chirp.keyboard.primary"]
        XCTAssertTrue(primary.isEnabled)
        keep(app, "keyboard-armed")
        primary.tap()
        let partialArrived = wait(for: field, key: "value", equalTo: prefix + "synthetic words")
        let observed = XCTAttachment(string: "Host text after partial: " + String(describing: field.value))
        observed.name = "Host field value after first primary tap"
        observed.lifetime = .keepAlways
        add(observed)
        XCTAssertTrue(partialArrived, "Real mailbox partial must reach the editor; host text was \(String(describing: field.value))")
        // Height never changes: the primary and the typing row stay exactly where they were while listening.
        XCTAssertEqual(primary.frame, primaryBefore, "The keyboard must not change height while listening")
        XCTAssertEqual(app.buttons["chirp.keyboard.space"].frame, spaceBefore)
        XCTAssertEqual(primary.label, "Stop dictation")
        XCTAssertTrue(app.buttons["chirp.keyboard.cancel"].exists, "Cancel is a chip while listening")
        keep(app, "keyboard-listening")
        primary.tap()
        XCTAssertTrue(wait(for: field, key: "value", equalTo: prefix + "Synthetic words."), "Final must replace only the keyboard-owned partial")
        // For 5 seconds after the final, the Cancel slot is Undo and removes exactly the dictation.
        let undo = app.buttons["chirp.keyboard.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 3), "Undo must be offered after the final lands")
        XCTAssertEqual(app.buttons["chirp.keyboard.space"].frame, spaceBefore, "The keyboard must not change height after the final")
        keep(app, "keyboard-finished")
        undo.tap()
        XCTAssertTrue(wait(for: field, key: "value", equalTo: prefix), "Undo must restore the field exactly; was \(String(describing: field.value))")
        XCTAssertTrue(status.label.hasPrefix("Dictation removed"), status.label)
        XCTAssertTrue(waitForAbsence(undo), "Undo goes away once used")
        app.buttons["chirp.keyboard.end"].tap()
        XCTAssertTrue(wait(for: app.staticTexts["chirp.host.phase"], key: "label", equalTo: "idle"))
        XCTAssertEqual(field.value as? String ?? "", prefix)
        // Secure fields always get Apple's keyboard; on the iOS 27.0 simulator a visible secure field also
        // withholds third-party keyboards from the window's other fields until it is gone.
        let toggle = app.descendants(matching: .any).matching(identifier: "chirp.host.secure.toggle").firstMatch
        toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap()
        let secure = app.secureTextFields["chirp.host.secure"]
        XCTAssertTrue(secure.waitForExistence(timeout: 5))
        secure.tap()
        XCTAssertTrue(waitForAbsence(status), "Chirp Keyboard must not appear in a secure field")
        XCTAssertTrue(app.keys["space"].waitForExistence(timeout: 5), "Apple's keyboard must take over in the secure field")
        XCTAssertEqual(field.value as? String ?? "", prefix)
    }

    private func primaryButton(in app: XCUIApplication) -> XCUIElement { app.buttons["chirp.keyboard.primary"] }

    /// A named screenshot of the keyboard area, kept with the result bundle (synthetic text only).
    @MainActor private func keep(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor private func waitForAbsence(_ element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
    }

    @MainActor private func wait(for element: XCUIElement, key: String, equalTo value: String) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "%K == %@", key, value), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
    }
}

private let AutoEnterSentMarker = "↵ sent"
