package dev.chirp.android

import android.Manifest
import android.inputmethodservice.InputMethodService
import android.os.Looper
import android.text.Editable
import android.text.InputType
import android.text.Selection
import android.text.SpannableStringBuilder
import android.view.ContextThemeWrapper
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.inputmethod.BaseInputConnection
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

/** Auto-Enter: which key goes out for each editor action, and that it follows only a complete, successful final. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 37])
class AutoEnterTest {
    class Editor : BaseInputConnection(View(RuntimeEnvironment.getApplication()), true) {
        val buffer = SpannableStringBuilder()
        val actions = mutableListOf<Int>()
        val keys = mutableListOf<Pair<Int, Int>>()
        override fun getEditable(): Editable = buffer
        override fun performEditorAction(editorAction: Int): Boolean { actions += editorAction; return true }
        override fun sendKeyEvent(event: KeyEvent): Boolean { keys += event.action to event.keyCode; return true }
        val text get() = buffer.toString()
        fun reset(value: String, at: Int) { buffer.replace(0, buffer.length, value); Selection.setSelection(buffer, at, at) }
    }
    class Host : InputMethodService() {
        val editor = Editor()
        val info = EditorInfo().apply { inputType = InputType.TYPE_CLASS_TEXT; packageName = "com.example.notes" }
        override fun getCurrentInputConnection() = editor
        override fun getCurrentInputEditorInfo() = info
    }

    private val controller = Robolectric.buildService(Host::class.java)
    private lateinit var host: Host
    private lateinit var voice: KeyboardDictation
    private lateinit var strip: KeyboardStrip
    private lateinit var capture: ChirpImeServiceTest.FakeCapture
    private val streams = mutableListOf<ChirpImeServiceTest.FakeTransport>()
    private val editor get() = host.editor
    private fun advance(ms: Long) = shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(ms))
    private fun tap() { voice.touch(MotionEvent.ACTION_DOWN); advance(40); voice.touch(MotionEvent.ACTION_UP) }
    private fun configure(mode: AutoEnterMode, imeOptions: Int = EditorInfo.IME_ACTION_SEND, inputType: Int = InputType.TYPE_CLASS_TEXT,
                          packageName: String = "com.example.notes") {
        SettingsStore(host).autoEnter = mode
        host.info.imeOptions = imeOptions; host.info.inputType = inputType; host.info.packageName = packageName
        editor.reset("", 0); host.info.initialSelStart = 0; host.info.initialSelEnd = 0
        voice.input(host.info, false)
    }
    /** One dictation, spoken and finished. */
    private fun dictate(text: String = "Hello.") {
        tap(); streams.last().ready(); streams.last().partial(1, "hello"); advance(16)
        tap(); advance(0)
        streams.last().event(ServerEvent.Final(text, text, false)); advance(0)
    }
    private val enter = listOf(KeyEvent.ACTION_DOWN to KeyEvent.KEYCODE_ENTER, KeyEvent.ACTION_UP to KeyEvent.KEYCODE_ENTER)

    @Before fun setup() {
        controller.create(); host = controller.get()
        shadowOf(RuntimeEnvironment.getApplication()).grantPermissions(Manifest.permission.RECORD_AUDIO, LOCAL_NETWORK_PERMISSION)
        voice = KeyboardDictation(host,
            captureFactory = { frame, _, done -> ChirpImeServiceTest.FakeCapture(frame, done, mutableListOf()).also { capture = it } },
            transportFactory = { _, _, event, failure -> ChirpImeServiceTest.FakeTransport(event, failure, mutableListOf()).also { streams += it } },
            prepare = {}, resync = { _, _ -> },
            pairing = { Pairing.from("https://mac.example.test", "synthetic") }, checkHealth = false)
        strip = KeyboardStrip(ContextThemeWrapper(host, R.style.Theme_Chirp)); voice.attach(strip)
        voice.shown()
    }
    @After fun teardown() { voice.destroy(); controller.destroy() }

    // MARK: the decision, per imeOptions case

    private fun press(action: Int, inputType: Int = InputType.TYPE_CLASS_TEXT, mode: AutoEnterMode = AutoEnterMode.ALWAYS, chat: Boolean = true,
                      flags: Int = 0) =
        AutoEnter.press(EditorInfo().apply { imeOptions = action or flags; this.inputType = inputType }, mode, chat)

    @Test fun `send go and done are performed as the editor action`() {
        for (action in listOf(EditorInfo.IME_ACTION_SEND, EditorInfo.IME_ACTION_GO, EditorInfo.IME_ACTION_DONE))
            assertEquals(EnterPress.Action(action), press(action))
    }
    @Test fun `next previous and search are left alone`() {
        for (action in listOf(EditorInfo.IME_ACTION_NEXT, EditorInfo.IME_ACTION_PREVIOUS, EditorInfo.IME_ACTION_SEARCH)) assertNull(press(action))
    }
    @Test fun `no action sends a plain Enter`() {
        assertEquals(EnterPress.Enter, press(EditorInfo.IME_ACTION_UNSPECIFIED))
        assertEquals(EnterPress.Enter, press(EditorInfo.IME_ACTION_NONE))
        assertEquals(EnterPress.Enter, press(EditorInfo.IME_ACTION_UNSPECIFIED, InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE,
            AutoEnterMode.CHAT_APPS))
    }
    @Test fun `an explicit no action in a multi-line field would insert a newline so only Always sends`() {
        val multi = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE
        assertNull(press(EditorInfo.IME_ACTION_NONE, multi, AutoEnterMode.CHAT_APPS))
        assertNull(press(EditorInfo.IME_ACTION_NONE, InputType.TYPE_CLASS_TEXT, AutoEnterMode.CHAT_APPS, flags = EditorInfo.IME_FLAG_NO_ENTER_ACTION))
        assertEquals(EnterPress.Enter, press(EditorInfo.IME_ACTION_NONE, multi, AutoEnterMode.ALWAYS))
        // A real action in a multi-line field still sends.
        assertEquals(EnterPress.Action(EditorInfo.IME_ACTION_SEND), press(EditorInfo.IME_ACTION_SEND, multi, AutoEnterMode.CHAT_APPS))
    }
    @Test fun `never in a password field`() {
        for (type in listOf(InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD,
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD,
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD,
            InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_VARIATION_PASSWORD))
            assertNull("$type", press(EditorInfo.IME_ACTION_SEND, type))
    }
    @Test fun `off never presses and chat apps mode needs a chat app`() {
        assertNull(press(EditorInfo.IME_ACTION_SEND, mode = AutoEnterMode.OFF))
        assertNull(press(EditorInfo.IME_ACTION_SEND, mode = AutoEnterMode.CHAT_APPS, chat = false))
        assertNotNull(press(EditorInfo.IME_ACTION_SEND, mode = AutoEnterMode.CHAT_APPS, chat = true))
        assertNull(AutoEnter.press(null, AutoEnterMode.ALWAYS, true))
    }
    @Test fun `the setting is off by default and survives an unknown value`() {
        assertEquals(AutoEnterMode.OFF, SettingsStore(host).autoEnter)
        SettingsStore(host).autoEnter = AutoEnterMode.CHAT_APPS
        assertEquals(AutoEnterMode.CHAT_APPS, SettingsStore(host).autoEnter)
        assertEquals(AutoEnterMode.OFF, AutoEnterMode.of("bogus"))
    }

    // MARK: through the keyboard

    @Test fun `off leaves the field alone`() {
        configure(AutoEnterMode.OFF); dictate()
        assertEquals("Hello.", editor.text); assertTrue(editor.actions.isEmpty()); assertTrue(editor.keys.isEmpty())
        assertFalse(strip.status.text.contains("↵"))
    }
    @Test fun `always performs the send action once after the final and says so`() {
        configure(AutoEnterMode.ALWAYS); dictate()
        assertEquals("Hello.", editor.text); assertEquals(listOf(EditorInfo.IME_ACTION_SEND), editor.actions); assertTrue(editor.keys.isEmpty())
        assertEquals("Inserted · tap mic to dictate again · ↵ sent", strip.status.text.toString())
        assertEquals(View.GONE, strip.revert.visibility) // the field is gone with the message: nothing to undo
    }
    @Test fun `a field without an action gets an Enter key`() {
        configure(AutoEnterMode.ALWAYS, EditorInfo.IME_ACTION_UNSPECIFIED); dictate()
        assertTrue(editor.actions.isEmpty()); assertEquals(enter, editor.keys)
    }
    @Test fun `chat apps mode follows the app's Chat rule`() {
        configure(AutoEnterMode.CHAT_APPS, packageName = "com.example.notes"); dictate()
        assertTrue(editor.actions.isEmpty())
        configure(AutoEnterMode.CHAT_APPS, packageName = "com.whatsapp"); dictate()
        assertEquals(listOf(EditorInfo.IME_ACTION_SEND), editor.actions)
        SettingsStore(host).appStyles = SettingsStore(host).appStyles + ("com.example.notes" to "chat")
        configure(AutoEnterMode.CHAT_APPS, packageName = "com.example.notes"); dictate()
        assertEquals(2, editor.actions.size)
    }
    @Test fun `a password field never starts a dictation, so nothing is sent even in Always`() {
        configure(AutoEnterMode.ALWAYS, inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD)
        tap(); advance(0)
        assertTrue(streams.isEmpty()); assertEquals("", editor.text); assertTrue(editor.actions.isEmpty()); assertTrue(editor.keys.isEmpty())
    }
    @Test fun `a failed dictation that only kept what was heard does not send`() {
        configure(AutoEnterMode.ALWAYS)
        tap(); streams.last().ready(); streams.last().partial(1, "hello"); advance(16)
        streams.last().failure(); advance(0)
        assertEquals("hello", editor.text); assertTrue(editor.actions.isEmpty()); assertTrue(editor.keys.isEmpty())
        assertFalse(strip.status.text.contains("↵"))
    }
    @Test fun `moving the caret away means the text landed elsewhere and nothing is sent`() {
        configure(AutoEnterMode.ALWAYS)
        tap(); streams.last().ready(); streams.last().partial(1, "hello"); advance(16)
        Selection.setSelection(editor.buffer, 0)
        voice.selection(5, 5, 0, 0, 0, 5); advance(0)
        streams.last().event(ServerEvent.Final("Hello.", "hello", false)); advance(0)
        assertTrue(editor.actions.isEmpty()); assertTrue(editor.keys.isEmpty())
    }
    @Test fun `an empty final sends nothing`() {
        configure(AutoEnterMode.ALWAYS); dictate(" ")
        assertTrue(editor.actions.isEmpty()); assertTrue(editor.keys.isEmpty())
    }
    @Test fun `a long dictation sends once after the last segment only`() {
        configure(AutoEnterMode.ALWAYS)
        voice.toggle(); streams[0].ready(); streams[0].partial(1, "one"); advance(16)
        repeat((DictationSegmenter.MIN_SEGMENT * 25).toInt()) { capture.frame(ByteArray(1280) { i -> if (i % 2 == 0) 0x40 else 0x1f }) }
        repeat((DictationSegmenter.PAUSE_CUT * 25).toInt()) { capture.frame(ByteArray(1280)) }
        advance(0); streams[1].ready(); streams[1].partial(1, "two"); advance(16)
        streams[0].event(ServerEvent.Final("One.", "one", false)); advance(16)
        assertTrue("the first segment lands while the dictation goes on", voice.active)
        assertTrue(editor.actions.isEmpty()); assertTrue(editor.keys.isEmpty())
        voice.toggle(); advance(0); streams[1].event(ServerEvent.Final("Two.", "two", false)); advance(0)
        assertFalse(voice.active); assertEquals("One. Two.", editor.text)
        assertEquals(listOf(EditorInfo.IME_ACTION_SEND), editor.actions)
    }
}
