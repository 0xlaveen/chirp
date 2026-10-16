package dev.chirp.android

/** Owns each frame until sent. All operations serialize capture with ready/cancel. */
class PreReadyBuffer(
    private val send: (ByteArray) -> Boolean,
    private val maxBytes: Int = 16000 * 2 * 5,
) {
    private val frames = ArrayDeque<ByteArray>()
    private var streaming = false
    private var cancelled = false
    var bufferedBytes: Int = 0
        private set

    init { require(maxBytes > 0) }

    /** Transfers ownership; callers must not reuse bytes. A false result aborts capture. */
    @Synchronized fun offer(bytes: ByteArray): Boolean {
        if (cancelled) { bytes.fill(0); return false }
        if (streaming) return transmit(bytes)
        if (bytes.size > maxBytes - bufferedBytes) {
            bytes.fill(0); cancel(); return false
        }
        frames.addLast(bytes)
        bufferedBytes += bytes.size
        return true
    }
    @Synchronized fun ready(): Boolean {
        if (cancelled) return false
        while (frames.isNotEmpty()) {
            val frame = frames.removeFirst()
            bufferedBytes -= frame.size
            if (!transmit(frame)) return false
        }
        streaming = true
        return true
    }
    private fun transmit(bytes: ByteArray): Boolean {
        return try {
            if (send(bytes)) true else { cancel(); false }
        } catch (_: Exception) {
            cancel(); false
        } finally { bytes.fill(0) }
    }
    @Synchronized fun cancel() {
        cancelled = true
        frames.forEach { it.fill(0) }
        frames.clear()
        bufferedBytes = 0
    }
}
