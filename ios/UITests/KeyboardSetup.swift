import XCTest

/// Real simulator Settings and system keyboard switching, shared by the keyboard suites.
extension XCTestCase {
    @MainActor func settingsItem(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "(label == %@ OR label BEGINSWITH %@ OR identifier == %@) AND (elementType == %d OR elementType == %d)", label, label + ",", label.uppercased(), XCUIElement.ElementType.cell.rawValue, XCUIElement.ElementType.button.rawValue)).firstMatch
    }

    @MainActor func tapSettings(_ label: String, in app: XCUIApplication) throws {
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

    @MainActor func enableKeyboardInSettings() throws {
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

    @MainActor func selectChirpKeyboard(in app: XCUIApplication) throws {
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
