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

/** Koi's streaming sink pattern: only one frame in memory, with explicit stop/cancel teardown. */
class PcmCapture(
    private val frame: (ByteArray) -> Boolean,
    private val level: (Double) -> Unit,
    private val done: (String?) -> Unit,
) {
    private val running = AtomicBoolean(true)
    private val lock = Any()
    private var recorder: AudioRecord? = null
    private var thread: Thread? = null

    @SuppressLint("MissingPermission") // IME checks RECORD_AUDIO before constructing capture.
    fun start() {
        check(thread == null)
        thread = Thread({
            Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO)
            var error: String? = null
            var local: AudioRecord? = null
            try {
                val minimum = AudioRecord.getMinBufferSize(16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
                check(minimum > 0)
                local = AudioRecord.Builder().setAudioSource(MediaRecorder.AudioSource.VOICE_RECOGNITION)
                    .setAudioFormat(AudioFormat.Builder().setSampleRate(16000).setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
                    .setBufferSizeInBytes(max(minimum, 1280 * 4)).build()
                synchronized(lock) {
                    if (running.get()) { recorder = local; local.startRecording() }
                }
                if (running.get()) check(local.recordingState == AudioRecord.RECORDSTATE_RECORDING)
                val samples = ShortArray(640) // 40 ms at 16 kHz, little-endian PCM16.
                var silentSamples = 0
                var total = 0
                var signalled = false
                var frames = 0
                while (running.get()) {
                    var count = 0
                    while (count < samples.size && running.get()) {
                        val read = local.read(samples, count, samples.size - count, AudioRecord.READ_BLOCKING)
                        if (read <= 0) { if (running.get()) error = "Microphone unavailable"; break }
                        count += read
                    }
                    if (!running.get() || count != samples.size) break
                    var peak = 0
                    var energy = 0.0
                    for (sample in samples) { peak = max(peak, abs(sample.toInt())); energy += sample.toDouble() * sample }
                    silentSamples = if (peak == 0) silentSamples + count else 0
                    if (silentSamples >= 24000) { error = "No microphone signal"; break }
                    if (peak > 0) signalled = true
                    if (++frames % 5 == 0) level(sqrt(energy / count) / 32768.0)
                    // Like Koi, do not send an initial buffer containing no microphone signal.
                    if (signalled) {
                        val bytes = ByteArray(count * 2)
                        for (i in samples.indices) {
                            bytes[i * 2] = samples[i].toByte()
                            bytes[i * 2 + 1] = (samples[i].toInt() shr 8).toByte()
                        }
                        if (!frame(bytes)) { error = "Mac unreachable — is Tailscale on?"; break }
                    }
                    total += count
                    if (total >= 16000 * 120) break
                }
                if (!signalled && error == null) error = "No microphone signal"
                samples.fill(0)
            } catch (_: Exception) {
                if (running.get()) error = "Microphone unavailable — check permission in Chirp setup"
            } finally {
                running.set(false)
                synchronized(lock) {
                    try { local?.stop() } catch (_: IllegalStateException) { }
                    local?.release()
                    recorder = null
                }
                done(error)
            }
        }, "ChirpCapture").also { it.start() }
    }
    fun stop() {
        running.set(false)
        synchronized(lock) { try { recorder?.stop() } catch (_: IllegalStateException) { } }
    }
}
