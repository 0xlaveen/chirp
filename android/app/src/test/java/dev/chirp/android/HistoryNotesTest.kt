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
class HistoryNotesTest {
    @Test fun `history creates and appends notes while respecting the opt out`() {
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

    @Test fun `appending preserves the note name and recording duration`() {
        val notes = NotesSessions(RuntimeEnvironment.getApplication(), SoftwareHistoryKeys())
        val note = NotesDocument().apply { userEdit(0, 0, "Meeting notes"); name = "Team meeting" }
        assertTrue(notes.put(note.uid, note.toJson().put("elapsed", 45.5)))
        assertEquals(AddToNoteResult.Added(createdNote = false), addDictationToNote(notes, "Follow up on Friday"))
        val record = notes.open(note.uid)!!
        assertEquals(45.5, record.entry.duration, 0.0)
        assertEquals("Team meeting", record.entry.title)
        assertEquals("Meeting notes\n\nFollow up on Friday", NotesDocument.fromJson(record.document).text)
    }

    @Test fun `an unreadable note is quarantined instead of replaced with the appended text`() {
        val context = RuntimeEnvironment.getApplication()
        val notes = NotesSessions(context, SoftwareHistoryKeys())
        val note = NotesDocument().apply { userEdit(0, 0, "Meeting notes") }
        assertTrue(notes.put(note.uid, note.toJson()))
        val file = java.io.File(context.filesDir, "notes/${note.uid}.bin")
        assertTrue(file.exists())
        file.writeText("broken ciphertext")
        assertEquals(AddToNoteResult.Added(createdNote = true, unreadableNote = true), addDictationToNote(notes, "Follow up on Friday"))
        assertFalse(file.exists())
        assertTrue(java.io.File(context.filesDir, "notes/quarantine").listFiles().orEmpty().isNotEmpty())
        assertNotEquals(note.uid, notes.entries().single().id)
        assertEquals("Follow up on Friday", notes.entries().single().title)
    }
}
