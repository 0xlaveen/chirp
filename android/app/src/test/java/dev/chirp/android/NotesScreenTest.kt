package dev.chirp.android

import android.Manifest
import android.app.Notification
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.os.Looper
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.lifecycle.viewmodel.initializer
import java.io.File
import org.junit.After
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** Structure calls answered from a list; reorganize answers "already tidy". Blocking, like the HTTP client. */
internal class ScriptedNotesApi : NotesApi {
    val structures = mutableListOf<NotesStructureRequest>()
    val answers = ArrayDeque<NotesStructureResponse>()
    override fun structure(request: NotesStructureRequest): NotesStructureResponse {
        structures += request; return answers.removeFirstOrNull() ?: NotesStructureResponse.failed("timeout")
    }
    override fun reorganize(request: NotesReorganizeRequest) = NotesReorganizeResponse(request.notes, true, false)
}

internal class NotesModelRig(context: Context, health: Health? = notesMac, paired: Boolean = true) {
    val wires = mutableListOf<NotesWire>()
    val captures = mutableListOf<FakeNotesCapture>()
    val foreground = mutableListOf<Boolean>()
    val api = ScriptedNotesApi()
    val model: NotesModel
    init {
        val store = SettingsStore(context)
        if (health != null) store.health = health
        model = NotesModel(context, store,
            captureFactory = { frame, _, done -> FakeNotesCapture(frame, done).also { captures += it } },
            transportFactory = { _, _, event, failure -> NotesWire(event, failure).also { wires += it } },
            apiFactory = { _, _ -> api }, micGranted = { true },
            pairing = { if (paired) Pairing.from("https://mac.example.test/chirp", "synthetic") else null },
            fetchHealth = { _, _ -> null }, tailscale = TailscalePromptTest.FakeTailscale(),
            foreground = { foreground += it }, io = { it() })
    }
    val wire get() = wires.last()
    fun idle() = shadowOf(Looper.getMainLooper()).idle()
    /** One 45 s segment from Record, cut to a fresh socket; returns the finished segment's socket. */
    fun record(): NotesWire {
        model.toggle(); wire.ready(); idle()
        repeat(1125) { model.recorder.handleFrame(ByteArray(1280), 0.1f) }
        wire.ready(); idle()
        return wires[wires.size - 2]
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 37])
class NotesModelTest {
    private val context get() = RuntimeEnvironment.getApplication()

    @Test fun `recording runs the foreground service from Record until the notes are final`() {
        val rig = NotesModelRig(context)
        rig.api.answers += NotesStructureResponse("## Plan\n- Ship it", true)
        val first = rig.record()
        assertEquals(listOf(true), rig.foreground)
        assertEquals("Listening…", rig.model.status)
        first.final("we will ship it"); rig.idle()
        assertEquals("## Plan\n- Ship it", rig.model.field.text)
        rig.model.toggle(); rig.idle()
        assertEquals(listOf(true), rig.foreground)
        rig.wire.final("and that is all"); rig.idle()
        assertEquals(NotesRecorder.State.STOPPED, rig.model.state)
        assertEquals(listOf(true, false), rig.foreground)
        assertTrue(rig.model.export().contains("**[00:00:45]** and that is all"))
    }

    @Test fun `an AI update keeps the caret where the user is typing`() {
        val rig = NotesModelRig(context)
        rig.model.edit(TextFieldValue("My line", TextRange(2)))
        rig.model.focused = true
        rig.api.answers += NotesStructureResponse("- Point one", true)
        rig.record().final("point one"); rig.idle()
        assertEquals("My line\n\n- Point one", rig.model.field.text)
        assertEquals(TextRange(2), rig.model.field.selection)
        // Typing inside the AI tail makes it the user's: a later answer starts a new tail after it.
        val end = rig.model.field.text.length
        rig.model.edit(TextFieldValue(rig.model.field.text + "!", TextRange(end + 1)))
        assertEquals(rig.model.document.text.length, rig.model.document.tailStart)
    }

    @Test fun `leaving the screen stops a recording and the service with it`() {
        val rig = NotesModelRig(context)
        rig.record()
        val store = androidx.lifecycle.ViewModelStore()
        androidx.lifecycle.ViewModelProvider(store, androidx.lifecycle.viewmodel.viewModelFactory {
            initializer { rig.model } })[NotesModel::class.java]
        store.clear()
        assertEquals(listOf(true, false), rig.foreground)
        assertTrue(rig.wires.all { it.closed })
        assertTrue(rig.captures.single().stopped)
    }

    @Test fun `without a pairing Record explains instead of starting`() {
        val rig = NotesModelRig(context, paired = false)
        rig.model.toggle()
        assertEquals("Pair your Mac in Chirp setup", rig.model.status)
        assertEquals(DictationAction.PAIR, DictationAction.forStatus(rig.model.status))
        assertTrue(rig.wires.isEmpty())
    }

