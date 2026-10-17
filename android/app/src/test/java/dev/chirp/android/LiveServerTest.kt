package dev.chirp.android

import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.After
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test

/**
 * Drives the IME's real transport (ChirpNetwork + StreamTransport + Protocol) against a running
 * chirp-server, with a WAV standing in for AudioRecord. No device, mic or permission involved.
 * Opt-in: ./gradlew testDebugUnitTest --tests '*LiveServerTest*' -Pchirp.live.url=http://127.0.0.1:7899/
 *   -Pchirp.live.tokenFile=… -Pchirp.live.wav=… -Pchirp.live.expect=word
 */
class LiveServerTest {
    private val url = System.getProperty("chirp.live.url")
    private val main = Executors.newSingleThreadExecutor()
    private val client = ChirpNetwork.client()
    private val events = LinkedBlockingQueue<Any>()

    @Before fun requireServer() = assumeTrue("set -Pchirp.live.url to run", url != null)

    @After fun tearDown() { ChirpNetwork.dispose(client); main.shutdownNow() }

    // Loopback only: Pairing.from enforces HTTPS for real pairings, so build the base URL directly.
    private fun pairing(token: String) = Pairing(url!!.toHttpUrl(), token)
    private fun token() = File(checkNotNull(System.getProperty("chirp.live.tokenFile"))).readText().trim()

    private fun transport(pairing: Pairing) = StreamTransport(client, pairing,
        dispatch = { if (!main.isShutdown) runCatching { main.execute(it) } }, event = { events.put(it) }, failure = { events.put("failure") },
        opened = { events.put("opened") })

    private fun onMain(block: () -> Unit) = main.submit(block).get(5, TimeUnit.SECONDS)

    private fun next(timeoutMs: Long = 30_000): Any = events.poll(timeoutMs, TimeUnit.MILLISECONDS) ?: "timeout"

    /** PCM16LE mono 16 kHz samples from the WAV's data chunk, in 40 ms (1280-byte) frames like PcmCapture. */
    private fun frames(): List<ByteArray> {
        val bytes = File(checkNotNull(System.getProperty("chirp.live.wav"))).readBytes()
        val buf = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        var at = 12
        while (at + 8 <= bytes.size) {
            val id = String(bytes, at, 4)
            val size = buf.getInt(at + 4)
            if (id == "data") return bytes.copyOfRange(at + 8, minOf(bytes.size, at + 8 + size)).toList().chunked(1280).map { it.toByteArray() }
            at += 8 + size + (size and 1)
        }
        error("no data chunk")
    }

    /** One utterance on an already-open transport; returns (final, stop→final ms, partial count). */
    private fun utterance(t: StreamTransport, audio: List<ByteArray>): Triple<ServerEvent.Final, Long, Int> {
        onMain { assertTrue(t.start(false)) }
        var event = next()
        while (event == "opened") event = next()
        assertTrue("expected ready, got $event", event is ServerEvent.Ready)
        val started = System.nanoTime()
        audio.forEachIndexed { i, frame ->
            assertTrue(t.audio(frame))
            val due = started + (i + 1) * 40_000_000L
            val wait = due - System.nanoTime()
            if (wait > 0) Thread.sleep(wait / 1_000_000, (wait % 1_000_000).toInt())
        }
        val stopAt = System.nanoTime()
        onMain { assertTrue(t.stop()) }
        var partials = 0
        while (true) {
            when (val e = next()) {
                is ServerEvent.Partial -> partials++
                is ServerEvent.Final -> return Triple(e, (System.nanoTime() - stopAt) / 1_000_000, partials)
                else -> fail("unexpected $e")
            }
        }
    }

    @Test fun healthStreamingAndSocketReuse() {
        val pairing = pairing(token())
        val health = ChirpNetwork.health(client, pairing)
        assertTrue(health.ready)
        val t = transport(pairing)
        onMain { t.connect() } // pre-warm, as when the IME view becomes visible
        assertEquals("opened", next())
        val audio = frames()
        val expect = System.getProperty("chirp.live.expect")?.lowercase()
        repeat(2) { n ->
            val (final, latency, partials) = utterance(t, audio)
            println("live utterance ${n + 1}: partials=$partials stop→final=${latency}ms final=\"${final.text}\"")
            assertTrue(partials > 0)
            if (expect != null) assertTrue(final.text.lowercase().contains(expect))
        }
        onMain { t.close() }
    }

    @Test fun wrongTokenIsRefusedBeforeAudio() {
        val pairing = pairing("not-the-token")
        assertThrows(Exception::class.java) { ChirpNetwork.health(client, pairing) }
        val t = transport(pairing)
        onMain { t.start(false) }
        val outcome = generateSequence { next(10_000) }.first { it != "opened" }
        assertTrue("expected refusal, got $outcome",
            outcome == "failure" || (outcome is ServerEvent.Failure && outcome.code == "auth"))
        assertFalse(t.audio(ByteArray(1280)))
        onMain { t.close() }
    }
}
