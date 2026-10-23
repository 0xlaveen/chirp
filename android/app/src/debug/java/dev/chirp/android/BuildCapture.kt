package dev.chirp.android

import android.content.Context
import androidx.core.content.edit
import dev.chirp.android.ui.SwitchRow
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import okhttp3.HttpUrl
import java.io.DataInputStream

internal fun allowedServer(base: HttpUrl) = base.isHttps || (base.scheme == "http" && base.host == "10.0.2.2" && base.port == 7899)
internal fun captureForBuild(context: Context, frame: (ByteArray) -> Boolean, level: (Double) -> Unit, done: (String?) -> Unit): Capture =
    if (context.getSharedPreferences("debug_capture", 0).getBoolean("synthetic", false))
        PcmCapture(frame, level, done, SyntheticPcmInput(context))
    else PcmCapture(frame, level, done)

/** Debug only: generated speech asset, paced in real time through PcmCapture's real framing loop. */
private class SyntheticPcmInput(private val context: Context) : PcmInput {
    private var stream: DataInputStream? = null
    private var left = 0
    @Volatile private var stopped = false
    private var firstRead = true
    override val finished get() = left < 2
    override fun start() {
        val input = DataInputStream(context.assets.open("synthetic.wav")); stream = input
        check(input.readInt() == 0x52494646); input.skipBytes(4); check(input.readInt() == 0x57415645)
        while (true) {
            val type = input.readInt(); val length = Integer.reverseBytes(input.readInt())
            if (type == 0x64617461) { left = length; break }
            input.skipBytes(length + length % 2)
        }
    }
    override fun read(samples: ShortArray, offset: Int, count: Int): Int {
        if (firstRead) {
            firstRead = false
            Thread.sleep(context.getSharedPreferences("debug_capture", 0).getLong("initial_frame_delay_ms", 0).coerceIn(0, 4000))
        }
        if (stopped || left < 2) return -1
        val size = minOf(count, left / 2)
        for (i in 0 until size) samples[offset + i] = java.lang.Short.reverseBytes(stream!!.readShort())
        left -= size * 2
        Thread.sleep(size * 1000L / 16000)
        return size
    }
    override fun stop() { stopped = true }
    override fun close() { stream?.close(); stream = null }
}
@Composable internal fun BuildSetupOptions() {
    val context = LocalContext.current
    val prefs = remember { context.getSharedPreferences("debug_capture", 0) }
    var checked by remember { mutableStateOf(prefs.getBoolean("synthetic", false)) }
    SwitchRow("Debug: synthetic speech (no microphone)", checked, { checked = it; prefs.edit { putBoolean("synthetic", it) } })
}

internal fun recordDebugNetworkFailure(context: Context, error: Exception) {
    context.getSharedPreferences("debug_capture", 0).edit {
        putString("failure_class", error.javaClass.name + "/" + error.cause?.javaClass?.name.orEmpty())
        putBoolean("cleartext_allowed", android.security.NetworkSecurityPolicy.getInstance().isCleartextTrafficPermitted("10.0.2.2"))
    }
}
