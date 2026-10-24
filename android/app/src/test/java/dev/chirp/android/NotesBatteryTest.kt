package dev.chirp.android

import android.app.Notification
import android.app.NotificationManager
import java.io.File
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** Battery saver: with the screen off only phone-side screen work stops; recording and the Mac's structuring go on. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 37])
class NotesBatteryTest {
    private val context get() = RuntimeEnvironment.getApplication()
    private fun posted() = shadowOf(context.getSystemService(NotificationManager::class.java)).getNotification(NotesService.ID)

    @Test fun `screen off skips editor updates, partials, the meter and the clock, but structuring runs and the screen catches up`() {
        val rig = NotesModelRig(context, sessions = libraryOff(context))
        rig.api.answers += NotesStructureResponse("## Plan\n- Ship it", true)
        val first = rig.record()
        rig.model.visible(false)
        assertTrue(rig.model.quiet); assertTrue(rig.model.recorder.quiet)
        assertEquals("Battery saver", posted().extras.getCharSequence(Notification.EXTRA_SUB_TEXT))
        first.final("we will ship it"); rig.idle()
        assertEquals("structuring still runs with the screen off", 1, rig.api.structures.size)
        assertEquals("## Plan\n- Ship it", rig.model.recorder.document.text)
        assertEquals("the editor waits", "", rig.model.field.text)
        assertTrue("the recovery copy keeps up", File(context.noBackupFilesDir, NotesJournal.FILE_NAME).exists())
        rig.wire.partial("next words"); rig.idle()
        assertEquals("partials are not joined while off", "", rig.model.recorder.document.livePartial)
        val shown = rig.model.elapsed
        repeat(250) { rig.model.recorder.handleFrame(ByteArray(1280), 0.1f) }
        assertEquals(shown, rig.model.elapsed, 1e-9)
        assertEquals(55.0, rig.model.recordedSeconds, 1e-9)

        rig.model.visible(true)
        assertFalse(rig.model.quiet)
        assertEquals("## Plan\n- Ship it", rig.model.field.text)
        assertTrue(rig.model.hearing.contains("next words"))
        assertEquals(55.0, rig.model.elapsed, 1e-9)
        assertNull(posted().extras.getCharSequence(Notification.EXTRA_SUB_TEXT))

        rig.model.visible(false)
        rig.model.toggle(); rig.idle()
        rig.wires.forEach { it.final("more words") }; rig.idle()
        assertEquals(NotesRecorder.State.STOPPED, rig.model.recorder.state)
        val timing = NotesTimingLog(context).entries().single()
        assertTrue(timing.saver)
        assertEquals(55, timing.recordedS)
        assertEquals(2, timing.segments)
        assertTrue("skipped ${timing.skipped}", timing.skipped > 0)
        assertTrue(timing.passes >= 1)
        assertFalse(NotesTimingLog(context).summary().contains("words"))
    }

    @Test fun `with the saver off the screen keeps updating out of sight`() {
        SettingsStore(context).notesBatterySaver = false
        val rig = NotesModelRig(context)
        rig.api.answers += NotesStructureResponse("- Ship it", true)
        val first = rig.record()
        rig.model.visible(false)
        assertFalse(rig.model.quiet)
        first.final("we will ship it"); rig.idle()
        assertEquals("- Ship it", rig.model.field.text)
    }

    @Test fun `timings are numbers only and round-trip`() {
        val timing = NotesTiming(1_800_000_000_000L, 3120, 2400, 70, 1, 64, 210, 18400, true)
        assertEquals(listOf(timing), NotesTimingLog.decode(NotesTimingLog.encode(listOf(timing))))
        val failed = timing.copy(problem = "structure: auth")
        assertEquals(listOf(failed), NotesTimingLog.decode(NotesTimingLog.encode(listOf(failed))))
        assertTrue(NotesTimingLog(context).also { it.record(failed) }.summary().endsWith(" · last problem: structure: auth"))
        NotesTimingLog(context).clear()
        val log = NotesTimingLog(context)
        repeat(NotesTimingLog.MAX + 3) { log.record(timing.copy(time = it.toLong())) }
        assertEquals(NotesTimingLog.MAX, log.entries().size)
        assertTrue(log.summary().startsWith("52 min recorded (40 min screen off), 70 segments, 1 gaps"))
        assertTrue(DiagnosticsReport.text(context).contains("Notes sessions"))
        DiagnosticsReport.clearTimings(context)
        assertTrue(log.entries().isEmpty())
    }
}
