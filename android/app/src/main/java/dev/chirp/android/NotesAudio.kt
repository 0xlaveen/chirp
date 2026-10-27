package dev.chirp.android

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaDataSource
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaPlayer
import android.os.Handler
import android.os.Looper
import java.io.File
import java.util.concurrent.Executors
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONObject

/**
 * Kept audio for one transcript segment: where it starts in the note's audio clock, how long it runs and the sample rate it
 * was captured at (so a later re-transcribe can rebuild the transcript in order). [bytes] is the sealed file's plain size.
 */
internal data class NotesAudioClip(val segment: Int, val offset: Double, val duration: Double, val sampleRate: Int, val bytes: Long) {
    fun toJson(): JSONObject = JSONObject().put("segment", segment).put("offset", offset).put("duration", duration)
        .put("sampleRate", sampleRate).put("bytes", bytes)

    companion object {
        fun fromJson(json: JSONObject) = NotesAudioClip(json.getInt("segment"), json.getDouble("offset"), json.getDouble("duration"),
            json.getInt("sampleRate"), json.getLong("bytes"))
    }
}

/** Turns one segment's PCM16 mono audio into a playable `.m4a`. A seam: the JVM has no codecs, so tests bring their own. */
internal interface AudioEncoder {
    fun encode(pcm: ByteArray, sampleRate: Int): ByteArray
}

/**
 * AAC-LC, mono, about 32 kbps in an MPEG-4 container, made with the platform's MediaCodec and MediaMuxer. Blocking: run it
 * off the main thread. MediaMuxer needs a file, so the result passes through a scratch file in [scratch] that is
 * overwritten and deleted at once.
 */
internal class MediaCodecAacEncoder(private val scratch: File, private val bitRate: Int = BIT_RATE) : AudioEncoder {
    override fun encode(pcm: ByteArray, sampleRate: Int): ByteArray {
        scratch.mkdirs()
        val file = File.createTempFile("enc", ".m4a", scratch)
        val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, sampleRate, 1).apply {
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            setInteger(MediaFormat.KEY_BIT_RATE, bitRate)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16384)
        }
        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
        var muxer: MediaMuxer? = null
        var muxing = false
        try {
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            codec.start()
            muxer = MediaMuxer(file.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            val info = MediaCodec.BufferInfo()
            val deadline = System.nanoTime() + TIMEOUT_NS
            var track = -1; var position = 0; var sentEnd = false; var done = false
            while (!done) {
                check(System.nanoTime() < deadline) { "encoder timed out" }
                if (!sentEnd) {
                    val index = codec.dequeueInputBuffer(DEQUEUE_US)
                    if (index >= 0) {
                        val input = codec.getInputBuffer(index) ?: error("no input buffer")
                        input.clear()
                        val count = minOf(input.remaining(), pcm.size - position).let { it - it % 2 }
                        val time = position / 2 * 1_000_000L / sampleRate
                        if (count <= 0) { codec.queueInputBuffer(index, 0, 0, time, MediaCodec.BUFFER_FLAG_END_OF_STREAM); sentEnd = true }
                        else { input.put(pcm, position, count); codec.queueInputBuffer(index, 0, count, time, 0); position += count }
                    }
                }
                val out = codec.dequeueOutputBuffer(info, DEQUEUE_US)
                when {
                    out == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> { track = muxer.addTrack(codec.outputFormat); muxer.start(); muxing = true }
                    out >= 0 -> {
                        val buffer = codec.getOutputBuffer(out)
                        if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) info.size = 0
                        if (info.size > 0 && muxing && buffer != null) {
                            buffer.position(info.offset); buffer.limit(info.offset + info.size)
                            muxer.writeSampleData(track, buffer, info)
                        }
                        codec.releaseOutputBuffer(out, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) done = true
                    }
                }
            }
            check(muxing) { "encoder produced nothing" }
            muxer.stop()
            muxing = false
            return file.readBytes()
        } finally {
            try { codec.stop() } catch (_: Exception) { }
            codec.release()
            try { if (muxing) muxer?.stop() } catch (_: Exception) { }
            try { muxer?.release() } catch (_: Exception) { }
            try { file.writeBytes(ByteArray(file.length().toInt())) } catch (_: Exception) { }
            file.delete()
        }
    }

    companion object {
        const val BIT_RATE = 32_000
        private const val DEQUEUE_US = 10_000L
        private const val TIMEOUT_NS = 120_000_000_000L
    }
}

/** The decrypted clip, served from memory: nothing readable is ever written to disk for playback. */
internal class BytesDataSource(private val bytes: ByteArray) : MediaDataSource() {
    override fun readAt(position: Long, buffer: ByteArray, offset: Int, size: Int): Int {
        if (position >= bytes.size) return -1
        val count = minOf(size.toLong(), bytes.size - position).toInt()
        System.arraycopy(bytes, position.toInt(), buffer, offset, count)
        return count
    }
    override fun getSize() = bytes.size.toLong()
    override fun close() { bytes.fill(0) }
}

/** Which clip is playing: a note and a segment index. */
internal data class NotesClipRef(val noteId: String, val segment: Int)

/**
 * Plays one kept segment at a time. [playing] is what the transcript row highlights. The clip is decrypted off the main
 * thread, played from memory and dropped when it ends or another one starts.
 */
