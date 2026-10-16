package dev.chirp.android

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import okhttp3.OkHttpClient
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import okio.ByteString
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class NetworkTest {
    private fun withServer(test: (MockWebServer, OkHttpClient, Pairing) -> Unit) {
        val certificate = HeldCertificate.Builder().commonName("localhost").addSubjectAlternativeName("localhost").build()
        val serverTls = HandshakeCertificates.Builder().heldCertificate(certificate).build()
        val clientTls = HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
        MockWebServer().use { server ->
            server.useHttps(serverTls.sslSocketFactory(), false)
            server.start()
            val client = ChirpNetwork.client().newBuilder().sslSocketFactory(clientTls.sslSocketFactory(), clientTls.trustManager).build()
            try { test(server, client, Pairing.from(server.url("/chirp/").toString(), "synthetic-credential")) }
            finally { ChirpNetwork.dispose(client) }
        }
    }
    @Test fun `authenticated mounted health request preserves privacy flags and rejects redirects`() = withServer { server, client, pairing ->
        server.enqueue(MockResponse().setBody("""{"ok":true,"ready":true,"debug_retention":true,"correction":"off"}"""))
        assertTrue(ChirpNetwork.health(client, pairing).debugRetention)
        val request = server.takeRequest(5, TimeUnit.SECONDS)!!
        assertEquals("/chirp/v1/health", request.path)
        assertEquals("Bearer synthetic-credential", request.getHeader("Authorization"))
        assertFalse(request.path!!.contains("credential"))
        server.enqueue(MockResponse().setResponseCode(302).addHeader("Location", "https://example.test/"))
        assertThrows(Exception::class.java) { ChirpNetwork.health(client, pairing) }
    }
    @Test fun `stream orders start pcm stop and dispatches live partial then final`() = withServer { server, client, pairing ->
        val stopped = CountDownLatch(1)
        val final = CountDownLatch(1)
        val ready = CountDownLatch(1)
        val audio = CountDownLatch(1)
        val received = mutableListOf<String>()
        server.enqueue(MockResponse().withWebSocketUpgrade(object : WebSocketListener() {
            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) { webSocket.close(code, null) }
            override fun onMessage(webSocket: WebSocket, text: String) {
                when (JSONObject(text).getString("type")) {
                    "start" -> {
                        assertFalse(JSONObject(text).getBoolean("correction"))
                        webSocket.send("""{"type":"ready","debug_retention":false}""")
                    }
                    "stop" -> {
                        stopped.countDown()
                        webSocket.send("""{"type":"partial","seq":1,"text":"synthetic","stable":""}""")
                        webSocket.send("""{"type":"final","text":"Synthetic.","raw":"synthetic","corrected":true}""")
                    }
                }
            }
            override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                assertEquals(1280, bytes.size); audio.countDown()
            }
        }))
        val stream = StreamTransport(client, pairing, false, { it() }, { event ->
            when (event) {
                is ServerEvent.Ready -> ready.countDown()
                is ServerEvent.Partial -> received.add("partial")
                is ServerEvent.Final -> { received.add("final"); final.countDown() }
                else -> Unit
            }
        }, { fail("Unexpected stream failure") })
        try {
            stream.connect(); assertTrue(ready.await(5, TimeUnit.SECONDS))
            assertTrue(stream.audio(ByteArray(1280))); assertTrue(audio.await(5, TimeUnit.SECONDS))
            assertTrue(stream.stop()); assertTrue(stopped.await(5, TimeUnit.SECONDS))
            assertTrue(final.await(5, TimeUnit.SECONDS)); assertEquals(listOf("partial", "final"), received)
            val request = server.takeRequest(5, TimeUnit.SECONDS)!!
            assertEquals("/chirp/v1/stream", request.path)
            assertEquals("Bearer synthetic-credential", request.getHeader("Authorization"))
        } finally { stream.close() }
        assertFalse(stream.audio(ByteArray(1280))); assertFalse(stream.stop())
    }
    @Test fun `failed upgrade retries exactly once and returns actionable failure`() = withServer { server, client, pairing ->
        server.enqueue(MockResponse().setResponseCode(503)); server.enqueue(MockResponse().setResponseCode(503))
        val failure = CountDownLatch(1)
        val stream = StreamTransport(client, pairing, false, { it() }, {}, { failure.countDown() })
        stream.connect()
        assertTrue(failure.await(5, TimeUnit.SECONDS))
        assertEquals(2, server.requestCount)
        stream.close(true)
    }
    @Test fun `cancel sends discard and suppresses later results`() = withServer { server, client, pairing ->
        val ready = CountDownLatch(1); val cancelled = CountDownLatch(1)
        server.enqueue(MockResponse().withWebSocketUpgrade(object : WebSocketListener() {
            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) { webSocket.close(code, null) }
            override fun onMessage(webSocket: WebSocket, text: String) {
                when (JSONObject(text).getString("type")) {
                    "start" -> webSocket.send("""{"type":"ready","debug_retention":false}""")
                    "cancel" -> { cancelled.countDown(); webSocket.send("""{"type":"final","text":"late","raw":"late","corrected":false}""") }
                }
            }
        }))
        val stream = StreamTransport(client, pairing, false, { it() }, {
            if (it is ServerEvent.Ready) ready.countDown() else fail("Event after cancellation")
        }, { fail("Failure after cancellation") })
        stream.connect(); assertTrue(ready.await(5, TimeUnit.SECONDS)); stream.close(true)
        assertTrue(cancelled.await(5, TimeUnit.SECONDS))
    }
}
