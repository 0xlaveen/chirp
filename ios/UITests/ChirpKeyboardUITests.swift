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
        // Terminating the app at the end keeps Xcode's post-test diagnostics collection short.
        defer { app.activate(); if app.buttons["chirp.host.end"].exists { app.buttons["chirp.host.end"].tap() }; app.terminate() }
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

    /// Screenshots of the Live Activity on the lock screen and in the Dynamic Island, from synthetic sample activities
    /// (Debug simulator builds). Attachments only; it fails only if the app cannot start.
    @MainActor func testLiveActivityScreenshots() throws {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
        let lock = NSSelectorFromString("pressLockButton")
        guard XCUIDevice.shared.responds(to: lock) else { throw XCTSkip("This XCTest cannot lock the simulator") }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for kind in ["session-listening", "session-ready", "session-stale", "session-debug", "notes-recording", "notes-paused"] {
            let app = XCUIApplication()
            app.launchArguments = ["--chirp-ui-test", "--chirp-keyboard-host", "--chirp-activity-preview", kind]
            app.launch()
            XCTAssertTrue(app.staticTexts["chirp.host.setup"].waitForExistence(timeout: 10))
            sleep(kind == "session-stale" ? 7 : 3)
            // Background the app: the Dynamic Island shows the compact activity; a long press expands it.
            XCUIDevice.shared.press(.home)
            sleep(2)
            shot("activity-\(kind)-island-compact")
            if kind == "session-listening" || kind == "notes-recording" {
                let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.028))
                top.press(forDuration: 1.2)
                sleep(1)
                shot("activity-\(kind)-island-expanded")
                XCUIDevice.shared.press(.home)
            }
            XCUIDevice.shared.perform(lock)
            sleep(2)
            XCUIDevice.shared.press(.home) // wakes onto the lock screen without unlocking
            sleep(2)
            // iOS asks "Allow Live Activities from Chirp?" and later "continue to allow" on the lock screen; answer it.
            for label in ["Always Allow", "Allow"] {
                let allow = springboard.buttons[label]
                if allow.waitForExistence(timeout: 1.5) { allow.tap(); sleep(1); break }
            }
            shot("activity-\(kind)-lock")
            XCUIDevice.shared.press(.home)
            springboard.swipeUp()
            app.terminate()
        }
    }

    /// Screenshots of every keyboard state over Messages, using the Debug simulator preview file (screenshot runs only:
    /// set `TEST_RUNNER_CHIRP_PREVIEW_FILE` to the file in the App Group container, as ios/scripts do). Synthetic
    /// states, no dictation, nothing is sent.
    @MainActor func testKeyboardStateScreenshotsInMessages() throws {
        guard let path = ProcessInfo.processInfo.environment["CHIRP_PREVIEW_FILE"], !path.isEmpty else {
            throw XCTSkip("Screenshot run only: set TEST_RUNNER_CHIRP_PREVIEW_FILE.")
        }
        let states = (ProcessInfo.processInfo.environment["CHIRP_SHOT_STATES"] ?? "nosession armed listening polishing finished error armed+info")
            .split(separator: " ").map(String.init)
        func pin(_ state: String) { try? state.write(toFile: path, atomically: true, encoding: .utf8) }
        XCUIDevice.shared.orientation = .portrait
        pin("armed")
        try enableKeyboardInSettings()
        let messages = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")
        messages.launch()
        defer { try? FileManager.default.removeItem(atPath: path); messages.terminate() }
        let conversation = messages.cells.firstMatch
        guard conversation.waitForExistence(timeout: 10) else { throw XCTSkip("Messages shows no conversation") }
        conversation.tap()
        let field = messages.descendants(matching: .any).matching(identifier: "messageBodyField").firstMatch
        guard field.waitForExistence(timeout: 10) else { throw XCTSkip("Messages exposes no message body field") }
        field.tap()
        try selectChirpKeyboard(in: messages)
        XCTAssertTrue(messages.staticTexts["chirp.keyboard.status"].waitForExistence(timeout: 10))
        for state in states {
            pin(state)
            sleep(2)
            shot("keyboard-" + state.replacingOccurrences(of: "+", with: "-"))
        }
        // Landscape: the strip keeps 44 pt, the suggestion row and the keys shrink like Apple's.
        pin("armed")
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        shot("keyboard-landscape")
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        // Apple's keyboard in the same field, for the side-by-side comparison.
        let next = messages.buttons.matching(NSPredicate(format: "identifier == 'Next keyboard' OR label == 'Next keyboard'")).firstMatch
        if next.exists {
            next.tap()
            if messages.keys["space"].waitForExistence(timeout: 5) || messages.buttons["space"].waitForExistence(timeout: 1) {
                sleep(1)
                shot("keyboard-system")
            }
        }
    }

    @MainActor private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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
            app.terminate()
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
        // Idle keyboard: one status line, no paragraph, the full typing keys under it. Chips that don't apply are
        // hidden, so only Style is on screen; End session sits behind ⓘ.
        for id in ["primary", "info", "style", "space", "delete", "return", "shift"] {
            XCTAssertTrue(app.descendants(matching: .any)["chirp.keyboard." + id].exists, "Missing keyboard identifier: \(id)")
        }
        for id in ["cancel", "raw", "undo", "detail", "end"] {
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
        XCTAssertTrue(app.buttons["chirp.keyboard.end"].exists, "End session is in the ⓘ panel")
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
        // Height never changes: the strip and the keys stay exactly where they were while listening.
        XCTAssertEqual(primary.frame, primaryBefore, "The keyboard must not change height while listening")
        XCTAssertEqual(app.buttons["chirp.keyboard.space"].frame, spaceBefore)
        XCTAssertEqual(primary.label, "Stop dictation")
        XCTAssertTrue(app.buttons["chirp.keyboard.cancel"].exists, "Cancel takes over the suggestion row while listening")
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
        app.buttons["chirp.keyboard.info"].tap()
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
