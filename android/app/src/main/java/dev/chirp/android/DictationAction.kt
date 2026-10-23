package dev.chirp.android

/** Only local status strings choose actions; server error messages are never rendered.
 * Prompt actions keep their status text visible beside a button instead of replacing it. */
internal enum class DictationAction(val label: String, val prompt: Boolean = false) {
    PAIR("Pair Mac"), MICROPHONE("Open mic settings"), NETWORK("Check Tailscale"),
    TAILSCALE_ON("Turn on", prompt = true), TAILSCALE_OPEN("Open Tailscale", prompt = true), TAILSCALE_SETUP("Set up", prompt = true);
    companion object {
        const val TAILSCALE_OFF = "Tailscale is off"
        const val TAILSCALE_STALLED = "Tailscale didn't connect"
        const val TAILSCALE_MISSING = "Tailscale isn't installed"
        fun forStatus(status: String): DictationAction? = when {
            status.startsWith("Pair your Mac") || status.startsWith("Pairing refused") -> PAIR
            status.startsWith("Allow microphone") || status.startsWith("Microphone permission") -> MICROPHONE
            status.startsWith("Mac unreachable") || status.startsWith("Mac connection") -> NETWORK
            status.startsWith(TAILSCALE_OFF) -> TAILSCALE_ON
            status.startsWith(TAILSCALE_STALLED) -> TAILSCALE_OPEN
            status.startsWith(TAILSCALE_MISSING) -> TAILSCALE_SETUP
            else -> null
        }
    }
}
