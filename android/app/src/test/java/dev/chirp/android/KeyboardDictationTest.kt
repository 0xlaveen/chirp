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
        start(); stream.partial(); advance(16); assertEquals("synthetic", host.editor.composing)
        finish(); assertFalse(voice.active); assertTrue(capture.released); assertTrue(stream.closed)
        assertEquals("Synthetic.", host.editor.committed)
        start(); stream.partial(); advance(16); assertEquals(" synthetic", host.editor.composing)
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
        start(); stream.partial(); advance(16); voice.beforeEdit()
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
        start(); stream.partial(); advance(16); finish(true)
        assertEquals("synthetic Synthetic.", host.editor.committed)
        strip.raw.performClick(); assertEquals("synthetic synthetic", host.editor.committed)
        start(); finish(true); advance(5000)
        assertEquals(android.view.View.GONE, strip.raw.visibility)
    }
    @Test fun `hide destroy and late capture callbacks cannot restart recording or commit`() {
        start(); stream.partial(); advance(16); val old = stream
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

    @Test fun `microphone denial offers app permissions and does not start capture`() {
        shadowOf(RuntimeEnvironment.getApplication()).denyPermissions(Manifest.permission.RECORD_AUDIO)
        strip.mic.performClick()
        assertFalse(voice.active)
        assertEquals("Open mic settings", strip.status.text.toString())
        strip.status.performClick()
        val intent = shadowOf(host).nextStartedActivity
        assertEquals(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS, intent.action)
        assertEquals("package:dev.chirp.android", intent.dataString)
    }
    @Test fun `connection failure offers Tailscale recovery without retaining partial text`() {
        start(); stream.partial(); advance(16); stream.failure()
        assertFalse(voice.active)
        assertEquals("", host.editor.composing)
        assertEquals("Check Tailscale", strip.status.text.toString())
        assertFalse(strip.status.text.contains("synthetic"))
    }
    @Test fun `dictated spelling bypasses keyboard autocorrection and learning`() {
        start(); stream.event(ServerEvent.Partial(1, "teh im", "")); advance(16)
        tap(); advance(0)
        stream.event(ServerEvent.Final("teh im", "teh im", false))
        assertEquals("teh im", host.editor.committed)
        assertEquals("", host.editor.composing)
        assertFalse(voice.ownsComposition)
        assertEquals(1, resyncs)
    }

    @Test fun `polishing keeps raw composing shows style and cleans with bounded undo`() {
        start(); stream.partial(); advance(16); tap(); advance(0)
        stream.event(ServerEvent.Correcting(2, "synthetic raw", "default"))
        assertEquals("synthetic raw", host.editor.composing); assertEquals("", host.editor.committed)
        assertEquals("Polishing…", strip.status.text.toString())
        assertEquals(android.view.View.VISIBLE, strip.style.visibility)
        stream.event(ServerEvent.Final("Synthetic.", "synthetic raw", true)); advance(450)
        assertEquals("Synthetic.", host.editor.committed); assertEquals("cleaned", strip.status.text.toString())
        assertEquals(android.view.View.VISIBLE, strip.raw.visibility)
        strip.raw.performClick(); assertEquals("synthetic raw", host.editor.committed)
    }
    @Test fun `polishing timeout commits original and reduced motion stays static`() {
        android.provider.Settings.Global.putFloat(host.contentResolver, android.provider.Settings.Global.ANIMATOR_DURATION_SCALE, 0f)
        start(); tap(); advance(0); stream.event(ServerEvent.Correcting(2, "synthetic raw", "default"))
        advance(500); assertEquals(1f, strip.status.alpha)
        advance(12000)
        assertEquals("synthetic raw", host.editor.committed); assertFalse(voice.active)
        assertEquals("kept original", strip.status.text.toString())
        advance(5000); assertEquals(android.view.View.GONE, strip.status.visibility)
    }

    @Test fun `show prewarms without recording and closes unused socket after thirty seconds`() {
        assertTrue(stream.connected); assertEquals(0, stream.starts)
        assertFalse(order.contains("capture.start"))
        val idle = stream; advance(30000); assertTrue(idle.closed)
        start(); assertEquals(1, stream.starts); assertTrue(capture.started)
        voice.hidden(); assertTrue(stream.closed)
    }
    @Test fun `error notice expires to restore suggestions`() {
        shadowOf(RuntimeEnvironment.getApplication()).denyPermissions(Manifest.permission.RECORD_AUDIO)
        strip.mic.performClick(); assertEquals(android.view.View.VISIBLE, strip.status.visibility)
        advance(5000); assertEquals(android.view.View.GONE, strip.status.visibility)
    }

    @Test fun `empty final removes partial and briefly explains without committing`() {
        start(); stream.partial(); advance(16); tap(); advance(0)
        stream.event(ServerEvent.Final("", "", false))
        assertEquals("", host.editor.committed); assertEquals("", host.editor.composing)
        assertEquals(0, host.editor.commits); assertFalse(voice.active)
        assertEquals("Didn't catch that", strip.status.text.toString())
        advance(5000); assertEquals(android.view.View.GONE, strip.status.visibility)
    }
    @Test fun `every server error survives stop and late cancel callbacks`() {
        for ((code, message) in mapOf(
            "bad_audio" to "Didn't catch that", "engine" to "Speech engine hiccup",
            "busy" to "Mac is busy — try again", "too_long" to "Dictation limit is 120 seconds",
            "auth" to "Pairing refused — pair again in Chirp setup",
            "bad_request" to "Clean-up prompt too long — shorten it in Chirp settings",
            "unknown" to "Mac speech engine unavailable — try again")) {
            start(); stream.partial(); advance(16); tap(); tap(); advance(0)
            val old = stream
            stream.event(ServerEvent.Failure(code))
            assertFalse(voice.active); assertEquals("", host.editor.committed)
            assertEquals(message, strip.status.contentDescription.toString().substringBefore(". Pair Mac"))
            voice.hidden(); old.final(); capture.finish(); advance(0)
            assertEquals(0, host.editor.commits)
            voice.shown()
        }
    }
    @Test fun `stop then focus loss discards delayed polishing result`() {
        start(); tap(); advance(0)
        stream.event(ServerEvent.Correcting(2, "synthetic raw", "default"))
        stream.final(true)
        voice.input(host.info, false); advance(12000)
        assertEquals(0, host.editor.commits); assertFalse(voice.active)
    }

    @Test fun `start requests on-Mac cleanup by default but never when the server reports off`() {
        val store = SettingsStore(host)
        val local = Health(true, false, true, false, null)
        store.health = local
        start(); assertTrue(stream.correctionRequested); voice.cancel()
        store.correction = true
        store.health = local.copy(correctionAvailable = false)
        start(); assertFalse(stream.correctionRequested)
    }

}
