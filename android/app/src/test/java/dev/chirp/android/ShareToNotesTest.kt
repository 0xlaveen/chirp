package dev.chirp.android

import android.content.Intent
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37])
class ShareToNotesTest {
    @get:Rule val compose = createComposeRule()
    class TestShare : ShareToNotesActivity() {
        internal val notes by lazy { NotesSessions(applicationContext, SoftwareHistoryKeys()) }
        override fun library() = notes
    }
    private fun intent(text: String = "Synthetic shared paragraph", type: String = "text/plain") =
        Intent(Intent.ACTION_SEND).setType(type).putExtra(Intent.EXTRA_TEXT, text)
    @Test fun `save creates exactly one sealed library note with subject title and original text`() {
        val controller = Robolectric.buildActivity(TestShare::class.java, intent().putExtra(Intent.EXTRA_SUBJECT, "Synthetic title")).setup()
        val activity = controller.get()
        compose.onNodeWithText("Save as new note").performClick()
        compose.waitUntil(10_000) { org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle(); activity.isFinishing }
        val row = activity.notes.entries().single()
        assertEquals("Synthetic title", row.title)
        assertEquals("Synthetic shared paragraph", activity.notes.open(row.id)!!.document.getString("text"))
        assertNull(org.robolectric.Shadows.shadowOf(activity).nextStartedActivity)
        controller.pause().stop().destroy()
    }
    @Test fun `oversize unsupported and blank shares cannot save`() {
        for (input in listOf(intent("a".repeat(100_001)), intent(type = "image/png"), intent(" "))) {
            val controller = Robolectric.buildActivity(TestShare::class.java, input).setup()
            val activity = controller.get()
            compose.onNodeWithText("Save as new note").assertIsNotEnabled()
            activity.save(false); assertTrue(activity.notes.entries().isEmpty())
            controller.pause().stop().destroy()
        }
    }
    @Test fun `append eligibility is recording or paused only`() {
        val session = object : NotesControls.Session {
            var current = NotesRecorder.State.RECORDING
            override val state get() = current
            override val recordedSeconds = 0.0
            override val quiet = false
            override val commanding: Boolean? = null
            override fun pause() {} override fun resume() {} override fun stop() {} override fun command() {}
        }
        for (state in NotesRecorder.State.entries) {
            session.current = state
            assertEquals(state == NotesRecorder.State.RECORDING || state == NotesRecorder.State.PAUSED, ShareToNotesActivity.canAppend(session))
        }
    }
    @Test fun `share appends as user text to the same live note and refuses a replacement`() {
        val app = org.robolectric.RuntimeEnvironment.getApplication()
        val rig = NotesModelRig(app)
        rig.model.toggle(); rig.wire.ready(); rig.idle()
        rig.model.edit(androidx.compose.ui.text.input.TextFieldValue("Existing user text"))
        val controller = Robolectric.buildActivity(TestShare::class.java, intent()).setup()
        compose.onNodeWithText("Add to", substring = true).assertExists()
        controller.get().save(true)
        assertEquals("Existing user text\n\nSynthetic shared paragraph", rig.model.document.text)
        assertTrue(controller.get().isFinishing)
        controller.pause().stop().destroy()
        rig.model.pause(); rig.idle()
        assertTrue(rig.model.appendShared("Paused user edit"))
        assertTrue(rig.model.document.text.endsWith("Paused user edit"))
        val stale = Robolectric.buildActivity(TestShare::class.java, intent("Never append here")).setup()
        rig.model.stop(); rig.idle()
        val replacement = NotesModelRig(app)
        replacement.model.toggle(); replacement.wire.ready(); replacement.idle()
        stale.get().save(true)
        assertFalse(replacement.model.document.text.contains("Never append"))
        assertFalse(stale.get().isFinishing)
        compose.onNodeWithText("That note has stopped.", substring = true).assertExists()
        stale.pause().stop().destroy()
        replacement.model.stop(); replacement.idle()
        NotesControls.release(app, replacement.model)
    }
    @Test fun `first nonblank line becomes title and cancel creates nothing`() {
        val controller = Robolectric.buildActivity(TestShare::class.java, intent("\nSynthetic first line\nSecond line")).setup()
        val activity = controller.get(); activity.save(false)
        compose.waitUntil(10_000) { org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle(); activity.isFinishing }
        assertEquals("Synthetic first line", activity.notes.entries().single().title)
        controller.pause().stop().destroy()
    }
}
