package dev.chirp.android

import java.io.File
import java.util.Locale
import java.util.TimeZone
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/** Title, snippet, to-do count and capture boundaries: what a library row and a continued note are made of. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 37])
class NotesDocumentLibraryTest {
    private val utc = TimeZone.getTimeZone("UTC")
    private fun doc(text: String, name: String? = null) = NotesDocument(1_792_840_000_000L, text).also { it.name = name }

    @Test fun `the title is a rename first, then the first heading, then the first heading, then the first line, then the date`() {
        assertEquals("Mine", doc("# Heading\nbody", name = "Mine").libraryTitle(utc, Locale.US))
        assertEquals("Heading", doc("intro line\n## Heading\nbody").libraryTitle(utc, Locale.US))
        assertEquals("a first line", doc("\n\n- a **first** line\nmore").libraryTitle(utc, Locale.US))
        assertEquals("Note, 24 October", doc("").libraryTitle(utc, Locale.US))
        assertEquals("Note, 24 October", doc("_(nothing yet)_\n---").libraryTitle(utc, Locale.US))
        assertEquals("a blank rename is no rename", "Heading", doc("# Heading", name = "  ").libraryTitle(utc, Locale.US))
    }

    @Test fun `snippet skips the title line and the markers, and open to-dos count unchecked boxes only`() {
        val text = "# Plan\nWe will ship it.\n- [ ] write docs\n- [x] done thing\n  * [ ] nested\n1. numbered"
        val d = doc(text)
        assertEquals("We will ship it. write docs done thing nested numbered", d.snippet)
        assertEquals(2, d.openTodos)
        assertEquals("a renamed note keeps every line in the snippet", "Plan We will ship it. write docs done thing nested numbered", doc(text, name = "Mine").snippet)
        assertTrue(doc("x".repeat(500) + " tail").snippet.length <= NotesDocument.MAX_SNIPPET + 1)
        val spoken = doc("").apply { append(NotesSegment(0, 0.0, "only the transcript so far")) }
        assertEquals("only the transcript so far", spoken.snippet)
    }

    @Test fun `a blank note nobody named is untouched, and anything else is not`() {
        assertTrue(doc("").untouched)
        assertTrue(doc("  \n").untouched)
        assertFalse(doc("", name = "Ideas").untouched)
        assertFalse(doc("words").untouched)
        assertFalse(doc("").apply { append(NotesSegment(0, 0.0, "spoken")) }.untouched)
    }

    @Test fun `capture boundaries and kept-audio metadata survive the round trip and show as a quiet divider`() {
        val d = doc("notes")
        d.append(NotesSegment(0, 0.0, "first part")); d.append(NotesSegment(1, 20.0, "second part"))
        d.addBoundary(30.0, 1_792_841_000_000L)
        d.append(NotesSegment(2, 31.0, "after the break"))
        d.addClip(NotesAudioClip(1, 20.0, 9.5, 16000, 3000))
        val back = NotesDocument.fromJson(d.toJson())
        assertEquals(listOf(NotesBoundary(30.0, 1_792_841_000_000L)), back.boundaries)
        assertEquals(listOf(NotesAudioClip(1, 20.0, 9.5, 16000, 3000)), back.audio)
        val lines = back.transcriptLines(zone = utc)
        assertEquals(4, lines.size)
        assertTrue(lines[2].startsWith("_Continued · Oct 24, ") && lines[2].endsWith("M_"))
        assertTrue(lines[3].contains("after the break"))
        assertEquals("a note without boundaries is unchanged", 1, doc("").apply { append(NotesSegment(0, 0.0, "x")) }.transcriptLines().size)
    }

    @Test fun `a late structure answer is ignored once the open note changed, by document and by generation`() {
        val a = doc("")
        a.append(NotesSegment(0, 0.0, "hello there"))
        val request = a.nextStructureRequest()!!
        val answer = NotesStructureResponse("## Greeting\n- hello", true)

        // The same note reopened from the library is a different document: the answer made for the first is not applied.
        val reopened = NotesDocument.fromJson(a.toJson())
        val before = reopened.text
        assertNull(reopened.apply(answer, request))
        assertEquals(before, reopened.text)
        assertNotEquals(a.id, reopened.id)

        // The same document, but the tail was claimed since the request: also ignored.
        a.freezeAll()
        val settled = a.text
        assertNull(a.apply(answer, request))
        assertEquals(settled, a.text)
    }
}

/** The model on the library: autosave, open by id, continue recording, trash, recovered notes and kept audio. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 37])
class NotesLibraryModelTest {
    private val context get() = RuntimeEnvironment.getApplication()
    private val dir get() = File(context.filesDir, NotesSessions.DIR)

    private fun stop(rig: NotesModelRig) { rig.model.toggle(); rig.idle(); rig.wire.final("and the rest"); rig.idle() }

    @Test fun `a note saves itself with no Save step, and a blank untouched note is never kept`() {
        val sessions = NotesSessions(context, SoftwareHistoryKeys())
        val rig = NotesModelRig(context, sessions = sessions)
        rig.model.toggle(); rig.wire.ready(); rig.idle()
        assertTrue("recording but nothing said yet: nothing to keep", sessions.entries().isEmpty())
        rig.model.toggle(); rig.idle()
        rig.model.keepSession(); rig.idle()
        assertTrue(sessions.entries().isEmpty())

        val second = NotesModelRig(context, sessions = sessions)
        second.record().final("synthetic plan words"); second.idle()
        val live = sessions.entries().single()
        assertEquals("kept while it is still recording", second.model.document.uid, live.id)
        assertFalse("the library has it, so the recovery copy stands down", File(context.noBackupFilesDir, NotesJournal.FILE_NAME).exists())
        second.model.rename("Weekly sync")
        stop(second)
        assertEquals(NotesRecorder.State.STOPPED, second.model.state)
        assertFalse(second.model.dirty)
        val kept = sessions.entries().single()
        assertEquals("Weekly sync", kept.title)
        assertEquals(45.0, kept.duration, 1e-9)
        assertEquals(listOf("synthetic plan words", "and the rest"), sessions.open(kept.id)!!.document.let { d -> (0 until 2).map { d.getJSONArray("segments").getJSONObject(it).getString("text") } })
    }

    @Test fun `open by id loads another note in place, and the previous one is kept first`() {
        val sessions = NotesSessions(context, SoftwareHistoryKeys())
        sessions.put("other", noteJson("# Other note\nwords", elapsed = 90.0))
        val rig = NotesModelRig(context, sessions = sessions)
        rig.record().final("synthetic first"); rig.idle(); stop(rig)
        val first = rig.model.document.uid; val firstId = rig.model.document.id
        rig.model.open("other"); rig.idle()
        assertNotEquals(firstId, rig.model.document.id)
        assertEquals("other", rig.model.document.uid)
        assertEquals("# Other note\nwords", rig.model.field.text)
        assertEquals(90.0, rig.model.elapsed, 1e-9)
        assertEquals(setOf(first, "other"), sessions.entries().map { it.id }.toSet())
        rig.model.open("missing"); rig.idle()
        assertEquals("a note that is gone leaves the open one alone", "other", rig.model.document.uid)
    }

    @Test fun `continue recording adds a boundary and carries on from the stored audio clock`() {
        val sessions = NotesSessions(context, SoftwareHistoryKeys())
        val rig = NotesModelRig(context, sessions = sessions)
        rig.record().final("synthetic first part"); rig.idle(); stop(rig)
        val id = rig.model.document.uid
        rig.model.clear()
        assertFalse(rig.model.hasContent)

        assertTrue(rig.model.continueRecording(id)); rig.idle()
        assertEquals(id, rig.model.document.uid)
        assertEquals(NotesRecorder.State.STARTING, rig.model.state)
        assertEquals(1, rig.model.document.boundaries.size)
        assertEquals(45.0, rig.model.document.boundaries.single().offset, 1e-9)
        rig.wire.ready(); rig.idle()
        repeat(250) { rig.model.recorder.handleFrame(ByteArray(1280), 0.1f) }
        assertEquals("the clock goes on", 55.0, rig.model.recordedSeconds, 1e-9)
        rig.wire.final("synthetic second part"); rig.model.toggle(); rig.idle(); rig.wire.final("tail"); rig.idle()
        val segments = rig.model.document.segments
        assertEquals(45.0, segments.first { it.text == "synthetic second part" }.offset, 1e-9)
        val saved = NotesDocument.fromJson(sessions.open(id)!!.document)
        assertEquals(1, saved.boundaries.size)
        assertEquals(1, sessions.entries().size)
        assertTrue(saved.transcriptLines().any { it.startsWith("_Continued · ") })
    }

    @Test fun `continue while another note records offers stop-and-continue, which stops it first`() {
        val sessions = NotesSessions(context, SoftwareHistoryKeys())
        sessions.put("older", noteJson("# Older\nwords", elapsed = 30.0))
        val rig = NotesModelRig(context, sessions = sessions)
        rig.record().final("synthetic live words"); rig.idle()
        val recording = rig.model.document.uid
        assertFalse("not unless asked", rig.model.continueRecording("older"))
        assertEquals(recording, rig.model.document.uid)
        assertFalse("a recording note cannot be deleted", rig.model.trash(recording))
        assertTrue(rig.model.continueRecording("older", stopCurrent = true))
        rig.idle(); rig.wire.final("finishing words"); rig.idle()
        assertEquals("older", rig.model.document.uid)
        assertEquals(NotesRecorder.State.STARTING, rig.model.state)
        assertTrue("the first note was kept as it stopped", sessions.entries().any { it.id == recording })
    }

    @Test fun `delete moves a stopped note to Recently Deleted, and it can be restored`() {
        val sessions = NotesSessions(context, SoftwareHistoryKeys())
        val rig = NotesModelRig(context, sessions = sessions)
        rig.record().final("synthetic words"); rig.idle(); stop(rig)
        val id = rig.model.document.uid
        assertTrue(rig.model.trash(id)); rig.idle()
        assertFalse(rig.model.hasContent)
        assertTrue(sessions.entries().isEmpty())
        assertEquals(listOf(id), sessions.trashed().map { it.id })
        assertTrue(sessions.restore(id))
        assertEquals(listOf(id), sessions.entries().map { it.id })
    }

    @Test fun `with the library off nothing is kept and the recovery copy still guards the unsaved notes`() {
        val sessions = NotesSessions(context, SoftwareHistoryKeys()).apply { disable() }
        val rig = NotesModelRig(context, sessions = sessions)
        rig.record().final("synthetic words"); rig.idle(); stop(rig)
        assertFalse(rig.model.keeps)
        assertTrue(rig.model.dirty)
        assertTrue(sessions.entries().isEmpty())
        assertTrue(File(context.noBackupFilesDir, NotesJournal.FILE_NAME).exists())
    }

    @Test fun `a recovered session becomes a library note marked recovered`() {
        val keys = SoftwareHistoryKeys()
        val first = NotesModelRig(context, keys = keys, sessions = NotesSessions(context, SoftwareHistoryKeys()).apply { disable() })
        first.record().final("synthetic crashed words"); first.idle()
        first.model.toggle(); first.idle(); first.wire.final("end"); first.idle()
        assertTrue("the crash left only the recovery copy", File(context.noBackupFilesDir, NotesJournal.FILE_NAME).exists())

        val sessions = NotesSessions(context, SoftwareHistoryKeys()).apply { enable() } // The switch is shared: back on for the restart.
        val rig = NotesModelRig(context, keys = keys, sessions = sessions)
        rig.idle()
        assertNotNull(rig.model.recovered)
        val entry = sessions.entries().single()
        assertTrue(entry.recovered)
        assertEquals(first.model.document.uid, entry.id)
        assertFalse(File(context.noBackupFilesDir, NotesJournal.FILE_NAME).exists())
        assertTrue(sessions.clearRecovered(entry.id))
        assertFalse(sessions.entries().single().recovered)
    }

    @Test fun `keep audio stores each speech segment sealed beside its transcript, only when switched on`() {
        val encoder = FakeAudioEncoder()
        val sessions = NotesSessions(context, SoftwareHistoryKeys(), encoder = encoder)
        val off = NotesModelRig(context, sessions = sessions)
        off.record().final("synthetic words"); off.idle()
        assertEquals(0, encoder.calls)
        assertEquals(0L, sessions.totalAudioBytes())
        stop(off)

        sessions.keepAudio = true
        val rig = NotesModelRig(context, sessions = sessions)
        rig.record().final("synthetic spoken words"); rig.idle()
        repeat(250) { rig.model.recorder.handleFrame(ByteArray(1280), 0.1f) } // 10 s more, into the second segment
        stop(rig); rig.idle()
        val id = rig.model.document.uid
        val clips = sessions.open(id)!!.clips
        assertEquals("the 45 s segment and the tail", listOf(0, 1), clips.map { it.segment })
        assertEquals(0.0, clips[0].offset, 1e-9)
        assertEquals(45.0, clips[0].duration, 1e-9)
        assertEquals(16000, clips[0].sampleRate)
        assertEquals(45.0, clips[1].offset, 1e-9)
        assertNotNull(sessions.clipBytes(id, 0))
        assertTrue(sessions.totalAudioBytes() > 0)
        assertEquals("the open note shows its clips too", 2, rig.model.document.audio.size)
        assertEquals(sessions.totalAudioBytes(), sessions.entries().first { it.id == id }.audioBytes)
        assertTrue(sessions.deleteAudio(id))
        assertEquals(0L, sessions.totalAudioBytes())
        assertEquals("the text stays", 2, NotesDocument.fromJson(sessions.open(id)!!.document).segments.size)
    }
}
