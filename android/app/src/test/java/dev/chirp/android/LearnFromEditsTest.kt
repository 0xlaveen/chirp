package dev.chirp.android

import android.os.Looper
import android.os.UserManager
import android.view.inputmethod.EditorInfo
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.io.File
import java.time.Duration

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 37])
class LearnFromEditsTest {
    private val context get() = RuntimeEnvironment.getApplication()
    private val keys = SoftwareHistoryKeys()
    private val store by lazy { LearnedStore(context, keys) }
    private val inserted = "Deploy it to cooper netties today."
    private val edited = "Deploy it to Kubernetes today."
    @Before fun setup() { PrivateSession.set(false); DictationHistory(context).enable(); store.enabled = true; store.clear() }
    private fun observe(explicit: Boolean = false, app: String = "dev.example.chat") = store.observe(inserted, edited, inserted, app, explicit)
    @Test fun `span diff accepts only changes wholly inside our insertion`() {
        assertEquals(edited, EditRegion.edited("prefix $inserted suffix", "prefix $edited suffix", 7, inserted.length))
        assertNull(EditRegion.edited("prefix $inserted", "changed $edited", 7, inserted.length))
        assertNull(EditRegion.edited(inserted, "$inserted more", 0, inserted.length))
        assertNull(EditRegion.edited(inserted, "More $inserted", 0, inserted.length))
        assertNull(EditRegion.edited(inserted, edited, -1, inserted.length))
        assertNull(EditRegion.edited(inserted, edited, 1, inserted.length))
        assertEquals("🦆 $edited", EditRegion.edited("🦆 $inserted", "🦆 $edited", 0, inserted.length + 3))
    }
    @Test fun `fixtures distinguish vocabulary styles grammar and large rewrites`() {
        val term = EditCorrections.extract(inserted, edited).single()
        assertEquals("cooper netties", term.heard); assertEquals("Kubernetes", term.term)
        assertEquals("GitHub", EditCorrections.extract("Try github today.", "Try GitHub today.").single().term)
        assertTrue(EditCorrections.extract("Their cat.", "There cat.").isEmpty())
        assertTrue(EditCorrections.extract("hello friend", "Hello friend").isEmpty())
        assertTrue(EditCorrections.extract("NASA is ready.", "nASA is ready.").isEmpty())
        assertTrue(EditCorrections.extract("I will go", "i will go").isEmpty())
        assertTrue(EditCorrections.extract("one two three four five six seven eight", "Write a completely different message about many things").isEmpty())
        assertEquals(setOf(LearnedStyle.LOWERCASE, LearnedStyle.NO_PERIOD), EditCorrections.extract("Sounds good.", "sounds good").mapNotNull { it.style }.toSet())
        assertTrue(EditCorrections.extract("Wait...", "Wait..").isEmpty())
        assertTrue(EditCorrections.extract("one ".repeat(301), "two ".repeat(301)).isEmpty())
    }
    @Test fun `two separate edits activate a correction and undo suppresses relearning`() {
        assertTrue(observe().isEmpty()); assertEquals(LearnedState.LEARNING, store.all().single().state)
        assertEquals(1, observe().size); assertEquals(2, store.all().single().count)
        assertTrue(observe().isEmpty())
        val id = store.all().single().id
        store.set(id, LearnedState.OFF); observe(); assertTrue(store.payload("dev.example.chat").isEmpty)
        store.set(id, LearnedState.ACTIVE); assertFalse(store.payload(null).isEmpty)
        store.delete(id); assertTrue(store.all().isEmpty())
    }
    @Test fun `explicit teaching activates once terms are global and style is per package`() {
        assertEquals(1, observe(explicit = true).size)
        store.observe("Sounds good.", "sounds good", "sounds good", "dev.example.chat", explicit = true)
        val chat = store.payload("dev.example.chat")
        assertEquals(2, chat.style.size); assertEquals(1, chat.examples.size)
        val other = store.payload("dev.example.editor")
        assertEquals("Kubernetes", other.terms.single().term); assertTrue(other.style.isEmpty()); assertTrue(other.examples.isEmpty())
        store.reset("dev.example.chat"); assertTrue(store.all().isEmpty())
    }
    @Test fun `sealed store has a separate key and clear history leaves learning intact`() {
        observe(true)
        val file = File(context.filesDir, LearnedStore.FILE_NAME)
        val first = file.readBytes()
        listOf("Kubernetes", "cooper netties", "dev.example.chat", inserted).forEach { assertFalse(String(first, Charsets.ISO_8859_1).contains(it)) }
        assertEquals("Kubernetes", LearnedStore(context, keys).all().single().correction.term)
        DictationHistory(context).clear(); assertEquals(1, store.all().size)
        observe(); assertFalse(first.contentEquals(file.readBytes()))
        assertFalse(store.all().single().toString().contains("Kubernetes"))
        file.writeBytes(file.readBytes().apply { this[lastIndex] = (this[lastIndex].toInt() xor 1).toByte() })
        assertTrue(store.all().isEmpty()); assertFalse(file.exists())
        observe(true); keys.key = null; assertTrue(store.all().isEmpty()); assertFalse(file.exists())
    }
    @Test fun `learning history private session and locked storage gate both observation and sending`() {
        observe(true)
        store.enabled = false; assertTrue(observe().isEmpty()); assertTrue(store.payload(null).isEmpty)
        store.enabled = true; DictationHistory(context).disable(); assertTrue(observe().isEmpty()); assertTrue(store.payload(null).isEmpty)
        DictationHistory(context).enable(); PrivateSession.set(true); assertTrue(observe().isEmpty()); assertTrue(store.payload(null).isEmpty)
        PrivateSession.set(false)
        shadowOf(context.getSystemService(UserManager::class.java)).setUserUnlocked(false)
        assertTrue(store.all().isEmpty()); assertTrue(store.payload(null).isEmpty)
        shadowOf(context.getSystemService(UserManager::class.java)).setUserUnlocked(true)
        assertFalse(LearnedStore(context.createDeviceProtectedStorageContext(), keys).available)
        assertEquals(1, store.all().size)
    }
    @Test fun `store and protocol cap items terms heard variants examples and example length`() {
        repeat(205) { i -> store.observe("Try something today.", "Try Product$i today.", "x".repeat(400), "dev.example.chat", explicit = true) }
        assertEquals(200, store.all().size)
        assertEquals(100, store.payload(null).terms.size)
        repeat(6) { i -> store.observe("Try phrase$i today.", "Try SameProduct today.", inserted, "dev.example.chat", explicit = true) }
        assertEquals(4, store.payload(null).terms.first { it.term == "SameProduct" }.heard.size)
        store.observe("Sounds good.", "sounds good", "x".repeat(400), "dev.example.chat", explicit = true)
        assertEquals(300, store.payload("dev.example.chat").examples.single().said.length)
    }
    @Test fun `start learned is optional versioned bounded and round trips through JSON`() {
        val old = Protocol.start(true)
        assertEquals(old, Protocol.start(true, learned = LearnedPayload()))
        observe(true)
        val payload = store.payload(null)
        val wire = JSONObject(Protocol.start(true, learned = payload)).getJSONObject("learned")
        assertEquals(1, wire.getInt("v")); assertEquals("Kubernetes", wire.getJSONArray("terms").getJSONObject(0).getString("term"))
        assertEquals("Deploy it to Kubernetes today.", payload.apply(inserted))
        assertEquals("cooper nettiesville", payload.apply("cooper nettiesville"))
        val single = LearnedPayload(listOf(LearnedPayload.Term("Koi", listOf("coy"))))
        assertEquals("a coy smile", single.apply("a coy smile"))
        assertFalse(payload.toString().contains("Kubernetes"))
    }
    @Test fun `watch counts once per dictation ends at next start focus loss or sixty seconds`() {
        var field: String? = inserted
        var allowed = true
        val edits = mutableListOf<String>()
        val watcher = EditWatcher({ allowed }, { _, edit -> edits += edit })
        watcher.watch(inserted, 0) { field }
        field = "Deploy it to Kube today."
        watcher.sample(); field = edited; watcher.sample()
        assertTrue(edits.isEmpty())
        watcher.finish(); assertEquals(listOf(edited), edits)
        watcher.watch(inserted, 0) { inserted }
        watcher.cancel(); assertFalse(watcher.watching)
        field = inserted; watcher.watch(inserted, 0) { field }; field = edited; watcher.sample(); field = null; watcher.sample()
        assertFalse(watcher.watching); assertEquals(2, edits.size)
        field = inserted; watcher.watch(inserted, 0) { field }; field = edited
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(60))
        assertFalse(watcher.watching); assertEquals(3, edits.size)
        field = inserted; watcher.watch(inserted, 0) { field }; field = edited; allowed = false; watcher.finish()
        assertEquals(3, edits.size)
    }
    @Test fun `coordinator finishes each window before loading next sessions preferences`() {
        val learning = EditLearning(context, store, io = { it() })
        var field = inserted
        repeat(2) {
            field = inserted
            learning.watch(inserted, 0, inserted, "dev.example.chat") { field }
            field = edited
            learning.prepare("dev.example.chat") { payload ->
                if (it == 0) assertTrue(payload.isEmpty) else assertEquals("Kubernetes", payload.terms.single().term)
            }
        }
        assertEquals(2, store.all().single().count)
        assertFalse(learning.watcher.watching)
        PrivateSession.set(true)
        learning.prepare("dev.example.chat") { assertTrue(it.isEmpty) }
    }
    @Test fun `accessibility skips password no suggestions and no personalized learning fields`() {
        val node = android.view.accessibility.AccessibilityNodeInfo().apply {
            isFocused = true; isEditable = true; isEnabled = true; inputType = android.text.InputType.TYPE_CLASS_TEXT
        }
        shadowOf(node).setRefreshReturnValue(true)
        assertTrue(FocusedInsertion.learningAllowed(node))
        node.isPassword = true; assertFalse(FocusedInsertion.learningAllowed(node)); node.isPassword = false
        node.inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
        assertFalse(FocusedInsertion.learningAllowed(node))
        node.inputType = android.text.InputType.TYPE_CLASS_TEXT; node.isFocused = false
        assertFalse(FocusedInsertion.learningAllowed(node))
        assertTrue(FocusedInsertion.learningPrivateAllowed(node))
    }
    @Test fun `history keeps target package for teaching and reads older entries`() {
        val history = DictationHistory(context, SoftwareHistoryKeys())
        val entry = history.record(inserted, null, "Chat", EditorInfo().apply { inputType = 1; packageName = "dev.example.chat" })!!
        assertEquals("dev.example.chat", history.entries().single().packageName)
        history.usedRaw(entry.id)
        assertEquals("dev.example.chat", history.entries().single().packageName)
    }
}
