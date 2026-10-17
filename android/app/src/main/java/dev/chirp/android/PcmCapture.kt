package dev.chirp.android

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Process
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.sqrt

interface Capture { fun start(); fun stop() }

/** Injectable PCM input keeps the real framing, buffering and transport path under test. */
internal interface PcmInput {
    val finished: Boolean get() = false
    fun start()
    fun read(samples: ShortArray, offset: Int, count: Int): Int
    fun stop()
    fun close()
}
private class MicrophoneInput : PcmInput {
    private var recorder: AudioRecord? = null
    @SuppressLint("MissingPermission") // Host checks permission before capture; failed/revoked grants are handled below.
    override fun start() {
        val minimum = AudioRecord.getMinBufferSize(16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        check(minimum > 0)
        val audio = AudioRecord.Builder().setAudioSource(MediaRecorder.AudioSource.VOICE_RECOGNITION)
            .setAudioFormat(AudioFormat.Builder().setSampleRate(16000).setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
            .setBufferSizeInBytes(max(minimum, 1280 * 4)).build()
        recorder = audio
        audio.startRecording()
        check(audio.recordingState == AudioRecord.RECORDSTATE_RECORDING)
    }
    override fun read(samples: ShortArray, offset: Int, count: Int) = recorder?.read(samples, offset, count, AudioRecord.READ_BLOCKING) ?: -1
    override fun stop() { try { recorder?.stop() } catch (_: IllegalStateException) { } }
    override fun close() { recorder?.release(); recorder = null }
}

/** One frame in memory, explicit stop/release before completion, and no content logging. */
class PcmCapture internal constructor(
    private val frame: (ByteArray) -> Boolean,
    private val level: (Double) -> Unit,
    private val done: (String?) -> Unit,
    private val input: PcmInput,
) : Capture {
    constructor(frame: (ByteArray) -> Boolean, level: (Double) -> Unit, done: (String?) -> Unit) : this(frame, level, done, MicrophoneInput())
    private val running = AtomicBoolean(true)
    private val lock = Any()
    private var thread: Thread? = null
    override fun start() {
        check(thread == null)
        thread = Thread({
            var error: String? = null
            val samples = ShortArray(640)
            try {
                Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO)
                synchronized(lock) { if (running.get()) input.start() }
                var silentSamples = 0; var total = 0; var signalled = false; var frames = 0
                while (running.get()) {
                    var count = 0
                    while (count < samples.size && running.get()) {
                        val read = input.read(samples, count, samples.size - count)
                        if (read <= 0) { if (running.get() && !input.finished) error = "Microphone unavailable"; break }
                        count += read
                    }
                    if (!running.get() || count != samples.size) break
                    var peak = 0; var energy = 0.0
                    for (sample in samples) { peak = max(peak, abs(sample.toInt())); energy += sample.toDouble() * sample }
                    silentSamples = if (peak == 0) silentSamples + count else 0
                    if (silentSamples >= 24000) { error = "No microphone signal"; break }
                    if (peak > 0) signalled = true
                    if (++frames % 5 == 0) level(sqrt(energy / count) / 32768.0)
                    if (signalled) {
                        val bytes = ByteArray(count * 2)
                        for (i in samples.indices) { bytes[i * 2] = samples[i].toByte(); bytes[i * 2 + 1] = (samples[i].toInt() shr 8).toByte() }
                        if (!frame(bytes)) { error = "Mac unreachable — is Tailscale on?"; break }
                    }
                    total += count
                    if (total >= 16000 * 120) break
                }
                if (!signalled && error == null) error = "No microphone signal"
            } catch (_: Exception) {
                if (running.get()) error = "Microphone unavailable — check permission in Chirp setup"
            } finally {
                running.set(false); samples.fill(0)
                synchronized(lock) {
                    try { input.stop() } catch (_: RuntimeException) { }
                    try { input.close() } catch (_: RuntimeException) { }
                }
                done(error)
            }
        }, "ChirpCapture").also { it.start() }
    }
    override fun stop() {
        running.set(false)
        synchronized(lock) { try { input.stop() } catch (_: RuntimeException) { } }
    }
}
