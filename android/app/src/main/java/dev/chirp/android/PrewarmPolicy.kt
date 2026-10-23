package dev.chirp.android

import android.os.SystemClock

/**
 * Decides when showing the keyboard is worth a TLS handshake, and rate-limits the health call.
 * Warm when the user dictated in the last [recentMs], or into this field's package in the last [packageMs];
 * otherwise the socket opens on press. Timestamps only, in memory: no text, no audio, nothing persisted.
 * All calls are main-thread.
 */
internal class PrewarmPolicy(
    private val now: () -> Long = SystemClock::elapsedRealtime,
    private val recentMs: Long = RECENT_MS,
    private val packageMs: Long = PACKAGE_MS,
    private val healthEveryMs: Long = HEALTH_EVERY_MS,
) {
    private var lastDictation: Long? = null
    private var lastHealth: Long? = null
    private val packages = object : LinkedHashMap<String, Long>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Long>) = size > MAX_PACKAGES
    }

    fun dictated(pkg: String?) {
        val at = now()
        lastDictation = at
        if (pkg != null) packages[pkg] = at
    }
    fun shouldPrewarm(pkg: String?): Boolean {
        val at = now()
        if (lastDictation?.let { at - it < recentMs } == true) return true
        return pkg?.let { packages[it] }?.let { at - it < packageMs } == true
    }
    /** True at most once per [healthEveryMs]; claims the slot. */
    fun healthDue(): Boolean {
        val at = now()
        if (lastHealth?.let { at - it < healthEveryMs } == true) return false
        lastHealth = at
        return true
    }
    /** A failed check frees the slot so the next show tries again. */
    fun healthFailed() { lastHealth = null }

    companion object {
        const val RECENT_MS = 10 * 60_000L
        const val PACKAGE_MS = 24 * 3_600_000L
        const val HEALTH_EVERY_MS = 60_000L
        const val MAX_PACKAGES = 16
    }
}
