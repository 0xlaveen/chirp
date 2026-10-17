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
    @Test fun `polishing fences late partials and commits raw once on timeout or disconnect`() {
        for (disconnect in listOf(false, true)) {
            val h = Harness(); h.session.start(true); h.transport.ready(); h.session.stop(); h.advance()
            h.transport.event(ServerEvent.Correcting(2, "synthetic raw", "chat"))
            assertTrue(h.session.polishing); assertEquals("Polishing…", h.statuses.last())
            h.transport.partial(3, "late partial"); assertTrue(h.partials.isEmpty())
            if (disconnect) h.transport.failure() else h.advance(12000)
            assertEquals(ServerEvent.Final("synthetic raw", "synthetic raw", false, "unavailable"), h.finals.single())
            h.transport.final(); assertEquals(1, h.finals.size); assertEquals(1, h.ended)
        }
    }
    @Test fun `cancel during polishing discards raw and final success wins over timeout`() {
        val h = Harness(); h.session.start(true); h.transport.ready(); h.session.stop(); h.advance()
        h.transport.event(ServerEvent.Correcting(2, "synthetic", "chat")); h.session.cancel(); h.advance(12000)
        assertTrue(h.finals.isEmpty()); assertEquals(1, h.ended)
        val success = Harness(); success.session.start(true); success.transport.ready(); success.session.stop(); success.advance()
        success.transport.event(ServerEvent.Correcting(2, "synthetic", "chat")); success.transport.final(true); success.advance(12000)
        assertTrue(success.finals.single().corrected); assertEquals(1, success.ended)
    }

    @Test fun `fast cleanup has a readable transition and cancellation fences pending commit`() {
        val h = Harness(); h.session.start(true); h.transport.ready(); h.session.stop(); h.advance()
        h.transport.event(ServerEvent.Correcting(2, "synthetic", "chat")); h.transport.final(true)
        h.advance(449); assertTrue(h.finals.isEmpty())
        h.advance(1); assertEquals(1, h.finals.size)
        val cancelled = Harness(); cancelled.session.start(true); cancelled.transport.ready(); cancelled.session.stop(); cancelled.advance()
        cancelled.transport.event(ServerEvent.Correcting(2, "synthetic", "chat")); cancelled.transport.final(true)
        cancelled.session.cancel(); cancelled.advance(450)
        assertTrue(cancelled.finals.isEmpty()); assertEquals(1, cancelled.ended)
    }

    @Test fun `blank finals after stop discard polishing raw and terminate once`() {
        for (polishing in listOf(false, true)) {
            val h = Harness(); h.session.start(true); h.transport.ready(); h.session.stop(); h.advance()
            if (polishing) h.transport.event(ServerEvent.Correcting(2, "synthetic raw", "default"))
            h.transport.event(ServerEvent.Final(" ", "", false)); h.advance(450)
            assertTrue(h.finals.isEmpty()); assertEquals("Didn't catch that", h.statuses.last())
            h.session.cancel(); h.transport.failure(); h.transport.final(); h.advance(12000)
            assertEquals(1, h.ended); assertTrue(h.transport.closed)
        }
    }

}
