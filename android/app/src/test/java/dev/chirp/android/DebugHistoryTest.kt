package dev.chirp.android

import dev.chirp.android.shell.AddToNoteResult
import dev.chirp.android.shell.addDictationToNote
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37])
class DebugHistoryTest {
    @Test fun debugOff() {
        val context = RuntimeEnvironment.getApplication()
        val off = NotesSessions(context, SoftwareHistoryKeys()).also { it.disable() }
        val result = addDictationToNote(off, "Meet at the pier")
        assertEquals(AddToNoteResult.Off, result)
        val on = NotesSessions(context, SoftwareHistoryKeys()).also { it.enable() }
        val created = addDictationToNote(on, "First line")
        assertEquals(AddToNoteResult.Added(createdNote = true), created)
        val appended = addDictationToNote(on, "Second line")
        assertEquals(AddToNoteResult.Added(createdNote = false), appended)
        assertEquals(1, on.entries().size)
        val doc = NotesDocument.fromJson(on.open(on.entries().single().id)!!.document)
        assertEquals("First line\n\nSecond line", doc.text)
    }
}
