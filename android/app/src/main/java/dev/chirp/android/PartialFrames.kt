package dev.chirp.android

import android.os.Handler
import android.os.Looper

/** Coalesce bursts to one editor update per frame, always retaining the newest sequence. */
internal class PartialFrames(private val apply: (ServerEvent.Partial) -> Unit,
                             private val handler: Handler = Handler(Looper.getMainLooper())) {
    private var pending: ServerEvent.Partial? = null
    private var scheduled = false
    private val frame = Runnable {
        scheduled = false
        val latest = pending; pending = null
        if (latest != null) apply(latest)
    }
    fun offer(event: ServerEvent.Partial) {
        if (event.seq <= (pending?.seq ?: -1)) return
        pending = event
        if (!scheduled) { scheduled = true; handler.postDelayed(frame, 16) }
    }
    fun clear() { handler.removeCallbacks(frame); pending = null; scheduled = false }
}
