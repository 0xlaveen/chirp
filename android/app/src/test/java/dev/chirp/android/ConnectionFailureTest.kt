package dev.chirp.android

import java.io.IOException
import java.io.InterruptedIOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import javax.net.ssl.SSLHandshakeException
import javax.net.ssl.SSLPeerUnverifiedException
import org.junit.Assert.*
import org.junit.Test

class ConnectionFailureTest {
    private fun kind(t: Throwable?) = ConnectionFailure.classify(t)

    @Test fun `exception classes map to a reason without reading messages`() {
        assertEquals(ConnectionFailure.Kind.DNS, kind(UnknownHostException("synthetic.example")))
        assertEquals(ConnectionFailure.Kind.DNS, kind(UnknownHostException()))
        for (down in listOf(SocketTimeoutException("timeout"), InterruptedIOException("timeout"), ConnectException("refused"), NoRouteToHostException()))
            assertEquals(down.javaClass.simpleName, ConnectionFailure.Kind.DOWN, kind(down))
        assertEquals(ConnectionFailure.Kind.TLS, kind(SSLHandshakeException("synthetic")))
        assertEquals(ConnectionFailure.Kind.TLS, kind(SSLPeerUnverifiedException("synthetic")))
        for (other in listOf(null, IOException("Health unavailable"), SocketException("Connection reset"), IllegalStateException(), RuntimeException("timeout")))
            assertEquals(ConnectionFailure.Kind.OTHER, kind(other))
    }
    @Test fun `wrapped causes are found and cycles terminate`() {
        assertEquals(ConnectionFailure.Kind.DNS, kind(IOException("wrapped", IOException("again", UnknownHostException()))))
        val loop = RuntimeException("loop"); loop.initCause(RuntimeException("inner", loop))
        assertEquals(ConnectionFailure.Kind.OTHER, kind(loop))
    }
    @Test fun `only reachability failures count as offline`() {
        assertEquals(setOf(ConnectionFailure.Kind.DNS, ConnectionFailure.Kind.DOWN), ConnectionFailure.Kind.entries.filter { it.offline }.toSet())
    }
    @Test fun `statuses are hedged, distinct and round-trip`() {
        val statuses = ConnectionFailure.Kind.entries.map { it.status }
        assertEquals(statuses.size, statuses.toSet().size)
        assertEquals("Mac may be asleep, or Chirp isn't running", ConnectionFailure.Kind.DOWN.status)
        assertTrue(ConnectionFailure.Kind.DNS.status.startsWith("Can't find your Mac on the tailnet"))
        ConnectionFailure.Kind.entries.forEach { assertEquals(it, ConnectionFailure.kind(it.status)) }
        assertNull(ConnectionFailure.kind("Didn't catch that"))
        assertEquals(ConnectionFailure.Kind.DNS.status, ConnectionFailure.status(ConnectionFailure.Kind.DNS, timedOut = true))
        assertEquals(ConnectionFailure.Kind.DOWN.status, ConnectionFailure.status(null, timedOut = true))
        assertEquals(ConnectionFailure.Kind.DOWN.status, ConnectionFailure.status(ConnectionFailure.Kind.OTHER, timedOut = true))
        assertEquals(ConnectionFailure.Kind.OTHER.status, ConnectionFailure.status(ConnectionFailure.Kind.OTHER))
    }
    @Test fun `connection statuses offer Check Tailscale except TLS and keep the existing actions`() {
        assertEquals(DictationAction.NETWORK, DictationAction.forStatus(ConnectionFailure.Kind.DNS.status))
        assertEquals(DictationAction.NETWORK, DictationAction.forStatus(ConnectionFailure.Kind.DOWN.status))
        assertEquals(DictationAction.NETWORK, DictationAction.forStatus(ConnectionFailure.Kind.OTHER.status))
        assertNull(DictationAction.forStatus(ConnectionFailure.Kind.TLS.status))
        assertNull(DictationAction.forStatus(ConnectionFailure.OFFLINE))
        assertEquals(DictationAction.PAIR, DictationAction.forStatus("Pairing refused — pair again in Chirp setup"))
        assertEquals(DictationAction.TAILSCALE_ON, DictationAction.forStatus(DictationAction.TAILSCALE_OFF))
    }
    @Test fun `offline state lasts 30 seconds and clears on reachability`() {
        var now = 1000L
        val state = OfflineState({ now }, 30000)
        assertFalse(state.active()); assertEquals(0, state.remaining())
        state.failed(ConnectionFailure.Kind.DNS)
        assertTrue(state.active()); assertEquals(ConnectionFailure.Kind.DNS, state.kind)
        now += 29999; assertTrue(state.active()); assertEquals(1, state.remaining())
        now += 1; assertFalse(state.active()); assertEquals(0, state.remaining())
        state.failed(ConnectionFailure.Kind.DOWN); assertTrue(state.active())
        state.reachable(); assertFalse(state.active())
    }
    @Test fun `a non-reachability failure means the Mac answered and clears the mark`() {
        val state = OfflineState({ 0L }, 30000)
        state.failed(ConnectionFailure.Kind.DOWN); state.failed(ConnectionFailure.Kind.TLS)
        assertFalse(state.active())
        state.failed(ConnectionFailure.Kind.DOWN); state.failed(ConnectionFailure.Kind.OTHER)
        assertFalse(state.active())
    }
}
