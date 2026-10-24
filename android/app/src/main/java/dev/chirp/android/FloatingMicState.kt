package dev.chirp.android

/** The floating mic panel's states (#167). The bubble itself is idle, or listening while held. */
internal enum class FloatingState { IDLE, CONNECTING, LISTENING, FINISHING, INSERTED, POLISHED, READY_TO_COPY, ERROR }

/** Each floating mic error carries exactly one fix (#167). Only local status strings choose it; server text is never shown. */
internal enum class BubbleFix(val label: String, val description: String) {
    PAIR("Pair Mac", "Pair your Mac in Chirp"),
    MICROPHONE("Allow", "Allow the microphone in Chirp's app permissions"),
    CHECK_AGAIN("Check again", "Check the Mac connection and dictate again"),
    TAILSCALE_ON("Turn on", "Turn on Tailscale"),
    TAILSCALE_OPEN("Open Tailscale", "Open Tailscale"),
    TAILSCALE_SETUP("Set up", "Set up Tailscale in Chirp"),
    QUICK_DICTATE("Use Quick dictate", "Dictate in Chirp instead, then copy"),
    SETTINGS("Open settings", "Open Chirp settings"),
    TRY_AGAIN("Try again", "Dictate again");

    companion object {
        const val NOT_PAIRED = "Pair your Mac to dictate"
        const val NO_MICROPHONE = "Allow the microphone for Chirp"
        const val BLOCKED = "Android blocked the microphone here"

        fun forStatus(status: String): BubbleFix? = when {
            status.startsWith(NOT_PAIRED) || status.startsWith("Pair your Mac") || status.startsWith("Pairing refused") -> PAIR
            status.startsWith(NO_MICROPHONE) || status.startsWith("Allow microphone") || status.startsWith("Microphone permission") -> MICROPHONE
            status.startsWith(BLOCKED) -> QUICK_DICTATE
            status.startsWith(DictationAction.TAILSCALE_OFF) -> TAILSCALE_ON
            status.startsWith(DictationAction.TAILSCALE_STALLED) -> TAILSCALE_OPEN
            status.startsWith(DictationAction.TAILSCALE_MISSING) -> TAILSCALE_SETUP
            ConnectionFailure.kind(status) != null || status.startsWith("Mac unreachable") || status.startsWith("Mac connection") ||
                status.startsWith("Mac took too long") -> CHECK_AGAIN
            status.startsWith("Clean-up prompt") -> SETTINGS
            Cue.isError(status) -> TRY_AGAIN
            else -> null
        }
    }
}

/**
 * Everything the panel draws, so a render is a pure function of it. [text]/[stable] are live partials or, in
 * Ready to copy and errors, the kept words.
 */
internal data class PanelModel(
    val state: FloatingState,
    val status: String = "",
    val text: String = "",
    val stable: String = "",
    val polishing: Boolean = false,
    val copyMode: Boolean = false,
    val level: Double = 0.0,
    val retention: Boolean = false,
) {
    val fix: BubbleFix? get() = if (state == FloatingState.ERROR) BubbleFix.forStatus(status) else null
    val active get() = state == FloatingState.CONNECTING || state == FloatingState.LISTENING || state == FloatingState.FINISHING

    /** The one line under the header. Errors say their own reason. */
    val headline: String get() = when (state) {
        FloatingState.IDLE -> if (copyMode) "This field can't be filled automatically" else "Tap to dictate"
        FloatingState.CONNECTING -> "Connecting to your Mac…"
        FloatingState.LISTENING -> "Listening"
        FloatingState.FINISHING -> if (polishing) "Polishing…" else "Finishing…"
        FloatingState.INSERTED -> "Inserted"
        FloatingState.POLISHED -> "Inserted"
        FloatingState.READY_TO_COPY -> if (copyMode) "This field can't be filled automatically" else "Couldn't put this in the field"
        FloatingState.ERROR -> status
    }
}