internal class NotesAudioPlayer(
    private val library: NotesSessions,
    private val newPlayer: () -> MediaPlayer = ::MediaPlayer,
    private val read: (() -> Unit) -> Unit = { IO.execute(it) },
) {
    private val main = Handler(Looper.getMainLooper())
    private val state = MutableStateFlow<NotesClipRef?>(null)
    private val failure = MutableStateFlow(false)
    private var player: MediaPlayer? = null
    private var source: BytesDataSource? = null
    private var request = 0
    val playing: StateFlow<NotesClipRef?> get() = state
    val failed: StateFlow<Boolean> get() = failure

    fun play(noteId: String, segment: Int, offsetMillis: Int = 0) {
        stop()
        failure.value = false
        val ref = NotesClipRef(noteId, segment)
        val mine = ++request
        read {
            val bytes = try { library.clipBytes(noteId, segment) } catch (_: Exception) { null }
            main.post {
                if (mine != request) { bytes?.fill(0); return@post }
                if (bytes == null) { failure.value = true; return@post }
                try {
                    val data = BytesDataSource(bytes).also { source = it }
                    val next = newPlayer().also { player = it }
                    next.setDataSource(data)
                    next.setOnCompletionListener { if (mine == request) stop() }
                    next.setOnErrorListener { _, _, _ -> if (mine == request) { stop(); failure.value = true }; true }
                    next.setOnPreparedListener { if (mine == request) { if (offsetMillis > 0) it.seekTo(offsetMillis); it.start(); state.value = ref } }
                    next.prepareAsync()
                } catch (_: Exception) { stop(); failure.value = true }
            }
        }
    }

    fun stop() {
        request++
        state.value = null
        player?.let { try { it.stop() } catch (_: Exception) { }; it.release() }
        player = null
        source?.close(); source = null
    }

    private companion object { val IO = Executors.newSingleThreadExecutor { Thread(it, "chirp-notes-audio-read").apply { isDaemon = true } } }
}

/** The encoding thread: one at a time, apart from the notes writer so a long encode never delays a text save. */
internal object NotesAudioIo {
    private val executor = Executors.newSingleThreadExecutor { Thread(it, "chirp-notes-audio").apply { isDaemon = true } }
    fun run(work: () -> Unit) { executor.execute { try { work() } catch (_: Exception) { /* Best effort, never logged. */ } } }
}

/** Decrypted AAC in, 16 kHz mono little-endian PCM16 out. No plaintext file is needed. */
internal fun interface AudioDecoder {
    fun decode(encoded: ByteArray): ByteArray
}

internal class MediaCodecAacDecoder : AudioDecoder {
    override fun decode(encoded: ByteArray): ByteArray {
        val source = BytesDataSource(encoded)
        val extractor = android.media.MediaExtractor()
        var codec: MediaCodec? = null
        try {
            extractor.setDataSource(source)
            val track = (0 until extractor.trackCount).first { extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true }
            extractor.selectTrack(track)
            val format = extractor.getTrackFormat(track)
            val decoder = MediaCodec.createDecoderByType(requireNotNull(format.getString(MediaFormat.KEY_MIME))).also { codec = it }
            decoder.configure(format, null, null, 0)
            decoder.start()
            var outputFormat = format
            var ended = false
            val output = java.io.ByteArrayOutputStream()
            val info = MediaCodec.BufferInfo()
            val deadline = System.nanoTime() + 120_000_000_000L
            while (true) {
                check(!Thread.currentThread().isInterrupted && System.nanoTime() < deadline) { "decode timeout" }
                if (!ended) {
                    val index = decoder.dequeueInputBuffer(10_000)
                    if (index >= 0) {
                        val buffer = requireNotNull(decoder.getInputBuffer(index)).apply { clear() }
                        val count = extractor.readSampleData(buffer, 0)
                        if (count < 0) { decoder.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM); ended = true }
                        else { decoder.queueInputBuffer(index, 0, count, extractor.sampleTime, 0); extractor.advance() }
                    }
                }
                when (val index = decoder.dequeueOutputBuffer(info, 10_000)) {
                    MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> outputFormat = decoder.outputFormat
                    else -> if (index >= 0) {
                        decoder.getOutputBuffer(index)?.let { buffer ->
                            buffer.position(info.offset); buffer.limit(info.offset + info.size)
                            val bytes = ByteArray(info.size); buffer.get(bytes); output.write(bytes); bytes.fill(0)
                        }
                        decoder.releaseOutputBuffer(index, false)
                        check(output.size() <= 32_000 * 125) { "clip too long" }
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                    }
                }
            }
            // Kept clips are encoded at 16 kHz mono; reject malformed/unexpected formats rather than send corrupt audio.
            check(outputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE) == 16000 && outputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT) == 1)
            check(!outputFormat.containsKey(MediaFormat.KEY_PCM_ENCODING) || outputFormat.getInteger(MediaFormat.KEY_PCM_ENCODING) == android.media.AudioFormat.ENCODING_PCM_16BIT)
            return output.toByteArray().also { check(it.isNotEmpty() && it.size % 2 == 0) }
        } finally {
            try { codec?.stop() } catch (_: Exception) { }
            codec?.release(); extractor.release(); source.close()
        }
    }
}
