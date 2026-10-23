package dev.chirp.android

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import androidx.core.content.edit
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.ceil

enum class TimingOutcome { FINAL, EMPTY, KEPT, FAILED, CANCELLED }
enum class TimingError { NONE, CONNECT, LOST, AUTH, BAD_AUDIO, ENGINE, BUSY, TOO_LONG, BAD_REQUEST, SERVER }
enum class TimingNetwork { WIFI, CELLULAR, ETHERNET, OTHER, NONE }

/** Numbers and enums only: no text, audio, URLs, hosts or tokens. Durations are milliseconds. */
internal data class SessionTiming(
    val time: Long, val outcome: TimingOutcome, val error: TimingError = TimingError.NONE,
    val network: TimingNetwork = TimingNetwork.NONE, val vpn: Boolean = false, val prewarmed: Boolean = false,
    val connectMs: Long? = null, val readyMs: Long? = null, val firstPartialMs: Long? = null,
    val stopFinalMs: Long? = null, val polishMs: Long? = null, val audioMs: Long = 0,
)

/** Last [MAX] sessions in a private shared-preferences file; backup and device transfer exclude it (data_extraction_rules.xml). */
internal class TimingLog(context: Context) {
    private val prefs = context.getSharedPreferences("session_timings", Context.MODE_PRIVATE)
    @Synchronized fun record(entry: SessionTiming) { prefs.edit { putString(KEY, encode((entries() + entry).takeLast(MAX))) } }
    @Synchronized fun entries(): List<SessionTiming> = decode(prefs.getString(KEY, null))
    @Synchronized fun clear() { prefs.edit { remove(KEY) } }
    fun summary() = TimingSummary.of(entries())

    companion object {
        const val MAX = 50
        private const val KEY = "entries"
        fun encode(items: List<SessionTiming>): String = JSONArray().also { array ->
            items.forEach { t ->
                array.put(JSONObject().put("t", t.time).put("out", t.outcome.name).put("err", t.error.name).put("net", t.network.name)
                    .put("vpn", t.vpn).put("warm", t.prewarmed).put("a", t.audioMs)
                    .also { o -> listOf("c" to t.connectMs, "r" to t.readyMs, "p" to t.firstPartialMs, "s" to t.stopFinalMs, "o" to t.polishMs)
                        .forEach { (key, value) -> if (value != null) o.put(key, value) } })
            }
        }.toString()
        fun decode(raw: String?): List<SessionTiming> = try {
            val array = JSONArray(raw ?: "[]")
            (0 until array.length()).mapNotNull { i ->
                try {
                    val o = array.getJSONObject(i)
                    fun ms(key: String) = if (o.has(key)) o.getLong(key) else null
                    SessionTiming(o.getLong("t"), TimingOutcome.valueOf(o.getString("out")), TimingError.valueOf(o.getString("err")),
                        TimingNetwork.valueOf(o.getString("net")), o.getBoolean("vpn"), o.getBoolean("warm"),
                        ms("c"), ms("r"), ms("p"), ms("s"), ms("o"), o.getLong("a"))
                } catch (_: Exception) { null }
            }.takeLast(MAX)
        } catch (_: Exception) { emptyList() }
    }
}

internal object TimingSummary {
    /** Nearest rank on [values]; null when empty. */
    fun percentile(values: List<Long>, p: Int): Long? =
        if (values.isEmpty()) null else values.sorted()[(ceil(p / 100.0 * values.size).toInt() - 1).coerceIn(0, values.size - 1)]

    fun of(items: List<SessionTiming>): String {
        if (items.isEmpty()) return "No sessions recorded"
        fun row(label: String, values: List<Long>, seconds: Boolean = false): String {
            fun show(v: Long?) = if (v == null) "–" else if (seconds) "%.1f s".format(java.util.Locale.US, v / 1000.0) else "$v ms"
            return "$label  p50 ${show(percentile(values, 50))} · p90 ${show(percentile(values, 90))} · n=${values.size}"
        }
        fun count(names: List<String>) = names.groupingBy { it }.eachCount().entries.sortedBy { it.key }.joinToString(" · ") { "${it.key} ${it.value}" }
        return listOf(
            "Last ${items.size} of up to ${TimingLog.MAX} sessions",
            row("connect", items.mapNotNull { it.connectMs }), row("ready", items.mapNotNull { it.readyMs }),
            row("first partial", items.mapNotNull { it.firstPartialMs }), row("stop → final", items.mapNotNull { it.stopFinalMs }),
            row("polishing", items.mapNotNull { it.polishMs }), row("audio", items.map { it.audioMs }, seconds = true),
            "Outcomes: " + count(items.map { it.outcome.name.lowercase() }),
            items.filter { it.error != TimingError.NONE }.let { if (it.isEmpty()) null else "Errors: " + count(it.map { e -> e.error.name.lowercase() }) },
            "Network: " + count(items.map { it.network.name.lowercase() }) +
                " · VPN up ${items.count { it.vpn }}/${items.size} · prewarmed ${items.count { it.prewarmed }}/${items.size}",
        ).filterNotNull().joinToString("\n")
    }
}

