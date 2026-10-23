import Testing
@testable import KeyboardPolicy

/// Ported from Android's AutoEnterTest (#101), within what an iOS custom keyboard can see.
struct AutoEnterTests {
    func press(_ mode: AutoEnterMode, _ key: ReturnKey, kept: Bool = false, moved: Bool = false,
               last: Bool = true, text: String = "Hello.") -> Bool {
        AutoEnter.presses(mode: mode, returnKey: key, kept: kept, moved: moved, lastSegment: last, text: text)
    }
    @Test func offByDefaultAndNeverWhenOff() {
        #expect(AutoEnterMode(rawValue: "missing") == nil)
        for key in [ReturnKey.plain, .send, .go, .done, .search, .next, .other] { #expect(!press(.off, key)) }
    }
    @Test func actionKeysPressOnlySendGoDoneAndFriends() {
        for key in [ReturnKey.send, .go, .done, .join, .route, .continue] { #expect(press(.actionKeys, key), "\(key)") }
        for key in [ReturnKey.plain, .other, .search, .next] { #expect(!press(.actionKeys, key), "\(key)") }
    }
    @Test func alwaysAddsPlainFieldsButNeverSearchOrNext() {
        #expect(press(.always, .plain) && press(.always, .other) && press(.always, .send))
        #expect(!press(.always, .search) && !press(.always, .next))
    }
    @Test func neverAfterKeptMovedBlankOrAnEarlierSegment() {
        #expect(!press(.always, .send, kept: true))
        #expect(!press(.always, .send, moved: true))
        #expect(!press(.always, .send, last: false), "Long dictation sends once, after the last segment")
        #expect(!press(.always, .send, text: "  \n"))
    }
}
