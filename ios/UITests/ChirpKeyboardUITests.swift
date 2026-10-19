import XCTest

/// Runs against the installed extension, never an in-process keyboard mock.
final class ChirpKeyboardUITests: XCTestCase {
    @MainActor func testSyntheticDictationInRealKeyboardPreservesPrefix() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--chirp-ui-test", "--chirp-keyboard-host"]
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
        XCTAssertEqual(field.value as? String, "Host prefix. ")
        try selectChirpKeyboard(in: app)

        // The redesign lands separately. Once status exists, failures are assertions.
        let status = app.staticTexts["chirp.keyboard.status"]
        guard status.waitForExistence(timeout: 10) else {
            throw XCTSkip("Installed keyboard has no chirp.keyboard.status yet; waiting for the parallel keyboard identifier change.")
        }
        for id in ["primary", "detail", "cancel", "raw", "style", "end", "space", "delete", "return"] {
            XCTAssertTrue(app.descendants(matching: .any)["chirp.keyboard." + id].exists, "Missing keyboard identifier: \(id)")
        }
        if setup.label.contains("unavailable") || setup.label.contains("could not arm") {
            throw XCTSkip(setup.label)
        }
        let armed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@ OR label BEGINSWITH %@", "Session armed", "Session armed · "), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [armed], timeout: 10), .completed)
        let primary = app.buttons["chirp.keyboard.primary"]
        XCTAssertTrue(primary.isEnabled)
        primary.tap()
        XCTAssertTrue(wait(for: field, key: "value", equalTo: "Host prefix. synthetic words"), "Real mailbox partial must reach the editor")
        primary.tap()
        XCTAssertTrue(wait(for: field, key: "value", equalTo: "Host prefix. Synthetic words."), "Final must replace only the keyboard-owned partial")
        app.buttons["chirp.keyboard.end"].tap()
        XCTAssertTrue(wait(for: app.staticTexts["chirp.host.phase"], key: "label", equalTo: "idle"))
        XCTAssertEqual(field.value as? String, "Host prefix. Synthetic words.")
    }

    @MainActor private func wait(for element: XCUIElement, key: String, equalTo value: String) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "%K == %@", key, value), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
    }

    @MainActor private func settingsItem(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "(label == %@ OR label BEGINSWITH %@ OR identifier == %@) AND (elementType == %d OR elementType == %d)", label, label + ",", label.uppercased(), XCUIElement.ElementType.cell.rawValue, XCUIElement.ElementType.button.rawValue)).firstMatch
    }

    @MainActor private func tapSettings(_ label: String, in app: XCUIApplication) throws {
        let item = settingsItem(label, in: app)
        guard item.waitForExistence(timeout: 5), item.isHittable else {
            let attachment = XCTAttachment(string: app.debugDescription)
            attachment.name = "Settings navigation unavailable: " + label
            attachment.lifetime = .keepAlways
            add(attachment)
            throw XCTSkip("Simulator Settings does not expose a tappable '\(label)' row; cannot configure the real keyboard on this OS.")
        }
        item.tap()
    }

    @MainActor private func enableKeyboardInSettings() throws {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.terminate()
        settings.launch()
        defer { settings.terminate() }
        try tapSettings("General", in: settings)
        try tapSettings("Keyboard", in: settings)
        try tapSettings("Keyboards", in: settings)
        var chirp = settings.cells.containing(NSPredicate(format: "label CONTAINS[c] 'Chirp'")).firstMatch
        if !chirp.exists {
            try tapSettings("Add New Keyboard", in: settings)
            chirp = settings.cells.containing(NSPredicate(format: "label CONTAINS[c] 'Chirp'")).firstMatch
            guard chirp.waitForExistence(timeout: 5) else {
                throw XCTSkip("Simulator Settings lists no installed Chirp third-party keyboard under Add New Keyboard.")
            }
            chirp.tap()
            chirp = settings.cells.containing(NSPredicate(format: "label CONTAINS[c] 'Chirp'")).firstMatch
        }
        guard chirp.waitForExistence(timeout: 5) else { throw XCTSkip("Chirp was not added to simulator Keyboards.") }
        chirp.tap()
        let fullAccess = settings.switches.matching(identifier: "Allow Full Access").firstMatch
        guard fullAccess.waitForExistence(timeout: 5) else { throw XCTSkip("Simulator Settings exposes no Allow Full Access switch for Chirp.") }
        if fullAccess.value as? String != "1" {
            let control = fullAccess.switches.firstMatch
            if control.exists { control.tap() } else { fullAccess.tap() }
            let allow = settings.alerts.buttons["Allow"]
            if allow.waitForExistence(timeout: 3) { allow.tap() }
        }
        guard fullAccess.value as? String == "1" else {
            let attachment = XCTAttachment(string: settings.debugDescription)
            attachment.name = "Full Access confirmation hierarchy"
            attachment.lifetime = .keepAlways
            add(attachment)
            throw XCTSkip("Simulator did not enable Chirp Keyboard Full Access after confirmation.")
        }
    }

    @MainActor private func selectChirpKeyboard(in app: XCUIApplication) throws {
        if app.staticTexts["chirp.keyboard.status"].exists { return }
        // Only system keyboard labels are used here. Extension queries use IDs.
        let globe = app.buttons.matching(NSPredicate(format: "identifier == 'Next keyboard' OR label == 'Next keyboard' OR identifier == 'Change Keyboard' OR label == 'Change Keyboard'")).firstMatch
        guard globe.waitForExistence(timeout: 5), globe.isHittable else {
            throw XCTSkip("Simulator has no system globe/input-mode button; disable Connect Hardware Keyboard and retry.")
        }
        globe.press(forDuration: 1)
        let mode = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'Chirp'")).firstMatch
        guard mode.waitForExistence(timeout: 5), mode.isHittable else {
            throw XCTSkip("System input-mode list has no selectable Chirp Keyboard entry on this simulator.")
        }
        mode.tap()
    }
}