/** One session's marks on one clock, written once. All calls are main-thread. */
internal class SessionTimer(
    private val log: TimingLog,
    private val network: () -> Pair<TimingNetwork, Boolean> = { TimingNetwork.NONE to false },
    private val now: () -> Long = { System.nanoTime() / 1_000_000 },
    private val wall: () -> Long = System::currentTimeMillis,
) {
    private val began = now()
    private var transport: ImeTransport? = null
    private var prewarmed = false
    private var readyAt: Long? = null
    private var partialAt: Long? = null
    private var stopAt: Long? = null
    private var polishAt: Long? = null
    private var serverCode: String? = null
    private var done = false
    fun attach(transport: ImeTransport, prewarmed: Boolean) { this.transport = transport; this.prewarmed = prewarmed }
    fun ready() { if (readyAt == null) readyAt = now() }
    fun partial() { if (partialAt == null) partialAt = now() }
    fun stopped() { if (stopAt == null) stopAt = now() }
    fun polishing() { if (polishAt == null) polishAt = now() }
    fun code(value: String) { serverCode = value }
    fun final(empty: Boolean) = finish(if (empty) TimingOutcome.EMPTY else TimingOutcome.FINAL, TimingError.NONE)
    fun cancelled() = finish(TimingOutcome.CANCELLED, TimingError.NONE)
    fun failed(kept: Boolean) = finish(if (kept) TimingOutcome.KEPT else TimingOutcome.FAILED, when (serverCode) {
        null -> if (readyAt == null) TimingError.CONNECT else TimingError.LOST
        "auth" -> TimingError.AUTH
        "bad_audio" -> TimingError.BAD_AUDIO
        "engine" -> TimingError.ENGINE
        "busy" -> TimingError.BUSY
        "too_long" -> TimingError.TOO_LONG
        "bad_request" -> TimingError.BAD_REQUEST
        else -> TimingError.SERVER
    })
    private fun finish(outcome: TimingOutcome, error: TimingError) {
        if (done) return
        done = true
        val end = now()
        val opened = transport?.openedAt?.takeIf { it >= 0 }
        val (kind, vpn) = try { network() } catch (_: Exception) { TimingNetwork.NONE to false }
        try {
            log.record(SessionTiming(wall(), outcome, error, kind, vpn, prewarmed,
                connectMs = opened?.let { (it - began).coerceAtLeast(0) }, readyMs = readyAt?.let { it - began },
                firstPartialMs = partialAt?.let { it - began },
                stopFinalMs = if (outcome == TimingOutcome.FINAL || outcome == TimingOutcome.EMPTY) stopAt?.let { end - it } else null,
                polishMs = polishAt?.takeIf { outcome == TimingOutcome.FINAL || outcome == TimingOutcome.EMPTY }?.let { end - it },
                audioMs = (stopAt ?: end) - began))
        } catch (_: Exception) { /* Timings must never affect dictation. */ }
    }
}

internal object TimingNetworks {
    /** Underlying transport (VPN excluded) and whether any VPN is up; never reads addresses or names. */
    fun current(context: Context): Pair<TimingNetwork, Boolean> {
        val manager = context.getSystemService(ConnectivityManager::class.java) ?: return TimingNetwork.NONE to false
        @Suppress("DEPRECATION")
        val caps = manager.allNetworks.mapNotNull { manager.getNetworkCapabilities(it) }
        val vpn = caps.any { it.hasTransport(NetworkCapabilities.TRANSPORT_VPN) }
        val real = caps.filter { !it.hasTransport(NetworkCapabilities.TRANSPORT_VPN) && it.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) }
        return of(real.any { it.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) }, real.any { it.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) },
            real.any { it.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) }, real.isNotEmpty()) to vpn
    }
    fun of(wifi: Boolean, cellular: Boolean, ethernet: Boolean, any: Boolean) = when {
        wifi -> TimingNetwork.WIFI
        cellular -> TimingNetwork.CELLULAR
        ethernet -> TimingNetwork.ETHERNET
        any -> TimingNetwork.OTHER
        else -> TimingNetwork.NONE
    }
}

/** Setup and settings Diagnostics: session timings first, then the crash log. */
internal object DiagnosticsReport {
    fun text(context: Context) = "Session timings\n${TimingLog(context).summary()}\n\nCrashes\n${CrashLog(context).text()}"
    fun clearTimings(context: Context) = TimingLog(context).clear()
}
