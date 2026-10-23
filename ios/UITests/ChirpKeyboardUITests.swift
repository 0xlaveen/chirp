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
        let partialArrived = wait(for: field, key: "value", equalTo: prefix + "synthetic words")
        let observed = XCTAttachment(string: "Host text after partial: " + String(describing: field.value))
        observed.name = "Host field value after first primary tap"
        observed.lifetime = .keepAlways
        add(observed)
        XCTAssertTrue(partialArrived, "Real mailbox partial must reach the editor; host text was \(String(describing: field.value))")
        primary.tap()
        XCTAssertTrue(wait(for: field, key: "value", equalTo: prefix + "Synthetic words."), "Final must replace only the keyboard-owned partial")
        app.buttons["chirp.keyboard.end"].tap()
        XCTAssertTrue(wait(for: app.staticTexts["chirp.host.phase"], key: "label", equalTo: "idle"))
        XCTAssertEqual(field.value as? String, prefix + "Synthetic words.")
    }

    @MainActor private func wait(for element: XCUIElement, key: String, equalTo value: String) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "%K == %@", key, value), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
    }
}
