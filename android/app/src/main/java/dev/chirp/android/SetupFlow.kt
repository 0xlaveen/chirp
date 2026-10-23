package dev.chirp.android

internal const val PAGE_WELCOME = 0
internal const val PAGE_KEYBOARD = 1
internal const val PAGE_MIC = 2
internal const val PAGE_PAIR = 3
/** Every prerequisite is met: onboarding hands over to Chirp settings. */
internal const val ONBOARDING_DONE = 4

/**
 * First incomplete onboarding page. The welcome page opens only on a first run ([welcomed] false, nothing done yet); a user who is
 * already paired, or who has got past it, goes straight to the first unmet requirement. Explicit back navigation may still review completed pages.
 */
internal fun setupStep(enabled: Boolean, selected: Boolean, microphone: Boolean, paired: Boolean, welcomed: Boolean = true): Int = when {
    !enabled || !selected -> if (!welcomed && !enabled && !selected && !microphone && !paired) PAGE_WELCOME else PAGE_KEYBOARD
    !microphone -> PAGE_MIC
    !paired -> PAGE_PAIR
    else -> ONBOARDING_DONE
}

/** Why the last pairing attempt didn't end in a saved pairing; each has one recovery action on the pair page. */
internal enum class PairIssue { Unreachable, ScannerUnavailable, InvalidLink }
