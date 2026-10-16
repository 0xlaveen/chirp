package dev.chirp.android

import java.io.IOException
import java.util.concurrent.TimeUnit
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString.Companion.toByteString

/** No logging interceptors, disk cache, redirects (bearer credential), pings or idle socket. */
object ChirpNetwork {
    fun client(): OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(6, TimeUnit.SECONDS).readTimeout(12, TimeUnit.SECONDS)
        .callTimeout(12, TimeUnit.SECONDS).webSocketCloseTimeout(1, TimeUnit.SECONDS).followRedirects(false).followSslRedirects(false)
        .retryOnConnectionFailure(false).connectionPool(okhttp3.ConnectionPool(0, 1, TimeUnit.SECONDS)).build()
    fun healthCall(client: OkHttpClient, pairing: Pairing): okhttp3.Call {
        val request = Request.Builder().url(pairing.endpoint("v1/health"))
            .header("Authorization", "Bearer ${pairing.token}").build()
        return client.newCall(request)
    }
    fun health(client: OkHttpClient, pairing: Pairing): Health = health(healthCall(client, pairing))
    fun health(call: okhttp3.Call): Health {
        call.execute().use { response ->
            if (!response.isSuccessful) throw IOException("Health unavailable")
            val body = response.body
            // Bound memory and never include response/request details in exceptions shown to users.
            val source = body.source()
            source.request(65537)
            if (source.buffer.size > 65536) throw IOException("Health too large")
            return Protocol.health(source.readUtf8())
        }
    }
    fun dispose(client: OkHttpClient) {
        client.dispatcher.cancelAll()
        client.connectionPool.evictAll()
        client.dispatcher.executorService.shutdown()
    }
}

class StreamTransport(
    private val client: OkHttpClient,
    private val pairing: Pairing,
    private val correction: Boolean,
    private val dispatch: (() -> Unit) -> Unit,
    private val event: (ServerEvent) -> Unit,
    private val failure: () -> Unit,
) {
    @Volatile private var socket: WebSocket? = null
    @Volatile private var closed = false
    @Volatile private var receivedReady = false
    private var retried = false

    fun connect() {
        if (closed) return
        val request = Request.Builder().url(pairing.endpoint("v1/stream"))
            .header("Authorization", "Bearer ${pairing.token}").build()
        socket = client.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                if (closed) { webSocket.cancel(); return }
                webSocket.send(Protocol.start(correction))
            }
            override fun onMessage(webSocket: WebSocket, text: String) {
                if (closed) return
                val decoded = try { Protocol.decode(text) } catch (_: Exception) {
                    dispatch { if (!closed) { close(true); failure() } }; return
                }
                if (decoded is ServerEvent.Ready) receivedReady = true
                dispatch { if (!closed) event(decoded) }
            }
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                dispatch { failed() }
            }
            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                webSocket.close(code, null)
                dispatch { failed() }
            }
        })
    }
    private fun failed() {
        if (closed) return
        // Before ready nothing has been recorded; retry once without replay or retaining audio.
        if (!retried && !receivedReady) { retried = true; socket?.cancel(); connect() }
        else { close(true); failure() }
    }
    fun audio(bytes: ByteArray): Boolean {
        if (closed) return false
        val ws = socket ?: return false
        // At most ~2 seconds queued: a broken link must not accumulate an utterance in RAM.
        if (ws.queueSize() > 64000) return false
        return ws.send(bytes.toByteString())
    }
    fun stop(): Boolean = !closed && socket?.send(Protocol.STOP) == true
    fun close(cancel: Boolean = false) {
        if (closed) return
        closed = true
        if (cancel) socket?.send(Protocol.CANCEL)
        socket?.close(1000, null)
        socket = null
        client.connectionPool.evictAll()
    }
}
