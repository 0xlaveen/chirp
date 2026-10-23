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
    private val correcting: (ServerEvent.Correcting) -> Unit = {},
    /** A failure after partials hands over what was heard (text, reason) instead of discarding it. */
    private val kept: ((String, String) -> Unit)? = null,
) {
    private var transport: ImeTransport? = null
    private var capture: Capture? = null
    private var buffer: PreReadyBuffer? = null
    private var live = false
    private var ready = false
    private var released = false
    private var stopSent = false
    private var sequence = -1L
    private var raw: String? = null
    private var heard: String? = null
    private var polishingAt = 0L
    private var pendingFinal: Runnable? = null
    var polishing = false
        private set
    var stopping = false
        private set
    private val timeout = Runnable { fail(if (stopSent) "Mac took too long to finish — try again" else "Mac unreachable — is Tailscale on?") }

    fun start(correction: Boolean, profile: String = "default", instructions: String = "", prompt: String? = null) {
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
        if (transport?.start(correction, profile, instructions, prompt) != true) fail("Mac unreachable — is Tailscale on?")
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
            is ServerEvent.Partial -> if (ready && !polishing && event.seq > sequence) {
                sequence = event.seq; heard = event.text; changed(if (stopping) "Finishing…" else "Listening…", event)
            }
            is ServerEvent.Correcting -> if (stopSent && !polishing && event.seq > sequence && event.raw.isNotEmpty()) {
                sequence = event.seq; raw = event.raw; polishing = true; polishingAt = android.os.SystemClock.uptimeMillis()
                correcting(event); changed("Polishing…", null); deadline(12000)
            }
            is ServerEvent.Final -> {
                if (!stopSent) { fail("Unexpected server response"); return }
                if (pendingFinal != null) return
                handler.removeCallbacks(timeout)
                val finish = Runnable {
                    if (live) {
                        close(false)
                        try {
                            if (event.text.isBlank()) changed("Didn't catch that", null) else final(event)
                        } finally { ended() }
                    }
                }
                val remaining = if (polishing) (450 - (android.os.SystemClock.uptimeMillis() - polishingAt)).coerceAtLeast(0) else 0
                if (remaining > 0) { pendingFinal = finish; handler.postDelayed(finish, remaining) } else finish.run()
            }
            is ServerEvent.Failure -> fail(when (event.code) {
                "auth" -> "Pairing refused — pair again in Chirp setup"
                "bad_audio" -> "Didn't catch that"
                "engine" -> "Speech engine hiccup"
                "busy" -> "Mac is busy — try again"
                "too_long" -> "Dictation limit is 120 seconds"
                "bad_request" -> "Clean-up prompt too long — shorten it in Chirp settings"
                else -> "Mac speech engine unavailable — try again"
            })
            ServerEvent.Unknown -> Unit
        }
    }
    private fun deadline(ms: Long) { handler.removeCallbacks(timeout); handler.postDelayed(timeout, ms) }
    fun fail(message: String) {
        if (!live || pendingFinal != null) return
        val original = raw; val partial = heard?.takeIf { it.isNotBlank() }
        close(true)
        try {
            if (original != null) final(ServerEvent.Final(original, original, false, "unavailable"))
            else if (partial != null && kept != null) kept(partial, message)
            else changed(message, null)
        } finally { ended() }
    }
    fun cancel() { if (live) { close(true); ended() } }
    private fun close(cancel: Boolean) {
        live = false; raw = null; heard = null
        pendingFinal?.let(handler::removeCallbacks); pendingFinal = null
        handler.removeCallbacks(timeout)
        capture?.stop(); capture = null
        buffer?.cancel(); buffer = null
        transport?.close(cancel = cancel, immediate = !cancel); transport = null
    }
}
