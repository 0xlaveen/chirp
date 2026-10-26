package dev.chirp.android

import java.io.InterruptedIOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.UnknownHostException
import javax.net.ssl.SSLException

/** Why the Mac couldn't be reached, from exception classes only: messages can carry hosts and are never read.
 * Wording is hedged because Android reports the symptom, not the cause. */
object ConnectionFailure {
    enum class Kind(val status: String, val offline: Boolean) {
        DNS("Can't find your computer on the tailnet — is it online?", true),
        DOWN("Computer may be asleep, or Chirp isn't running", true),
        TLS("Couldn't make a secure connection to your computer", false),
        OTHER("Computer unreachable — is Tailscale on?", false),
    }
    const val OFFLINE = "Computer offline · Check again"
    const val OFFLINE_DESCRIPTION = "Computer offline, double-tap to retry"
    const val CHECKING = "Checking your computer…"

    fun classify(failure: Throwable?): Kind {
        var current = failure
        repeat(6) {
            when (current) {
                null -> return Kind.OTHER
                is UnknownHostException -> return Kind.DNS
                is SSLException -> return Kind.TLS
                is InterruptedIOException, is ConnectException, is NoRouteToHostException -> return Kind.DOWN
                else -> current = current?.cause
            }
        }
        return Kind.OTHER
    }
    /** A deadline expiring before Ready is a connect timeout when the transport recorded no better reason. */
    fun status(kind: Kind?, timedOut: Boolean = false): String =
        (if (kind == null || kind == Kind.OTHER) (if (timedOut) Kind.DOWN else Kind.OTHER) else kind).status
    fun kind(status: String): Kind? = Kind.entries.firstOrNull { it.status == status }
}

/** The last health/prewarm outcome. Offline only for a short window: a Mac that woke up must not stay marked down. */
internal class OfflineState(private val now: () -> Long = android.os.SystemClock::elapsedRealtime, private val window: Long = 30000) {
    private var at = -1L
    var kind = ConnectionFailure.Kind.OTHER
        private set
    fun failed(kind: ConnectionFailure.Kind) { if (kind.offline) { at = now(); this.kind = kind } else reachable() }
    fun reachable() { at = -1L; kind = ConnectionFailure.Kind.OTHER }
    fun active() = at >= 0 && now() - at < window
    /** Milliseconds until active() turns false; 0 when it already is. */
    fun remaining() = if (active()) window - (now() - at) else 0L
}
