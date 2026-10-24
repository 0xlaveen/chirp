package dev.chirp.android

import android.Manifest
import android.content.Intent
import android.os.Looper
import android.view.View
import android.os.SystemClock
import android.view.MotionEvent
import android.view.ViewGroup
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.Button
import android.widget.TextView
import java.time.Duration
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
import org.robolectric.util.ReflectionHelpers

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 37])
class ChirpAccessibilityServiceTest {
    class TestService : ChirpAccessibilityService() {
        var paired = true
        val captures = mutableListOf<ChirpImeServiceTest.FakeCapture>()
        val streams = mutableListOf<ChirpImeServiceTest.FakeTransport>()
        private val order = mutableListOf<String>()
        override fun loadPairing() = if (paired) Pairing.from("https://mac.example.test", "synthetic") else null
        override fun createCapture(frame: (ByteArray) -> Boolean, level: (Double) -> Unit, done: (String?) -> Unit): Capture =
            ChirpImeServiceTest.FakeCapture(frame, done, order).also { captures += it }
        override fun createTransport(client: okhttp3.OkHttpClient, pairing: Pairing, event: (ServerEvent) -> Unit, failure: () -> Unit): ImeTransport =
            ChirpImeServiceTest.FakeTransport(event, failure, order).also { streams += it }
    }
    private lateinit var service: TestService
    private lateinit var node: AccessibilityNodeInfo
    private var writes = 0
    private val overlay get() = ReflectionHelpers.getField<View?>(service, "overlay")
    private fun descendants(root: View): List<View> = listOf(root) + if (root is ViewGroup)
        (0 until root.childCount).flatMap { descendants(root.getChildAt(it)) } else emptyList()
    private val bubble get() = descendants(overlay!!).filterIsInstance<Button>().single { it.contentDescription?.toString()?.startsWith("Chirp microphone:") == true }
    private fun button(text: String) = descendants(overlay!!).filterIsInstance<Button>().single { it.text.toString() == text }
    private fun shows(text: String) = descendants(overlay!!).filterIsInstance<TextView>().any { it.text.toString().contains(text) }
    private fun advance(ms: Long = 0) { shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(ms)) }
    private fun focus() {
        ReflectionHelpers.setField(service, "focused", node)
        ReflectionHelpers.callInstanceMethod<Unit>(service, "collapse")
    }
    private fun start() {
        bubble.performClick()
        val intent = shadowOf(RuntimeEnvironment.getApplication()).nextStartedService
        assertNotNull(intent)
        service.onStartCommand(intent, 0, 1)
        service.streams.last().ready()
    }
    @Before fun setup() {
        // Android grants this app-owned signature permission at install; Robolectric needs it explicitly at API 31.
        shadowOf(RuntimeEnvironment.getApplication()).grantPermissions(Manifest.permission.RECORD_AUDIO,
            "dev.chirp.android.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION")
        service = Robolectric.buildService(TestService::class.java).create().get()
        node = AccessibilityNodeInfo().apply {
            isFocused = true; isEditable = true; isEnabled = true
            text = "prefix suffix"; setTextSelection(7, 7)
            addAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_SET_TEXT)
        }
        shadowOf(node).setRefreshReturnValue(true)
        shadowOf(node).setOnPerformActionListener { action, args ->
            when (action) {
                AccessibilityNodeInfo.ACTION_SET_TEXT -> { writes++; node.text = args.getCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE); true }
                AccessibilityNodeInfo.ACTION_SET_SELECTION -> {
                    node.setTextSelection(args.getInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT),
                        args.getInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT)); true
                }
                else -> false
            }
        }
        focus()
    }
    @After fun cleanup() { service.onDestroy() }
    @Test fun `idle has no microphone socket or foreground notification`() {
        assertNotNull(overlay); advance(30000)
        assertTrue(service.captures.isEmpty()); assertTrue(service.streams.isEmpty())
        assertNull(shadowOf(service).lastForegroundNotification)
    }
    @Test fun `partials stay in panel final preserves field contents and closes microphone and socket`() {
        start(); service.streams.last().partial()
        assertTrue(shows("synthetic")); assertEquals("prefix suffix", node.text.toString()); assertEquals(0, writes)
        button("Stop").performClick(); advance(); service.streams.last().final()
        assertEquals("prefix Synthetic.suffix", node.text.toString()); assertEquals(1, writes)
        assertTrue(service.captures.last().released); assertTrue(service.streams.last().closed)
        assertTrue(shadowOf(service).isForegroundStopped)
    }
    @Test fun `field change before final refuses insertion and raw undo expires`() {
        start(); button("Stop").performClick(); advance()
        node.text = "user changed field"; service.streams.last().final()
        assertEquals(0, writes); assertEquals("user changed field", node.text.toString())
        node.text = "prefix suffix"; node.setTextSelection(7, 7)
        button("Tap to dictate").performClick()
        service.onStartCommand(shadowOf(RuntimeEnvironment.getApplication()).nextStartedService, 0, 2)
        service.streams.last().ready(); button("Stop").performClick(); advance(); service.streams.last().final(true)
        assertEquals(View.VISIBLE, button("Use raw").visibility)
        advance(5000)
        assertFalse(descendants(overlay!!).filterIsInstance<Button>().any { it.text.toString() == "Use raw" && it.visibility == View.VISIBLE })
    }
    @Test fun `cancel interrupt and window change release resources and fence late finals`() {
        start(); service.streams.last().partial(); button("Cancel").performClick(); advance()
        assertTrue(service.captures.last().released); assertTrue(service.streams.last().cancelled)
        service.streams.last().final(); assertEquals(0, writes)
        start(); service.onInterrupt(); advance()
        assertNull(overlay); assertTrue(service.captures.last().released)
        service.streams.last().final(); assertEquals(0, writes)
        focus(); start()
        service.onAccessibilityEvent(AccessibilityEvent().apply { eventType = AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED })
        advance(); assertTrue(service.captures.last().released); service.streams.last().final(); assertEquals(0, writes)
    }
    @Test fun `finger release while expanding bubble does not cancel the pending start`() {
        val view = bubble
        val now = SystemClock.uptimeMillis()
        MotionEvent.obtain(now, now, MotionEvent.ACTION_DOWN, 20f, 20f, 0).also { view.dispatchTouchEvent(it); it.recycle() }
        advance(50)
        MotionEvent.obtain(now, now + 50, MotionEvent.ACTION_UP, 20f, 20f, 0).also { view.dispatchTouchEvent(it); it.recycle() }
        advance()
        val intent = shadowOf(RuntimeEnvironment.getApplication()).nextStartedService
        service.onStartCommand(intent, 0, 1)
        assertEquals(1, service.captures.size)
        service.streams.last().ready()
        assertTrue(shows("Listening")); assertFalse(service.captures.last().stopRequested)
    }
    @Test fun `screen off releases microphone and discards late final`() {
        start()
        service.sendBroadcast(Intent(Intent.ACTION_SCREEN_OFF)); advance()
        assertNull(overlay); assertTrue(service.captures.last().released)
        service.streams.last().final(); assertEquals(0, writes)
    }
    @Test fun `password and unsupported fields have no bubble`() {
        node.isPassword = true; focus(); assertNull(overlay)
        node.isPassword = false; node.isEditable = false; focus(); assertNull(overlay)
    }
    @Test fun `permission and pairing errors do not start capture and expose setup repair`() {
        shadowOf(RuntimeEnvironment.getApplication()).denyPermissions(Manifest.permission.RECORD_AUDIO)
        bubble.performClick(); assertTrue(shows("Allow microphone in Chirp settings"))
        assertTrue(service.captures.isEmpty()); assertNotNull(button("Fix setup"))
    }
}
