package dev.chirp.android

import dev.chirp.android.shell.AddToNoteResult
import dev.chirp.android.shell.addDictationToNote
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37])
class HistoryNotesTest {
    private fun add(notes: NotesSessions, text: String, destination: NotesIndexEntry? = null, newNote: Boolean = false) =
        runBlocking { addDictationToNote(notes, text, destination, saveAsNew = newNote) }

    @Test fun `an open stopped note receives history through its model before the next typed edit`() {
        val context = RuntimeEnvironment.getApplication()
        val notes = NotesSessions(context, SoftwareHistoryKeys())
        val rig = NotesModelRig(context, sessions = notes)
        val host = org.robolectric.Robolectric.buildActivity(androidx.activity.ComponentActivity::class.java).setup()
        NotesSessionHolder.model(host.get()) { rig.model }
        try {
            rig.model.edit(androidx.compose.ui.text.input.TextFieldValue("Meeting notes")); rig.model.keepSession()
            assertEquals(AddToNoteResult.Added(createdNote = false), add(notes, "History reminder"))
            assertEquals("Meeting notes\n\nHistory reminder", rig.model.field.text)
            rig.model.edit(androidx.compose.ui.text.input.TextFieldValue(rig.model.field.text + "\nLater edit"))
            rig.model.keepSession()
            assertEquals("Meeting notes\n\nHistory reminder\nLater edit", NotesDocument.fromJson(notes.open(rig.model.document.uid)!!.document).text)
        } finally { host.pause().stop().destroy() }
    }

    @Test fun `history also edits the loaded reader while another note records`() {
        val context = RuntimeEnvironment.getApplication()
        val notes = NotesSessions(context, SoftwareHistoryKeys())
        val live = NotesModelRig(context, sessions = notes)
        val host = org.robolectric.Robolectric.buildActivity(androidx.activity.ComponentActivity::class.java).setup()
        NotesSessionHolder.model(host.get()) { live.model }
        try {
            live.record().final("Live recording"); live.idle()
            val reader = NotesSessionHolder.reader(host.get())
            val other = NotesDocument().apply { userEdit(0, 0, "Reading notes"); name = "Earlier meeting" }
            assertTrue(notes.put(other.uid, other.toJson()))
            reader.recorder.restore(other, 0.0)
            val target = notes.entries().first { it.id == other.uid }
            assertEquals(AddToNoteResult.Added(createdNote = false), add(notes, "History reminder", target))
            assertEquals("Reading notes\n\nHistory reminder", reader.field.text)
            reader.edit(androidx.compose.ui.text.input.TextFieldValue(reader.field.text + "\nTyped later"))
            reader.keepSession()
            val saved = java.util.concurrent.CountDownLatch(1)
            NotesIo.run { saved.countDown() }
            assertTrue(saved.await(5, java.util.concurrent.TimeUnit.SECONDS))
            assertEquals("Reading notes\n\nHistory reminder\nTyped later", NotesDocument.fromJson(notes.open(other.uid)!!.document).text)
            assertFalse(live.model.document.text.contains("History reminder"))
            live.model.stop(); live.idle(); live.wire.final("End"); live.idle()
        } finally { host.pause().stop().destroy() }
    }

    @Test fun `a stale revision cannot overwrite a concurrent save or recreate a deleted note`() {
        val context = RuntimeEnvironment.getApplication()
        val keys = SoftwareHistoryKeys()
        // Two store instances, and a fixed clock: timestamps alone cannot detect these writes.
        val first = NotesSessions(context, keys, { 1_800_000_000_000L })
        val second = NotesSessions(context, keys, { 1_800_000_000_000L })
        val note = NotesDocument().apply { userEdit(0, 0, "Original") }
        assertTrue(first.put(note.uid, note.toJson()))
        val stale = first.open(note.uid)!!
        val update = NotesDocument.fromJson(stale.document).apply { userEdit(text.length, text.length, "\nConcurrent edit") }
        assertTrue(second.put(note.uid, update.toJson()))
        assertFalse(first.put(note.uid, stale.document, expectedRevision = stale.revision))
        assertEquals(update.text, NotesDocument.fromJson(first.open(note.uid)!!.document).text)
        val fresh = first.open(note.uid)!!
        assertTrue(first.put(note.uid, fresh.document, expectedRevision = fresh.revision))
        val beforeDelete = first.open(note.uid)!!
        assertTrue(second.trash(note.uid))
        assertFalse(first.put(note.uid, beforeDelete.document, expectedRevision = beforeDelete.revision))
        second.purge(note.uid)
        assertFalse(first.put(note.uid, beforeDelete.document, expectedRevision = beforeDelete.revision))
        assertNull(first.open(note.uid))
    }

