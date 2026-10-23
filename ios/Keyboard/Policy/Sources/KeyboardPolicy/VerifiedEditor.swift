/// Shared by the UIKit adapter and fake-proxy tests. Run synchronously on the
/// main actor so local callbacks cannot interleave with an authorized edit.
@MainActor
public enum VerifiedEditor {
    public static func apply(_ plan: EditPlan, context: () -> CursorContext,
                             deleteBackward: () -> Void, insertText: (String) -> Void) -> Bool {
        guard context() == plan.expected else { return false }
        var remaining = plan.deletedText
        while !remaining.isEmpty {
            guard plan.permitsDeletion(context: context(), remaining: remaining) else { return false }
            deleteBackward()
            remaining.removeLast()
            var expected = plan.insertionContext
            expected.before = (expected.before ?? "") + remaining
            guard context() == expected else { return false }
        }
        guard context() == plan.insertionContext else { return false }
        if !plan.insertedText.isEmpty { insertText(plan.insertedText) }
        return context() == plan.resultingContext
    }
}
