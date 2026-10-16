package dev.chirp.android

import org.junit.Assert.*
import org.junit.Test

class PreReadyBufferTest {
    @Test fun `ready flushes frames in order before live frames and zeroes ownership`() {
        val sent = mutableListOf<List<Byte>>()
        val buffer = PreReadyBuffer({ sent.add(it.toList()); true }, maxBytes = 8)
        val first = byteArrayOf(1, 2); val second = byteArrayOf(3, 4); val live = byteArrayOf(5, 6)
        assertTrue(buffer.offer(first)); assertTrue(buffer.offer(second))
        assertTrue(sent.isEmpty()); assertEquals(4, buffer.bufferedBytes)
        assertTrue(buffer.ready()); assertTrue(buffer.offer(live))
        assertEquals(listOf(listOf<Byte>(1, 2), listOf<Byte>(3, 4), listOf<Byte>(5, 6)), sent)
        assertEquals(0, buffer.bufferedBytes)
        listOf(first, second, live).forEach { assertArrayEquals(ByteArray(2), it) }
        assertTrue(buffer.ready()); assertEquals(3, sent.size) // Ready cannot replay.
    }
    @Test fun `bound accepts exact limit then aborts without dropping or leaking frames`() {
        val buffer = PreReadyBuffer({ fail("Not ready"); true }, maxBytes = 4)
        val first = byteArrayOf(1, 2, 3, 4); val overflow = byteArrayOf(5)
        assertTrue(buffer.offer(first)); assertEquals(4, buffer.bufferedBytes)
        assertFalse(buffer.offer(overflow)); assertEquals(0, buffer.bufferedBytes)
        assertArrayEquals(ByteArray(4), first); assertArrayEquals(ByteArray(1), overflow)
        assertFalse(buffer.ready())
    }
    @Test fun `cancel clears queued frames and rejects late capture and ready`() {
        val buffer = PreReadyBuffer({ fail("Cancelled"); true })
        val queued = byteArrayOf(1, 2); val late = byteArrayOf(3, 4)
        buffer.offer(queued); buffer.cancel(); buffer.cancel()
        assertEquals(0, buffer.bufferedBytes); assertArrayEquals(ByteArray(2), queued)
        assertFalse(buffer.offer(late)); assertArrayEquals(ByteArray(2), late)
        assertFalse(buffer.ready())
    }
    @Test fun `failed flush clears remaining frames and prevents continued streaming`() {
        val sent = mutableListOf<Byte>()
        val buffer = PreReadyBuffer({ sent.add(it[0]); false })
        val first = byteArrayOf(1); val second = byteArrayOf(2)
        buffer.offer(first); buffer.offer(second)
        assertFalse(buffer.ready()); assertEquals(listOf<Byte>(1), sent)
        assertArrayEquals(ByteArray(1), first); assertArrayEquals(ByteArray(1), second)
        assertEquals(0, buffer.bufferedBytes)
    }
    @Test fun `default bound is exactly five seconds of pcm16 at 16 kHz`() {
        val buffer = PreReadyBuffer({ true })
        repeat(125) { assertTrue(buffer.offer(ByteArray(1280))) }
        assertEquals(160000, buffer.bufferedBytes)
        assertFalse(buffer.offer(ByteArray(1280))); assertEquals(0, buffer.bufferedBytes)
    }
}
