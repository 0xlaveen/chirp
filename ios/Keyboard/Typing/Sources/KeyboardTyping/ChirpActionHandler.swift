import UIKit
import KeyboardKit
import KeyboardPolicy

/// KeyboardKit's standard key handling plus two Chirp rules:
/// - `willEdit` runs before any key or suggestion edits the text, so a dictation the keyboard owns is released
///   before the user's own typing lands next to it (the same rule Space, Delete and Return always had).
/// - Delete right after an autocorrection puts back what was typed (Apple's revert), and that word is not
///   corrected again.
public final class ChirpActionHandler: KeyboardAction.StandardActionHandler {
    public var willEdit: (() -> Void)?
    private(set) var memory: AutocorrectMemory?

    public override func handle(_ gesture: Keyboard.Gesture, on action: KeyboardAction, replaced: Bool) {
        let edits = !replaced && action.editsText(on: gesture)
        if edits { willEdit?() }
        if gesture == .press, action == .backspace, revertAutocorrection() {
            tryTriggerFeedback(for: gesture, on: action)
            return
        }
        // Any other edit ends the chance to revert; an autocorrection made by this key sets it again.
        if edits, gesture == .release { memory = nil }
        super.handle(gesture, on: action, replaced: replaced)
    }

    public override func handle(_ suggestion: Autocomplete.Suggestion) {
        willEdit?()
        memory = nil
        super.handle(suggestion)
    }

    public override func tryApplyAutocorrectSuggestion(before gesture: Keyboard.Gesture, on action: KeyboardAction) {
        guard shouldApplyAutocorrectSuggestion(before: gesture, on: action),
              let fix = autocompleteContext.suggestions.first(where: \.isAutocorrect) else { return }
        let typed = Typing.currentWord(before: keyboardContext.textDocumentProxy.documentContextBeforeInput)
        super.tryApplyAutocorrectSuggestion(before: gesture, on: action)
        if !typed.isEmpty, typed != fix.text { memory = AutocorrectMemory(original: typed, corrected: fix.text) }
    }

    /// Tapping the quoted, typed word keeps it and teaches it to the on-device dictionary.
    public override func shouldAutolearnSuggestion(_ suggestion: Autocomplete.Suggestion) -> Bool {
        suggestion.isUnknown && !suggestion.text.isEmpty
    }

    private func revertAutocorrection() -> Bool {
        let proxy = keyboardContext.textDocumentProxy
        guard let plan = Typing.revert(memory, before: proxy.documentContextBeforeInput), let memory else { return false }
        self.memory = nil
        for _ in 0..<plan.delete { proxy.deleteBackward() }
        proxy.insertText(plan.insert)
        autocompleteService?.learnWord(memory.original)
        autocompleteContext.reset()
        return true
    }
}

extension KeyboardAction {
    /// Whether this key changes the document (letters, space, delete, return, text and domain keys) rather than
    /// the keyboard (shift, 123, globe).
    func editsText(on gesture: Keyboard.Gesture) -> Bool {
        switch self {
        case .backspace: gesture == .press || gesture == .repeatPress
        case .character, .characterMargin, .diacritic, .emoji, .primary, .space, .text, .urlDomain, .tab: gesture == .release
        default: false
        }
    }
}
