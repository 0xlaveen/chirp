package dev.chirp.android

/** First incomplete prerequisite. Explicit back navigation may still review completed steps. */
internal fun setupStep(enabled: Boolean, selected: Boolean, microphone: Boolean, paired: Boolean): Int = when {
    !enabled || !selected -> 0
    !microphone -> 1
    !paired -> 2
    else -> 3
}
