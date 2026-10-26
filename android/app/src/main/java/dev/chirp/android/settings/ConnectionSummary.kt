package dev.chirp.android.settings

import dev.chirp.android.Health
import dev.chirp.android.cleanupAvailable
import dev.chirp.android.ui.StatusKind

internal class ConnectionSummary(val kind: StatusKind, val title: String, val summary: String?, val hint: String? = null)

/** What the Mac connection row says. [reachable] is null until a check has finished (the keyboard's summary never checks). */
internal fun connectionSummary(paired: Boolean, host: String, reachable: Boolean?, checking: Boolean, health: Health?): ConnectionSummary {
    if (!paired) return ConnectionSummary(StatusKind.Warning, "Not paired", "Pair your computer to dictate")
    val details = listOf(health?.engine ?: "Engine not reported", when {
        !health.cleanupAvailable() -> "clean-up off"
        health?.correctionLeavesMachine == true -> "clean-up via ${health.correctionHost}"
        else -> "clean-up on your computer"
    }).joinToString(" · ")
    return when {
        checking -> ConnectionSummary(StatusKind.Info, "Checking · $host", details)
        reachable == false -> ConnectionSummary(StatusKind.Warning, "Computer unreachable · $host", details,
            "Check Tailscale is connected on both devices. Wake the computer and start Chirp, then check again.")
        health?.ready == false -> ConnectionSummary(StatusKind.Info, "Paired · $host", "Computer is loading its speech model")
        reachable == true -> ConnectionSummary(StatusKind.Success, "Connected · $host", details)
        else -> ConnectionSummary(StatusKind.Info, "Paired · $host", details)
    }
}
