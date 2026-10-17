package dev.chirp.android

import android.os.Looper
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import okhttp3.OkHttpClient
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 37])
class NetworkHousekeepingTest {
    @Test fun `TLS pool teardown always runs off main and remains safe after disposal`() {
        assertEquals(Looper.getMainLooper(), Looper.myLooper())
        val client = OkHttpClient()
        val completed = CountDownLatch(3)
        val onMain = AtomicBoolean(false)
        val cleanup = NetworkHousekeeping(evict = {
            if (Looper.myLooper() == Looper.getMainLooper()) onMain.set(true)
            it.connectionPool.evictAll()
            completed.countDown()
        })
        cleanup.release(client)
        cleanup.release(client, cancel = true, dispose = true)
        cleanup.release(client, cancel = true, dispose = true)
        assertTrue(completed.await(10, TimeUnit.SECONDS))
        assertFalse(onMain.get())
    }
    @Test fun `queued hide cleanup cannot cancel a newly shown session`() {
        val server = okhttp3.mockwebserver.MockWebServer()
        server.enqueue(okhttp3.mockwebserver.MockResponse().setSocketPolicy(okhttp3.mockwebserver.SocketPolicy.NO_RESPONSE))
        server.start()
        val client = OkHttpClient.Builder().dispatcher(okhttp3.Dispatcher().apply { maxRequests = 1 }).build()
        val tasks = mutableListOf<Runnable>()
        val cleanup = NetworkHousekeeping(java.util.concurrent.Executor { tasks += it }, evict = {})
        val callback = object : okhttp3.Callback {
            override fun onFailure(call: okhttp3.Call, error: java.io.IOException) = Unit
            override fun onResponse(call: okhttp3.Call, response: okhttp3.Response) { response.close() }
        }
        try {
            val old = client.newCall(okhttp3.Request.Builder().url(server.url("/")).build())
            old.enqueue(callback)
            cleanup.release(client, cancel = true)
            val fresh = client.newCall(okhttp3.Request.Builder().url(server.url("/")).build())
            fresh.enqueue(callback)
            tasks.single().run()
            assertTrue(old.isCanceled()); assertFalse(fresh.isCanceled())
        } finally {
            client.dispatcher.cancelAll(); client.connectionPool.evictAll()
            client.dispatcher.executorService.shutdown(); server.shutdown()
        }
    }

}
