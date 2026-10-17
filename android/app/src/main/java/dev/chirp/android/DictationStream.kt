package dev.chirp.android

import android.os.Handler
import android.os.Looper

/** One utterance, no idle connection. Capture completion precedes STOP, including pre-ready stops. */
internal class DictationStream(
    private val transportFactory: ((ServerEvent) -> Unit, () -> Unit) -> ImeTransport,
    private val captureFactory: ((ByteArray) -> Boolean, (Double) -> Unit, (String?) -> Unit) -> Capture,
    private val changed: (String, ServerEvent.Partial?) -> Unit,
    private val level: (Double) -> Unit,
    private val retention: (Boolean) -> Unit,
    private val final: (ServerEvent.Final) -> Unit,
    private val ended: () -> Unit,
    private val handler: Handler = Handler(Looper.getMainLooper()),
) {
    private var transport: ImeTransport? = null
    private var capture: Capture? = null
    private var buffer: PreReadyBuffer? = null
    private var live = false
    private var ready = false
    private var released = false
    private var stopSent = false
    private var sequence = -1L
    var stopping = false
        private set
    private val timeout = Runnable { fail(if (stopSent) "Mac took too long to finish — try again" else "Mac unreachable — is Tailscale on?") }

    fun start(correction: Boolean) {
        check(!live && transport == null)
        live = true
        changed("Connecting to Mac…", null)
        val pending = PreReadyBuffer(send = { transport?.audio(it) == true })
        buffer = pending
        transport = transportFactory({ if (live) event(it) }, { if (live) fail("Mac unreachable — is Tailscale on?") })
        capture = captureFactory(pending::offer, { value -> handler.post { if (live && !stopping) level(value) } }, { error ->
            handler.post {
                if (live) {
                    capture = null; released = true
                    if (error != null) fail(error) else {
                        stopping = true; changed("Finishing…", null); sendStop()
                    }
                }
            }
        })
        deadline(18000)
        capture?.start()
        if (transport?.start(correction) != true) fail("Mac unreachable — is Tailscale on?")
    }
    fun stop() {
        if (!live || stopping) return
        stopping = true
        changed("Finishing…", null)
        capture?.stop()
    }
    private fun sendStop() {
        if (!live || !ready || !released || stopSent) return
        if (transport?.stop() != true) { fail("Mac unreachable — is Tailscale on?"); return }
        stopSent = true; deadline(60000)
    }
    private fun event(event: ServerEvent) {
        when (event) {
            is ServerEvent.Ready -> {
                if (ready) { fail("Unexpected server response"); return }
                ready = true; retention(event.debugRetention)
                if (buffer?.ready() != true) { fail("Mac connection is too slow — try again"); return }
                handler.removeCallbacks(timeout)
                if (!stopping) changed("Listening…", null)
                if (released) sendStop() else deadline(125000)
            }
            is ServerEvent.Partial -> if (ready && event.seq > sequence) {
                sequence = event.seq; changed(if (stopping) "Finishing…" else "Listening…", event)
            }
            is ServerEvent.Final -> {
                if (!stopSent) { fail("Unexpected server response"); return }
                close(false)
                try { final(event) } finally { ended() }
            }
            is ServerEvent.Failure -> fail(when (event.code) {
                "auth" -> "Pairing refused — pair again in Chirp setup"
                "busy" -> "Mac is busy — try again"
                "too_long" -> "Dictation limit is 120 seconds"
                else -> "Mac speech engine unavailable — try again"
            })
            ServerEvent.Unknown -> Unit
        }
    }
    private fun deadline(ms: Long) { handler.removeCallbacks(timeout); handler.postDelayed(timeout, ms) }
    fun fail(message: String) { if (live) { close(true); changed(message, null); ended() } }
    fun cancel() { if (live) { close(true); ended() } }
    private fun close(cancel: Boolean) {
        live = false
        handler.removeCallbacks(timeout)
        capture?.stop(); capture = null
        buffer?.cancel(); buffer = null
        transport?.close(cancel = cancel, immediate = !cancel); transport = null
    }
}
