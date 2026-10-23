package dev.chirp.android

import android.os.Looper
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 37])
class SessionTimingsTest {
    private val context get() = RuntimeEnvironment.getApplication()
    private fun entry(i: Int, outcome: TimingOutcome = TimingOutcome.FINAL) = SessionTiming(i.toLong(), outcome, readyMs = i.toLong(), audioMs = 1000L * i)

    private class Harness(val log: TimingLog, opened: Long = -1L) {
        var clock = 1000L
        val order = mutableListOf<String>()
        lateinit var fake: ChirpImeServiceTest.FakeTransport
        val timer = SessionTimer(log, { TimingNetwork.WIFI to true }, { clock }, { 42L })
        val session = DictationStream(
            transportFactory = { event, failure ->
                ChirpImeServiceTest.FakeTransport(event, failure, order).also { fake = it }
                    .let { f -> object : ImeTransport by f { override val openedAt = opened }.also { timer.attach(it, opened in 0..999) } }
            },
            captureFactory = { frame, _, done -> ChirpImeServiceTest.FakeCapture(frame, done, order) },
            changed = { _, _ -> }, level = {}, retention = {}, final = {}, ended = {}, kept = { _, _ -> }, timing = timer,
        )
        fun at(ms: Long) { clock = ms }
    }

