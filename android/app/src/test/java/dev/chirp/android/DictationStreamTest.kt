package dev.chirp.android

import android.os.Looper
import java.time.Duration
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 37])
class DictationStreamTest {
    private class Harness {
        val order = mutableListOf<String>()
        lateinit var transport: ChirpImeServiceTest.FakeTransport
        lateinit var capture: ChirpImeServiceTest.FakeCapture
        val statuses = mutableListOf<String>()
        val partials = mutableListOf<ServerEvent.Partial>()
        val finals = mutableListOf<ServerEvent.Final>()
        var ended = 0
        var retention = false
        val session = DictationStream(
            transportFactory = { event, failure -> ChirpImeServiceTest.FakeTransport(event, failure, order).also { transport = it } },
            captureFactory = { frame, _, done -> ChirpImeServiceTest.FakeCapture(frame, done, order).also { capture = it } },
            changed = { status, partial -> statuses += status; if (partial != null) partials += partial },
            level = {}, retention = { retention = it }, final = { finals += it }, ended = { ended++ },
        )
        fun advance(ms: Long = 0) { shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(ms)) }
    }
    @Test fun `buffered hold stops only after release and Ready then final shuts down transport`() {
        val h = Harness(); h.session.start(false)
        assertEquals(listOf("capture.start", "stream.start"), h.order)
        val frame = byteArrayOf(1, 2); h.capture.frame(frame)
        h.capture.deferRelease = true
        h.session.stop(); h.advance()
        assertEquals(0, h.transport.stops)
        h.capture.finish(); h.advance()
        assertEquals(0, h.transport.stops)
        h.transport.ready()
        assertEquals(1, h.transport.stops)
        assertArrayEquals(byteArrayOf(0, 0), frame)
        assertArrayEquals(byteArrayOf(1, 2), h.transport.frames.single())
        h.transport.final()
        assertTrue(h.transport.closed); assertTrue(h.transport.immediate)
        assertEquals(1, h.finals.size); assertEquals(1, h.ended)
        h.transport.final(); assertEquals(1, h.finals.size)
    }
    @Test fun `partials stay ordered and cancellation fences late callbacks and releases microphone`() {
        val h = Harness(); h.session.start(false); h.transport.ready()
        h.transport.partial(2, "synthetic"); h.transport.partial(1, "stale")
        assertEquals(listOf("synthetic"), h.partials.map { it.text })
        h.session.cancel(); h.advance()
        assertTrue(h.capture.released); assertTrue(h.transport.cancelled)
        h.transport.partial(3, "late"); h.transport.final(); h.advance(18000)
        assertEquals(1, h.ended); assertTrue(h.finals.isEmpty())
    }
    @Test fun `startup and finalization timeouts release all resources`() {
        val startup = Harness(); startup.session.start(false); startup.advance(18000)
        assertTrue(startup.capture.released); assertTrue(startup.transport.closed)
        assertTrue(startup.statuses.last().contains("Tailscale")); assertEquals(1, startup.ended)
        val finish = Harness(); finish.session.start(false); finish.transport.ready(); finish.session.stop(); finish.advance()
        assertTrue(finish.capture.released); finish.advance(60000)
        assertEquals(1, finish.ended); assertTrue(finish.transport.closed)
    }
    @Test fun `debug retention changes before partials and no final is accepted before stop`() {
        val h = Harness(); h.session.start(false)
        h.transport.event(ServerEvent.Ready(true)); assertTrue(h.retention)
        h.transport.final(); assertTrue(h.finals.isEmpty()); assertTrue(h.capture.released)
        assertEquals("Unexpected server response", h.statuses.last())
    }
}
