import XCTest

/// Types with Chirp Keyboard's full keys (KeyboardKit's system-style keyboard) in the synthetic host: auto-capitals,
/// shift, the 123 page, a long-press accent, a suggestion, delete and the space-bar cursor. Synthetic text only.
final class ChirpKeyboardTypingUITests: XCTestCase {
    @MainActor func testTypingASentenceWithTheFullKeyboard() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--chirp-ui-test", "--chirp-keyboard-host", "--chirp-keyboard-host-empty", "--chirp-keyboard-host-prose"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.textViews["chirp.host.text"].waitForExistence(timeout: 10))
        try enableKeyboardInSettings()
        app.activate()
        let field = app.textViews["chirp.host.text"]
        field.tap()
        try selectChirpKeyboard(in: app)
        XCTAssertTrue(chirpKeyboard(in: app).waitForExistence(timeout: 10))
        keep(app, "typing-empty")

        // Sentence start: the first letter is a capital, the next ones are not.
        tapLetters("hi", in: app)
        XCTAssertEqual(value(field), "Hi")
        key("space", in: app).tap()
        // Shift: one capital, then lower case again. (Caps lock — two taps within 0.5 s — is covered by
        // KeyboardTypingTests: XCUITest's taps arrive further apart than that.)
        key("shift", in: app).tap()
        tapLetters("so", in: app)
        XCTAssertEqual(value(field), "Hi So")
        key("space", in: app).tap()
        // The 123 page; Space returns to the letters, as on Apple's keyboard.
        key("type.numeric", in: app).tap()
        key("key.4", in: app).tap()
        key("key.2", in: app).tap()
        keep(app, "typing-numbers")
        key("space", in: app).tap()
        XCTAssertEqual(value(field), "Hi So 42 ")
        // Long-press e for its accents; é is third in the callout (e è é ê …), whose cells are narrower than a key.
        // iPhone only: the iPad callout sits elsewhere and XCUITest cannot read it mid-gesture.
        tapLetters("caf", in: app)
        let phone = UIDevice.current.userInterfaceIdiom == .phone
        let e = letter("e", in: app)
        if phone {
            let center = e.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            center.press(forDuration: 1.0, thenDragTo: center.withOffset(CGVector(dx: e.frame.width * 1.4, dy: -e.frame.height)))
        } else {
            e.tap()
        }
        let cafe = phone ? "café" : "cafe"
        XCTAssertEqual(value(field), "Hi So 42 " + cafe)
        key("space", in: app).tap()
        // A misspelling: the bar offers the fix; tapping it replaces the word.
        tapLetters("helo", in: app)
        let hello = app.buttons["hello"]
        XCTAssertTrue(hello.waitForExistence(timeout: 5), "the suggestion bar offers the correction")
        keep(app, "typing-suggestions")
        hello.tap()
        XCTAssertEqual(value(field), "Hi So 42 \(cafe) hello ")
        key("delete", in: app).tap()
        XCTAssertEqual(value(field), "Hi So 42 \(cafe) hello")
        // Touch and hold the space bar, slide left: the caret moves, so the next letter lands inside the text.
        // iPhone only: on the iPad simulator XCUITest's press-and-drag never registers KeyboardKit's long press
        // (it types a space), so the iPad cursor drag is a device check.
        if phone {
            let middle = key("space", in: app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            middle.press(forDuration: 0.8, thenDragTo: middle.withOffset(CGVector(dx: -80, dy: 0)))
            tapLetters("x", in: app)
            let moved = value(field)
            XCTAssertTrue(moved.contains("x") && !moved.hasSuffix("x"), "the caret moved left before typing: \(moved)")
        }
        keep(app, "typing-done")
    }

    @MainActor private func key(_ id: String, in app: XCUIApplication) -> XCUIElement {
        let element = app.descendants(matching: .any).matching(identifier: "chirp.keyboard." + id).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 5), "Missing key \(id)")
        return element
    }

    /// A letter key whatever the current case (its identifier carries the cased character).
    @MainActor private func letter(_ char: Character, in app: XCUIApplication) -> XCUIElement {
        let ids = ["chirp.keyboard.key." + String(char).lowercased(), "chirp.keyboard.key." + String(char).uppercased()]
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@", ids)).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 5), "Missing letter \(char)")
        return element
    }

    @MainActor private func tapLetters(_ text: String, in app: XCUIApplication) {
        for char in text { letter(char, in: app).tap() }
    }

    private func value(_ field: XCUIElement) -> String { field.value as? String ?? "" }

    @MainActor private func keep(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
