package dev.chirp.android.shell


/** The one fix Home's connection card offers. */
internal enum class HomeFix(val label: String) { Pair("Pair Mac"), Microphone("Allow"), TailscaleOn("Turn on"), Retry("Check again") }

/** Compact status for the Notes top bar. Setup help belongs in Settings → Connection. */
internal data class NotesConnectionStatus(val label: String, val connected: Boolean)

internal fun notesConnectionStatus(paired: Boolean, reachable: Boolean?, tailscaleOff: Boolean, phone: Boolean) = when {
    paired && reachable != false && !tailscaleOff -> NotesConnectionStatus("Mac", true)
    !paired && phone -> NotesConnectionStatus("Phone", false)
    else -> NotesConnectionStatus("Offline", false)
}