    @Test fun `structuring that would leave the Mac is off until the user turns it on`() {
        val rig = NotesModelRig(context, health = notesMac.copy(correctionLeavesMachine = true, correctionHost = "helper.example.test"))
        assertFalse(rig.model.structureEnabled)
        assertEquals("helper.example.test", rig.model.structureHost)
        assertEquals(Structuring.Off(StructuringOff.DISABLED), rig.model.structuring)
        rig.model.setStructure(true)
        assertEquals(Structuring.Idle, rig.model.structuring)
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 37])
class NotesActivityTest {
    class TestNotes : NotesActivity() {
        internal lateinit var rig: NotesModelRig
        override val tailscale: TailscaleControl = TailscalePromptTest.FakeTailscale()
        override fun createModel(): NotesModel { rig = NotesModelRig(applicationContext); return rig.model }
    }
    private val app get() = RuntimeEnvironment.getApplication()
    private val controller = Robolectric.buildActivity(TestNotes::class.java)
    private lateinit var activity: TestNotes
    private fun open() { activity = controller.setup().get() }
    @After fun tearDown() { if (!activity.isDestroyed) controller.pause().stop().destroy() }

    @Test fun `the notification's Stop finishes the recording, and copy exports Markdown marked sensitive`() {
        shadowOf(app).grantPermissions(Manifest.permission.RECORD_AUDIO, Manifest.permission.POST_NOTIFICATIONS)
        open()
        activity.record()
        activity.rig.wire.ready(); activity.rig.idle()
        assertTrue(activity.model.recording)
        controller.newIntent(NotesActivity.intent(app).setAction(NotesService.ACTION_STOP))
        activity.rig.idle()
        assertEquals(NotesRecorder.State.STOPPING, activity.model.state)
        activity.rig.wire.final("synthetic words"); activity.rig.idle()
        assertEquals(NotesRecorder.State.STOPPED, activity.model.state)
        activity.copy()
        val clip = app.getSystemService(ClipboardManager::class.java).primaryClip!!
        assertTrue(clip.getItemAt(0).text.toString().contains("## Transcript\n\n**[00:00:00]** synthetic words"))
        assertTrue(clip.description.extras!!.getBoolean("android.content.extra.IS_SENSITIVE"))
    }

    @Test fun `back while recording keeps it running in the background`() {
        shadowOf(app).grantPermissions(Manifest.permission.RECORD_AUDIO, Manifest.permission.POST_NOTIFICATIONS)
        open(); activity.record(); activity.rig.wire.ready(); activity.rig.idle()
        activity.leave(false)
        assertFalse(activity.isFinishing)
        assertTrue(activity.model.recording)
    }

    @Test fun `record asks for the microphone first`() {
        shadowOf(app).denyPermissions(Manifest.permission.RECORD_AUDIO)
        open(); activity.record()
        assertTrue(activity.rig.wires.isEmpty())
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37])
class NotesServiceTest {
    @Test fun `the service is a microphone foreground service whose notification has no notes text`() {
        val app = RuntimeEnvironment.getApplication()
        val service = Robolectric.buildService(NotesService::class.java).create().startCommand(0, 1).get()
        val shadow = shadowOf(service)
        assertFalse(shadow.isStoppedBySelf)
        assertEquals(ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE, service.foregroundServiceType)
        val notification = shadow.lastForegroundNotification!!
        assertEquals("Chirp Notes is recording", notification.extras.getString(Notification.EXTRA_TITLE))
        assertNull(notification.extras.getCharSequence(Notification.EXTRA_TEXT))
        assertTrue(notification.flags and Notification.FLAG_ONGOING_EVENT != 0)
        val stop = notification.actions.single()
        assertEquals("Stop", stop.title)
        val intent = shadowOf(stop.actionIntent).savedIntent
        assertEquals(NotesService.ACTION_STOP, intent.action)
        assertEquals(NotesActivity::class.java.name, intent.component?.className)
        assertEquals(NotesActivity::class.java.name, shadowOf(notification.contentIntent).savedIntent.component?.className)
        NotesService.set(app, true)
        assertEquals(NotesService::class.java.name, shadowOf(app).nextStartedService.component?.className)
        NotesService.set(app, false)
        assertEquals(NotesService::class.java.name, shadowOf(app).nextStoppedService.component?.className)
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class NotesRenderTest {
    @get:Rule val compose = createComposeRule()

    private fun render(width: String) {
        val output = File(System.getProperty("chirp.screenshots")).apply { mkdirs() }
        val rig = NotesModelRig(RuntimeEnvironment.getApplication())
        val dark = mutableStateOf(false)
        compose.setContent { ChirpTheme(dark.value) { NotesScreen(rig.model, rig.model::toggle, {}, {}, {}, {}) } }
        fun shot(name: String) {
            compose.waitForIdle()
            val bitmap = compose.onRoot().captureToImage().asAndroidBitmap()
            File(output, "notes-$width-$name-${if (dark.value) "dark" else "light"}.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        }
        val notes = NotesStructureResponse("## Launch plan\n- Beta goes to ten design partners first\n- [ ] Draft the invite email\n" +
            "- **Decision:** Ship the beta on Friday\n- **Question:** Do we need a waitlist?", true)
        for (night in listOf(false, true)) {
            rig.api.answers += notes
            compose.runOnIdle { dark.value = night }
            shot("idle")
            compose.runOnIdle {
                rig.record().final("Synthetic example: the beta goes to ten design partners first, and we ship it on Friday.")
                rig.wire.partial("Someone should draft the invite email")
            }
            shot("recording")
            compose.runOnIdle { rig.model.recorder.cancel(); rig.model.clear() }
        }
    }

    @Test @Config(qualifiers = "w411dp-h891dp-mdpi") fun `render notes on the cover screen in light and dark`() = render("cover")
    @Test @Config(qualifiers = "w832dp-h749dp-land-mdpi") fun `render notes side by side on the inner screen in light and dark`() = render("inner")
}
