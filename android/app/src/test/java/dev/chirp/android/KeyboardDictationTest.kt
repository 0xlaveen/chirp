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
    private var healthCalls = 0
    private var sockets = 0
    private fun build(policy: PrewarmPolicy, checkHealth: Boolean = false) {
        voice = KeyboardDictation(host, learning = EditLearning(host, io = { it() }),
            captureFactory = { frame, _, done -> ChirpImeServiceTest.FakeCapture(frame, done, order).also { capture = it } },
            transportFactory = { _, _, event, failure -> sockets++; ChirpImeServiceTest.FakeTransport(event, failure, order).also { stream = it } },
            prepare = { order += "prepare" }, resync = { _, _ -> resyncs++ },
            pairing = { Pairing.from("https://mac.example.test", "synthetic") }, checkHealth = checkHealth,
            healthCheck = { healthCalls++; Health(true, false, true, false, null) }, policy = policy)
        strip = KeyboardStrip(ContextThemeWrapper(host, R.style.Theme_Chirp)); voice.attach(strip)
        voice.input(host.info, false); voice.shown()
    }
    @Before fun setup() {
        controller.create(); host = controller.get()
        shadowOf(RuntimeEnvironment.getApplication()).grantPermissions(Manifest.permission.RECORD_AUDIO, LOCAL_NETWORK_PERMISSION)
        build(PrewarmPolicy().apply { dictated(null) })
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
    @Test fun `countdown shows the seconds left and clears once finishing`() {
        voice.toggle(); stream.ready(); stream.partial(); advance(16)
        capture.countdown!!(15); advance(0)
        assertEquals("Listening… · 15 s left", strip.status.text.toString())
        stream.partial(2, "more"); advance(16)
        assertEquals("Listening… · 15 s left", strip.status.text.toString())
        capture.countdown!!(14); advance(0)
        assertEquals("Listening… · 14 s left", strip.status.text.toString())
        assertEquals("Listening… · 15 s left", strip.status.contentDescription.toString())
        voice.toggle(); advance(0)
        assertFalse(strip.status.text.contains("s left"))
        stream.final(); advance(0)
        assertFalse(strip.status.text.contains("s left"))
    }
    @Test fun `pause mode passes the chosen pause to capture and tap mode passes none`() {
        voice.toggle(); assertNull(capture.pauseSeconds); voice.cancel()
        SettingsStore(host).apply { stopOnPause = true; pauseSeconds = 3.0 }
        voice.toggle(); assertEquals(3.0, capture.pauseSeconds!!, 0.0)
    }
    private fun micTouch(action: Int) {
        val now = android.os.SystemClock.uptimeMillis()
        MotionEvent.obtain(now, now, action, 20f, 20f, 0).also { strip.mic.dispatchTouchEvent(it); it.recycle() }
    }
    @Test fun `press and hold on the strip mic is push-to-talk, release finishes (172)`() {
        assertFalse(strip.mic.isLongClickable) // a long press no longer opens options: it is a hold
        micTouch(MotionEvent.ACTION_DOWN); assertTrue(voice.active); assertTrue(capture.started); stream.ready()
        capture.frame(byteArrayOf(1, 2)); stream.partial(); advance(700)
        assertTrue(voice.active); assertEquals(0, stream.stops)
        micTouch(MotionEvent.ACTION_UP); advance(0)
        assertTrue(capture.released); assertEquals(1, stream.stops)
        stream.final(); advance(0); assertEquals("Synthetic.", host.editor.committed)
    }
    @Test fun `a short tap on the strip mic keeps listening and the next tap stops`() {
        micTouch(MotionEvent.ACTION_DOWN); advance(60); micTouch(MotionEvent.ACTION_UP); stream.ready()
        assertTrue(voice.active); assertEquals(0, stream.stops)
        micTouch(MotionEvent.ACTION_DOWN); advance(60); micTouch(MotionEvent.ACTION_UP); advance(0)
        assertEquals(1, stream.stops)
    }
    @Test fun `a cancelled hold cancels the dictation and accessibility click still toggles`() {
        micTouch(MotionEvent.ACTION_DOWN); stream.ready(); stream.partial(); advance(16)
        micTouch(MotionEvent.ACTION_CANCEL); advance(0)
        assertFalse(voice.active); assertEquals("", host.editor.committed)
        strip.mic.performClick(); assertTrue(voice.active); stream.ready() // TalkBack double-tap
        strip.mic.performClick(); advance(0); assertEquals(1, stream.stops)
    }
    @Test fun `options sit on the beside-mic button and as a TalkBack action, not on the mic's long press`() {
        assertEquals("Dictation options", strip.options.contentDescription.toString())
        assertEquals(android.view.View.VISIBLE, strip.options.visibility)
        val actions = androidx.core.view.accessibility.AccessibilityNodeInfoCompat.obtain().also { strip.mic.onInitializeAccessibilityNodeInfo(it.unwrap()) }
            .actionList.map { it.label?.toString() }
        assertTrue(actions.toString(), "Dictation options" in actions)
        assertTrue(strip.mic.contentDescription.toString().contains("hold to talk"))
        strip.options.performClick(); assertFalse(voice.active) // opening options never starts capture
        voice.toggle(); stream.ready(); advance(0)
        assertEquals(android.view.View.GONE, strip.options.visibility) // out of the way while listening, like history
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
    @Test fun `moving the cursor after a cleaned final still expires the notice`() {
        start(); finish(true)
        voice.selection(10, 10, 0, 0, -1, -1)
        assertEquals(android.view.View.GONE, strip.raw.visibility)
        advance(5000)
        assertEquals(android.view.View.GONE, strip.status.visibility)
        assertEquals(android.view.View.VISIBLE, strip.history.visibility)
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
    @Test fun `connection failure keeps heard text without rendering it in the status`() {
        start(); stream.partial(); advance(16); stream.failure()
        assertFalse(voice.active)
        assertEquals("", host.editor.composing); assertEquals("synthetic", host.editor.committed)
        assertEquals("Connection lost — kept what I heard", strip.status.text.toString())
        assertFalse(strip.status.contentDescription.contains("synthetic"))
        start(); stream.failure()
        assertEquals("Check Tailscale", strip.status.text.toString())
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
        assertEquals("Synthetic.", host.editor.committed); assertEquals("Polished", strip.status.text.toString())
        assertEquals(android.view.View.VISIBLE, strip.raw.visibility)
        strip.raw.performClick(); assertEquals("synthetic raw", host.editor.committed)
    }
    @Test fun `polishing timeout commits original and reduced motion stays static`() {
        android.provider.Settings.Global.putFloat(host.contentResolver, android.provider.Settings.Global.ANIMATOR_DURATION_SCALE, 0f)
        start(); tap(); advance(0); stream.event(ServerEvent.Correcting(2, "synthetic raw", "default"))
        advance(500); assertEquals(1f, strip.status.alpha)
        advance(12000)
        assertEquals("synthetic raw", host.editor.committed); assertFalse(voice.active)
        assertEquals("Kept what was heard", strip.status.text.toString())
        advance(5000); assertEquals(android.view.View.GONE, strip.status.visibility)
    }

    @Test fun `show prewarms without recording and closes unused socket after thirty seconds`() {
        assertTrue(stream.connected); assertEquals(0, stream.starts)
        assertFalse(order.contains("capture.start"))
        val idle = stream; advance(30000); assertTrue(idle.closed)
        start(); assertEquals(1, stream.starts); assertTrue(capture.started)
        voice.hidden(); assertTrue(stream.closed)
    }
    @Test fun `a cold keyboard connects on press and the next show prewarms after a dictation`() {
        voice.destroy(); sockets = 0
        build(PrewarmPolicy())
        assertEquals("no recent dictation: no socket on show", 0, sockets)
        voice.hidden(); voice.shown(); assertEquals(0, sockets)
        start(); assertEquals(1, sockets); assertEquals(1, stream.starts); assertTrue(capture.started)
        finish(); voice.hidden(); voice.shown()
        assertEquals("dictated a moment ago: warm on show", 2, sockets); assertTrue(stream.connected); assertEquals(0, stream.starts)
    }
    @Test fun `show checks health at most once a minute and a failed check frees the slot`() {
        voice.destroy(); healthCalls = 0
        var clock = 0L
        build(PrewarmPolicy(now = { clock }), checkHealth = true)
        val await = { n: Int -> repeat(300) { shadowOf(Looper.getMainLooper()).idle(); if (healthCalls >= n) return@repeat; Thread.sleep(10) } }
        await(1); assertEquals(1, healthCalls)
        voice.hidden(); clock += 30_000; voice.shown(); Thread.sleep(100); shadowOf(Looper.getMainLooper()).idle()
        assertEquals("within 60 s: no second health call", 1, healthCalls)
        voice.hidden(); clock += 31_000; voice.shown(); await(2); assertEquals(2, healthCalls)
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
            "busy" to "Chirp server is busy — try again", "too_long" to "Dictation limit is 120 seconds",
            "auth" to "Pairing refused — pair again in Chirp settings",
            "bad_request" to "Clean-up prompt too long — shorten it in Chirp settings",
            "unknown" to "Speech engine unavailable — try again")) {
            start(); tap(); tap(); advance(0) // No partial: nothing heard, nothing kept.
            val old = stream
            stream.event(ServerEvent.Failure(code))
            assertFalse(voice.active); assertEquals("", host.editor.committed)
            assertEquals(message, strip.status.contentDescription.toString().substringBefore(". Pair computer"))
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
