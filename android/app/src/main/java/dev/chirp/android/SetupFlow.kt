package dev.chirp.android

internal const val PAGE_WELCOME = 0
internal const val PAGE_CHOICE = 1
internal const val PAGE_KEYBOARD = 2
internal const val PAGE_MIC = 3
internal const val PAGE_PAIR = 4
/** Every prerequisite is met: onboarding hands over to Chirp settings. */
internal const val ONBOARDING_DONE = 5

/**
 * First incomplete onboarding page. The welcome page opens only on a first run ([welcomed] false, nothing done yet); a user who is
 * already paired, or who has got past it, goes straight to the first unmet requirement. Explicit back navigation may still review completed pages.
 */
internal fun setupStep(enabled: Boolean, selected: Boolean, microphone: Boolean, paired: Boolean, welcomed: Boolean = true,
                       mode: InputMode? = InputMode.KEYBOARD, bubbleEnabled: Boolean = false,
                       floatingMicSkipped: Boolean = false): Int = when {
    !welcomed && !enabled && !selected && !microphone && !paired && mode == null -> PAGE_WELCOME
    mode == null -> PAGE_CHOICE
    mode == InputMode.KEYBOARD && (!enabled || !selected) -> PAGE_KEYBOARD
    mode == InputMode.OWN_KEYBOARD && !bubbleEnabled && !floatingMicSkipped -> PAGE_KEYBOARD
    !microphone -> PAGE_MIC
    !paired -> PAGE_PAIR
    else -> ONBOARDING_DONE
}

/** Why the last pairing attempt didn't end in a saved pairing; each has one recovery action on the pair page. */
internal enum class PairIssue { Unreachable, ScannerUnavailable, InvalidLink }
