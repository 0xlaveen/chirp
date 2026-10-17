package dev.chirp.android

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 37])
class PcmCaptureTest {
    @Test fun `real PCM loop assembles short reads and releases source before completion`() {
        val order = mutableListOf<String>()
        var remaining = 640 * 6
        val input = object : PcmInput {
            override val finished get() = remaining == 0
            override fun start() { order += "start" }
            override fun read(samples: ShortArray, offset: Int, count: Int): Int {
                val size = minOf(remaining, count, 317)
                for (i in offset until offset + size) samples[i] = 1024
                remaining -= size
                return size
            }
            override fun stop() { order += "stop" }
            override fun close() { order += "release" }
        }
        val done = CountDownLatch(1)
        val error = AtomicReference<String?>()
        val frames = mutableListOf<ByteArray>()
        PcmCapture({ bytes -> frames += bytes.copyOf(); bytes.fill(0); true }, {}, {
            error.set(it); order += "done"; done.countDown()
        }, input).start()
        assertTrue(done.await(10, TimeUnit.SECONDS)); assertNull(error.get())
        assertEquals(6, frames.size); assertTrue(frames.all { it.size == 1280 && it[1] == 4.toByte() })
        assertTrue(order.indexOf("release") < order.indexOf("done"))
    }
    @Test fun `capture initialization failure still closes source and exposes no exception message`() {
        val done = CountDownLatch(1)
        val error = AtomicReference<String?>()
        var closed = false
        val input = object : PcmInput {
            override fun start() { throw SecurityException("synthetic private detail") }
            override fun read(samples: ShortArray, offset: Int, count: Int) = -1
            override fun stop() { throw IllegalStateException("synthetic private detail") }
            override fun close() { closed = true }
        }
        PcmCapture({ true }, {}, { error.set(it); done.countDown() }, input).start()
        assertTrue(done.await(10, TimeUnit.SECONDS)); assertTrue(closed)
        assertTrue(error.get().orEmpty().contains("Microphone unavailable"))
        assertFalse(error.get().orEmpty().contains("private"))
    }
}
