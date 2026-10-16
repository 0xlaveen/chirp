package dev.chirp.android

import java.io.IOException
import java.util.concurrent.TimeUnit
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString.Companion.toByteString

/** No logging interceptors, disk cache, redirects (bearer credential), pings or disk persistence. Idle resources are scoped to IME visibility. */
object ChirpNetwork {
    fun client(): OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(6, TimeUnit.SECONDS).readTimeout(12, TimeUnit.SECONDS)
        .callTimeout(12, TimeUnit.SECONDS).webSocketCloseTimeout(1, TimeUnit.SECONDS).followRedirects(false).followSslRedirects(false)
        .retryOnConnectionFailure(false).connectionPool(okhttp3.ConnectionPool(2, 30, TimeUnit.SECONDS)).build()
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

/** Main-thread control; audio() is also called by the capture thread. */
class StreamTransport(
    private val client: OkHttpClient,
    private val pairing: Pairing,
    private val dispatch: (() -> Unit) -> Unit,
    private val event: (ServerEvent) -> Unit,
    private val failure: () -> Unit,
    private val opened: () -> Unit = {},
) {
    @Volatile private var socket: WebSocket? = null
    @Volatile private var ready = false
    @Volatile private var active = false
    private var closed = false
    private var connected = false
    private var startSent = false
    private var correction = false
    private var retried = false
    private var attempt = 0

    /** Upgrade with bearer authentication only. Do not allocate an engine utterance. */
    fun connect() {
        if (closed || socket != null) return
        val id = ++attempt
        val request = Request.Builder().url(pairing.endpoint("v1/stream"))
            .header("Authorization", "Bearer ${pairing.token}").build()
        socket = client.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                dispatch {
                    if (closed || attempt != id) { webSocket.cancel(); return@dispatch }
                    connected = true
                    if (active) sendStart()
                    opened()
                }
            }
            override fun onMessage(webSocket: WebSocket, text: String) {
                dispatch {
                    if (closed || attempt != id) return@dispatch
                    val decoded = try { Protocol.decode(text) } catch (_: Exception) {
                        close(true); failure(); return@dispatch
                    }
                    when (decoded) {
                        is ServerEvent.Ready -> {
                            if (!active || !startSent || ready) return@dispatch
                            ready = true
                        }
                        is ServerEvent.Partial, is ServerEvent.Final -> if (!active || !ready) return@dispatch
                        is ServerEvent.Failure -> if (!active) { close(); failure(); return@dispatch }
                        ServerEvent.Unknown -> return@dispatch
                    }
                    if (decoded is ServerEvent.Final || decoded is ServerEvent.Failure) {
                        active = false; ready = false; startSent = false
                    }
                    event(decoded)
                }
            }
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                dispatch { if (!closed && attempt == id) failed() }
            }
            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                webSocket.close(code, null)
                dispatch { if (!closed && attempt == id) failed() }
            }
        })
    }
    fun start(correction: Boolean): Boolean {
        if (closed || active) return false
        active = true; ready = false; startSent = false; retried = false
        this.correction = correction
        if (connected) sendStart() else connect()
        return !closed
    }
    private fun sendStart() {
        startSent = socket?.send(Protocol.start(correction)) == true
        if (!startSent) failed()
    }
    private fun failed() {
        if (closed) return
        val wasReady = ready
        socket?.cancel(); socket = null; connected = false; startSent = false; ready = false
        // No audio has left the pre-ready buffer: one reconnect can safely retry start.
        if (!retried && !wasReady) { retried = true; connect() }
        else { close(); failure() }
    }
    fun audio(bytes: ByteArray): Boolean {
        if (!active || !ready) return false
        val ws = socket ?: return false
        if (ws.queueSize() + bytes.size > 160000) return false // Bound network backpressure as well.
        return ws.send(bytes.toByteString())
    }
    fun stop(): Boolean = active && ready && socket?.send(Protocol.STOP) == true

    /** Cancel retires the socket: v1 has no cancel acknowledgement or session IDs on finals. */
    fun close(cancel: Boolean = false, immediate: Boolean = false) {
        if (closed) return
        closed = true; ++attempt; active = false; ready = false; connected = false
        val ws = socket
        socket = null
        if (cancel) ws?.send(Protocol.CANCEL)
        if (immediate) ws?.cancel() else ws?.close(1000, null)
    }
}
