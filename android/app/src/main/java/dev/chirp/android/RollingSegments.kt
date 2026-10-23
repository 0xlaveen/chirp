package dev.chirp.android

/** The Mac's Live Notes cut: at a pause after 12 s (0.3 s of quiet after 30 s), always at 45 s, so each segment cleans up fast. */
internal fun notesSegmenter() = DictationSegmenter(minSegment = 12.0, pauseCut = 0.6, relaxedAfter = 30.0, relaxedPause = 0.3, maxSegment = 45.0)

/**
 * Routes Notes capture frames (16 kHz PCM16) to the current segment and runs the segmenter, on the capture thread. The swap
 * is atomic under one lock, so every frame lands on exactly one target, in order. Unlike the keyboard's router it
 * swaps only to a socket that is already Ready: the caller opens the next one, waits, swaps, then stops the old one.
 */
internal class FrameRouter<T : Any>(private val segmenter: DictationSegmenter = notesSegmenter(), private val send: (T, ByteArray) -> Unit) {
    private val lock = Any()
    private var target: T? = null
    private var cutRequested = false
    private var bytes = 0L

    /** Sends the frame on; true when the segmenter wants a cut (asked once until the next [swap]). */
    fun route(frame: ByteArray, rms: Float): Boolean = synchronized(lock) {
        val current = target ?: return false
        send(current, frame)
        bytes += frame.size
        if (cutRequested || !segmenter.feed(rms, frame.size / 2 / SAMPLE_RATE)) return false
        cutRequested = true
        true
    }

    /** Points capture at [next] (null stops routing). Returns the old target and the audio offset of the switch, seconds. */
    fun swap(next: T?): Pair<T?, Double> = synchronized(lock) {
        val old = target
        target = next; segmenter.reset(); cutRequested = false
        old to bytes / 2 / SAMPLE_RATE
    }

    /** Audio routed since the last [resetTime], seconds. */
    val seconds: Double get() = synchronized(lock) { bytes / 2 / SAMPLE_RATE }

    /** Restarts the clock, at [seconds] for a recovered session. */
    fun resetTime(seconds: Double = 0.0) = synchronized(lock) { bytes = (seconds * SAMPLE_RATE).toLong() * 2 }

    private companion object { const val SAMPLE_RATE = 16000.0 }
}
