package dev.chirp.android.shell


internal enum class SetupNeed(val title: String, val action: String, val section: String) {
    Pair("Pair your Mac", "Scan code", "pair"),
    Microphone("Allow the microphone", "Allow", "microphone"),
    Keyboard("Turn on Chirp Keyboard", "Set up", "input"),
    FloatingMic("Turn on the floating mic", "Set up", "input"),
}

internal data class SetupProgress(val missing: SetupNeed?, val done: Int)

/** Pairing, microphone, then the chosen input method: exactly three prerequisites. */
internal fun setupProgress(paired: Boolean, mic: Boolean, keyboard: Boolean, selected: Boolean,
                           floating: Boolean, ownKeyboard: Boolean): SetupProgress {
    val steps = listOf(SetupNeed.Pair to paired, SetupNeed.Microphone to mic,
        (if (ownKeyboard) SetupNeed.FloatingMic else SetupNeed.Keyboard) to
            (if (ownKeyboard) floating else keyboard && selected))
    return SetupProgress(steps.firstOrNull { !it.second }?.first, steps.count { it.second })
}

/** The one fix Home's connection card offers. */
internal enum class HomeFix(val label: String) { Pair("Pair Mac"), Microphone("Allow"), TailscaleOn("Turn on"), Retry("Check again") }

/** Compact status for the Notes top bar. Setup help belongs in Settings → Connection. */
internal data class NotesConnectionStatus(val label: String, val connected: Boolean)

internal fun notesConnectionStatus(paired: Boolean, reachable: Boolean?, tailscaleOff: Boolean, phone: Boolean) = when {
    paired && reachable != false && !tailscaleOff -> NotesConnectionStatus("Mac", true)
    !paired && phone -> NotesConnectionStatus("Phone", false)
    else -> NotesConnectionStatus("Offline", false)
}
