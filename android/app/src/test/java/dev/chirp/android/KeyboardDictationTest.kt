package dev.chirp.android

import android.Manifest
import android.inputmethodservice.InputMethodService
import android.os.Looper
import android.os.SystemClock
import android.view.ContextThemeWrapper
import android.view.MotionEvent
import android.view.inputmethod.EditorInfo
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.time.Duration

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 37])
class KeyboardDictationTest {
    class Host : InputMethodService() {
        val editor = ChirpImeServiceTest.Editor()
        val info = EditorInfo().apply { inputType = android.text.InputType.TYPE_CLASS_TEXT; initialSelStart = 0; initialSelEnd = 0 }
        override fun getCurrentInputConnection() = editor.connection
        override fun getCurrentInputEditorInfo() = info
    }
    private val controller = Robolectric.buildService(Host::class.java)
    private lateinit var host: Host
    private lateinit var voice: KeyboardDictation
    private lateinit var strip: KeyboardStrip
    private lateinit var stream: ChirpImeServiceTest.FakeTransport
    private lateinit var capture: ChirpImeServiceTest.FakeCapture
    private val order = mutableListOf<String>()
    private var resyncs = 0
    private fun advance(ms: Long) = shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(ms))
    private fun tap() { voice.touch(MotionEvent.ACTION_DOWN); advance(40); voice.touch(MotionEvent.ACTION_UP) }
    private fun start() { tap(); stream.ready() }
    private fun finish(corrected: Boolean = false) { tap(); advance(0); stream.final(corrected) }
    @Before fun setup() {
        controller.create(); host = controller.get()
        shadowOf(RuntimeEnvironment.getApplication()).grantPermissions(Manifest.permission.RECORD_AUDIO, LOCAL_NETWORK_PERMISSION)
        voice = KeyboardDictation(host,
            captureFactory = { frame, _, done -> ChirpImeServiceTest.FakeCapture(frame, done, order).also { capture = it } },
            transportFactory = { _, _, event, failure -> ChirpImeServiceTest.FakeTransport(event, failure, order).also { stream = it } },
            prepare = { order += "prepare" }, resync = { _, _ -> resyncs++ },
            pairing = { Pairing.from("https://mac.example.test", "synthetic") }, checkHealth = false)
        strip = KeyboardStrip(ContextThemeWrapper(host, R.style.Theme_Chirp)); voice.attach(strip)
        voice.input(host.info, false); voice.shown()
    }
    @After fun teardown() { voice.destroy(); controller.destroy() }
    @Test fun `full keyboard stays after two finals even with legacy auto return enabled`() {
        SettingsStore(host).returnToPrevious = true
        start(); stream.partial(); assertEquals("synthetic", host.editor.composing)
        finish(); assertFalse(voice.active); assertTrue(capture.released); assertTrue(stream.closed)
        assertEquals("Synthetic.", host.editor.committed)
        start(); stream.partial(); assertEquals(" synthetic", host.editor.composing)
        finish(); assertEquals("Synthetic. Synthetic.", host.editor.committed)
        assertEquals(2, host.editor.commits); assertEquals(2, resyncs)
    }
    @Test fun `hold before ready waits for release and cancel rejects late results`() {
        voice.touch(MotionEvent.ACTION_DOWN); capture.frame(byteArrayOf(1, 2)); advance(350)
        voice.touch(MotionEvent.ACTION_UP); advance(0)
        assertTrue(capture.released); assertEquals(0, stream.stops)
        stream.ready(); assertEquals(1, stream.stops)
        voice.cancel(); stream.final(); assertEquals("", host.editor.committed)
    }
    @Test fun `typing discards live composition and invalidates raw undo`() {
        start(); stream.partial(); voice.beforeEdit()
        assertEquals("", host.editor.composing); assertTrue(capture.released)
        stream.final(); assertEquals("", host.editor.committed)
        start(); finish(true); assertEquals(android.view.View.VISIBLE, strip.raw.visibility)
        voice.beforeEdit(); strip.raw.performClick(); assertEquals("Synthetic.", host.editor.committed)
    }
    @Test fun `raw replacement and expiry remain bounded without switching keyboard`() {
        start(); finish(true)
        assertEquals(android.view.View.VISIBLE, strip.raw.visibility)
        strip.raw.performClick(); assertEquals("synthetic", host.editor.committed)
        assertEquals(android.view.View.GONE, strip.raw.visibility)
        start(); stream.partial(); finish(true)
        assertEquals("synthetic Synthetic.", host.editor.committed)
        strip.raw.performClick(); assertEquals("synthetic synthetic", host.editor.committed)
        start(); finish(true); advance(5000)
        assertEquals(android.view.View.GONE, strip.raw.visibility)
    }
    @Test fun `hide destroy and late capture callbacks cannot restart recording or commit`() {
        start(); stream.partial(); val old = stream
        voice.hidden(); capture.finish(); old.final(); advance(0)
        assertFalse(voice.active); assertEquals("", host.editor.committed)
        voice.destroy(); voice.shown(); tap(); assertFalse(voice.active)
    }
    @Test fun `raw chip after final survives disconnected composing region then dictates again`() {
        start(); finish(true)
        host.editor.disconnectOnRegion = true
        strip.raw.performClick()
        assertEquals("Synthetic.", host.editor.committed)
        host.editor.disconnectOnRegion = false
        start(); finish()
        assertEquals("Synthetic. Synthetic.", host.editor.committed)
    }

}