    @Test fun `a polished session records every phase`() {
        val log = TimingLog(context); log.clear()
        val h = Harness(log, opened = 1030); h.session.start(true)
        h.at(1050); h.fake.ready()
        h.at(1200); h.fake.partial()
        h.at(3000); h.session.stop(); shadowOf(Looper.getMainLooper()).idle()
        h.at(3100); h.fake.event(ServerEvent.Correcting(2, "synthetic", "default"))
        h.at(3400); h.fake.final()
        val t = log.entries().single()
        assertEquals(TimingOutcome.FINAL, t.outcome); assertEquals(TimingError.NONE, t.error)
        assertEquals(30L, t.connectMs); assertEquals(50L, t.readyMs); assertEquals(200L, t.firstPartialMs)
        assertEquals(400L, t.stopFinalMs); assertEquals(300L, t.polishMs); assertEquals(2000L, t.audioMs)
        assertEquals(TimingNetwork.WIFI, t.network); assertTrue(t.vpn); assertFalse(t.prewarmed); assertEquals(42L, t.time)
    }
    @Test fun `a prewarmed socket opened before the press records zero connect time and the flag`() {
        val log = TimingLog(context); log.clear()
        val h = Harness(log, opened = 500); h.session.start(false)
        h.at(1040); h.fake.ready(); h.at(2000); h.session.stop(); shadowOf(Looper.getMainLooper()).idle(); h.at(2100); h.fake.final()
        val t = log.entries().single()
        assertEquals(0L, t.connectMs); assertEquals(40L, t.readyMs); assertTrue(t.prewarmed); assertNull(t.polishMs)
    }
    @Test fun `server failures map to error codes and a kept partial is a kept outcome`() {
        val log = TimingLog(context); log.clear()
        Harness(log).apply { session.start(false); at(1010); fake.ready(); fake.partial(); fake.event(ServerEvent.Failure("busy")) }
        Harness(log).apply { session.start(false); fake.event(ServerEvent.Failure("engine")) }
        Harness(log).apply { session.start(false); fake.failure() }
        Harness(log).apply { session.start(false); fake.ready(); fake.failure() }
        val all = log.entries()
        assertEquals(listOf(TimingOutcome.KEPT, TimingOutcome.FAILED, TimingOutcome.FAILED, TimingOutcome.FAILED), all.map { it.outcome })
        assertEquals(listOf(TimingError.BUSY, TimingError.ENGINE, TimingError.CONNECT, TimingError.LOST), all.map { it.error })
        assertNull(all[0].stopFinalMs)
    }
    @Test fun `cancel is recorded once and an empty final is its own outcome`() {
        val log = TimingLog(context); log.clear()
        Harness(log).apply { session.start(false); session.cancel(); session.cancel() }
        Harness(log).apply { session.start(false); fake.ready(); session.stop(); shadowOf(Looper.getMainLooper()).idle(); fake.event(ServerEvent.Final("", "", false)) }
        assertEquals(listOf(TimingOutcome.CANCELLED, TimingOutcome.EMPTY), log.entries().map { it.outcome })
    }
    @Test fun `ring buffer keeps the newest fifty across reloads`() {
        val log = TimingLog(context); log.clear()
        (1..60).forEach { log.record(entry(it)) }
        val reloaded = TimingLog(context).entries()
        assertEquals(50, reloaded.size); assertEquals(11L, reloaded.first().time); assertEquals(60L, reloaded.last().time)
    }
    @Test fun `clear removes every entry`() {
        val log = TimingLog(context); log.record(entry(1)); log.clear()
        assertTrue(TimingLog(context).entries().isEmpty()); assertEquals("No sessions recorded", log.summary())
        assertTrue(DiagnosticsReport.text(context).contains("No sessions recorded"))
    }
    @Test fun `percentiles use nearest rank`() {
        assertNull(TimingSummary.percentile(emptyList(), 50))
        assertEquals(7L, TimingSummary.percentile(listOf(7), 90))
        val ten = (1L..10L).map { it * 10 }.shuffled()
        assertEquals(50L, TimingSummary.percentile(ten, 50)); assertEquals(90L, TimingSummary.percentile(ten, 90))
        assertEquals(20L, TimingSummary.percentile(listOf(10, 20, 30), 50)); assertEquals(30L, TimingSummary.percentile(listOf(10, 20, 30), 90))
    }
    @Test fun `summary shows p50 p90 per metric and counts per outcome`() {
        val items = (1..10).map { entry(it) } + entry(11, TimingOutcome.FAILED).copy(error = TimingError.BUSY, readyMs = null)
        val text = TimingSummary.of(items)
        assertTrue(text, text.contains("ready  p50 5 ms · p90 9 ms · n=10"))
        assertTrue(text, text.contains("audio  p50 6.0 s · p90 10.0 s · n=11"))
        assertTrue(text, text.contains("Outcomes: failed 1 · final 10"))
        assertTrue(text, text.contains("Errors: busy 1"))
        assertTrue(text, text.contains("connect  p50 – · p90 – · n=0"))
    }
    @Test fun `stored form holds numbers booleans and enum names only`() {
        val log = TimingLog(context); log.clear()
        log.record(SessionTiming(1, TimingOutcome.KEPT, TimingError.BUSY, TimingNetwork.CELLULAR, vpn = true, prewarmed = true, connectMs = 1, readyMs = 2, firstPartialMs = 3, stopFinalMs = 4, polishMs = 5, audioMs = 6))
        val stored = context.getSharedPreferences("session_timings", 0).getString("entries", null)!!
        val o = org.json.JSONArray(stored).getJSONObject(0)
        val enums = (TimingOutcome.entries.map { it.name } + TimingError.entries.map { it.name } + TimingNetwork.entries.map { it.name }).toSet()
        o.keys().forEach { key ->
            val value = o.get(key)
            assertTrue("$key=$value", value is Number || value is Boolean || (key in setOf("out", "err", "net") && value in enums))
        }
        assertEquals(setOf("t", "out", "err", "net", "vpn", "warm", "a", "c", "r", "p", "s", "o"), o.keys().asSequence().toSet())
        assertEquals(log.entries().single(), TimingLog.decode(stored).single())
    }
    @Test fun `corrupt or foreign stored entries are skipped`() {
        assertTrue(TimingLog.decode("not json").isEmpty())
        assertTrue(TimingLog.decode("""[{"t":1,"out":"SOMETHING","err":"NONE","net":"WIFI","vpn":false,"warm":false,"a":1}]""").isEmpty())
    }
    @Test fun `network kind prefers wifi then cellular and VPN is separate`() {
        assertEquals(TimingNetwork.WIFI, TimingNetworks.of(true, true, false, true))
        assertEquals(TimingNetwork.CELLULAR, TimingNetworks.of(false, true, false, true))
        assertEquals(TimingNetwork.ETHERNET, TimingNetworks.of(false, false, true, true))
        assertEquals(TimingNetwork.OTHER, TimingNetworks.of(false, false, false, true))
        assertEquals(TimingNetwork.NONE, TimingNetworks.of(false, false, false, false))
    }
}
