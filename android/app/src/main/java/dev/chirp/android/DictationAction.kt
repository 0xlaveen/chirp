package dev.chirp.android

/** Only local status strings choose actions; server error messages are never rendered. */
internal enum class DictationAction(val label: String) {
    PAIR("Pair Mac"), MICROPHONE("Open mic settings"), NETWORK("Check Tailscale");
    companion object {
        fun forStatus(status: String): DictationAction? = when {
            status.startsWith("Pair your Mac") || status.startsWith("Pairing refused") -> PAIR
            status.startsWith("Allow microphone") || status.startsWith("Microphone permission") -> MICROPHONE
            status.startsWith("Mac unreachable") || status.startsWith("Mac connection") -> NETWORK
            else -> null
        }
    }
}