    @Test fun `the destination is pinned and save as new leaves it untouched`() {
        val notes = NotesSessions(RuntimeEnvironment.getApplication(), SoftwareHistoryKeys())
        assertEquals(AddToNoteResult.Added(createdNote = true), add(notes, "First note"))
        val destination = notes.entries().single()
        assertEquals(AddToNoteResult.Added(createdNote = true), add(notes, "New separate note", newNote = true))
        assertEquals(2, notes.entries().size)
        assertEquals(AddToNoteResult.Added(createdNote = false), add(notes, "Appended to first", destination))
        assertEquals("First note\n\nAppended to first", NotesDocument.fromJson(notes.open(destination.id)!!.document).text)
        assertEquals("New separate note", notes.entries().first { it.id != destination.id }.title)
    }

    /** Exercise the same process-owned model the History tab must find while Notes is off screen. */
    private fun liveAppend(structure: Boolean) {
        val context = RuntimeEnvironment.getApplication()
        val notes = NotesSessions(context, SoftwareHistoryKeys())
        val rig = NotesModelRig(context, sessions = notes)
        val host = org.robolectric.Robolectric.buildActivity(androidx.activity.ComponentActivity::class.java).setup()
        NotesSessionHolder.model(host.get()) { rig.model }
        try {
            rig.model.edit(androidx.compose.ui.text.input.TextFieldValue("Meeting notes"))
            rig.model.rename("Team meeting")
            rig.record().final("first spoken segment"); rig.idle()
            assertEquals(AddToNoteResult.Added(createdNote = false), add(notes, "History reminder"))
            if (structure) rig.api.answers += NotesStructureResponse("## Next steps\n- Send the draft", true)
            rig.model.stop(); rig.idle(); rig.wire.final("send the draft"); rig.idle()
            assertEquals(NotesRecorder.State.STOPPED, rig.model.state)
            rig.model.clear()
            rig.model.open(notes.entries().single().id); rig.idle()
            assertTrue("History text must survive the next commit, Stop and reopen", rig.model.document.text.contains("History reminder"))
            if (structure) assertTrue("the AI answer really applied", rig.model.document.text.contains("## Next steps"))
            assertEquals("Team meeting", notes.entries().single().title)
        } finally { host.pause().stop().destroy() }
    }

    @Test fun `history append survives a live segment commit and stop`() = liveAppend(structure = false)

    @Test fun `history append survives an AI structure update and stop`() = liveAppend(structure = true)

    @Test fun `history creates and appends notes while respecting the opt out`() {
        val context = RuntimeEnvironment.getApplication()
        val off = NotesSessions(context, SoftwareHistoryKeys()).also { it.disable() }
        val result = add(off, "Meet at the pier")
        assertEquals(AddToNoteResult.Off, result)
        val on = NotesSessions(context, SoftwareHistoryKeys()).also { it.enable() }
        val created = add(on, "First line")
        assertEquals(AddToNoteResult.Added(createdNote = true), created)
        val appended = add(on, "Second line")
        assertEquals(AddToNoteResult.Added(createdNote = false), appended)
        assertEquals(1, on.entries().size)
        val doc = NotesDocument.fromJson(on.open(on.entries().single().id)!!.document)
        assertEquals("First line\n\nSecond line", doc.text)
    }

    @Test fun `appending preserves the note name and recording duration`() {
        val notes = NotesSessions(RuntimeEnvironment.getApplication(), SoftwareHistoryKeys())
        val note = NotesDocument().apply { userEdit(0, 0, "Meeting notes"); name = "Team meeting" }
        assertTrue(notes.put(note.uid, note.toJson().put("elapsed", 45.5)))
        assertEquals(AddToNoteResult.Added(createdNote = false), add(notes, "Follow up on Friday"))
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
        assertEquals(AddToNoteResult.Added(createdNote = true, unreadableNote = true), add(notes, "Follow up on Friday"))
        assertFalse(file.exists())
        assertTrue(java.io.File(context.filesDir, "notes/quarantine").listFiles().orEmpty().isNotEmpty())
        assertNotEquals(note.uid, notes.entries().single().id)
        assertEquals("Follow up on Friday", notes.entries().single().title)
    }
}
