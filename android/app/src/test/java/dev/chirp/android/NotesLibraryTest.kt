package dev.chirp.android

import java.io.File
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/** A stand-in for MediaCodec, which the JVM does not have: "m4a:" and the first bytes of the audio. */
internal class FakeAudioEncoder : AudioEncoder {
    var calls = 0
    override fun encode(pcm: ByteArray, sampleRate: Int): ByteArray { calls++; return "m4a:".toByteArray() + pcm.copyOf(minOf(pcm.size, 16)) }
}

internal fun noteJson(text: String, startedAt: Long = 1_800_000_000_000L, name: String? = null, elapsed: Double = 12.0, segments: List<String> = emptyList()): JSONObject {
    val document = NotesDocument(startedAt, text)
    segments.forEachIndexed { i, s -> document.append(NotesSegment(i, i * 20.0, s)) }
    document.name = name
    return document.toJson().put("elapsed", elapsed)
}

/** The notes library: per-note sealed files and an index, retention and Recently Deleted on a fake clock, quarantine, migration. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 37])
class NotesLibraryTest {
    private val context get() = RuntimeEnvironment.getApplication()
    private val dir get() = File(context.filesDir, NotesSessions.DIR)
    private var now = 1_800_000_000_000L
    private val keys = SoftwareHistoryKeys()
    private fun library(encoder: AudioEncoder = FakeAudioEncoder()) = NotesSessions(context, keys, { now }, encoder)
    private val day = 86_400_000L

    @Test fun `on by default, notes are sealed one file each, and the files hold no readable text`() {
        val library = library()
        assertTrue("an absent preference counts as on", library.enabled)
        assertFalse(library.optedOut)
        assertTrue(library.put("a1", noteJson("# Weekly sync\nsynthetic plan words")))
        val raw = File(dir, "a1.bin").readBytes().toString(Charsets.ISO_8859_1) + File(dir, NotesSessions.INDEX_FILE).readBytes().toString(Charsets.ISO_8859_1)
        assertFalse(raw.contains("synthetic") || raw.contains("Weekly"))
        val entry = library.entries().single()
        assertEquals("Weekly sync", entry.title)
        assertEquals("synthetic plan words", entry.snippet)
        assertEquals("NotesIndexEntry(<redacted>)", entry.toString())
        assertEquals("NotesRecord(<redacted>)", library.open("a1")!!.toString())
        assertFalse(File(context.filesDir, NotesSessions.FILE_NAME).exists())
    }

    @Test fun `two hundred notes, no cap, the list comes from the index, newest edit first`() {
        val library = library()
        repeat(200) { i -> now += 1000; assertTrue(library.put("n$i", noteJson("# Note $i\n- [ ] task $i", elapsed = i.toDouble()))) }
        val entries = library.entries()
        assertEquals(200, entries.size)
        assertEquals("Note 199", entries.first().title)
        assertEquals("Note 0", entries.last().title)
        assertEquals(1, entries.first().openTodos)
        assertEquals(199.0, entries.first().duration, 1e-9)
        assertEquals(201, dir.listFiles { f -> f.name.endsWith(".bin") }!!.size)
        // The index alone feeds the list: a note that cannot be opened is not touched by listing.
        File(dir, "n7.bin").writeBytes(ByteArray(40) { 3 })
        assertEquals(200, library().entries().size)
        assertEquals("Note 42", library().open("n42")!!.entry.title)
    }

    @Test fun `put replaces the same note, keeps its creation time, and a blank untouched note is not kept`() {
        val library = library()
        library.put("a", noteJson("first"))
        val created = library.entries().single().createdAt
        now += 5000
        library.put("a", noteJson("first, then more"))
        assertEquals(1, library.entries().size)
        assertEquals(created, library.entries().single().createdAt)
        assertEquals(now, library.entries().single().updatedAt)
        assertFalse(library.put("blank", noteJson("")))
        assertEquals(listOf("a"), library.entries().map { it.id })
        assertTrue("a named blank note is kept", library.put("named", noteJson("", name = "Ideas")))
        assertEquals("Ideas", library.open("named")!!.entry.title)
    }

    @Test fun `rename wins forever and a blank rename goes back to the derived title`() {
        val library = library()
        library.put("a", noteJson("# Heading from the text"))
        assertTrue(library.rename("a", "  My name  "))
        assertEquals("My name", library.entries().single().title)
        library.put("a", noteJson("# Another heading", name = "My name"))
        assertEquals("My name", library.entries().single().title)
        library.rename("a", " ")
        assertEquals("Another heading", library.entries().single().title)
    }

    @Test fun `search finds title, notes and transcript, highlights the match, and a blank query finds nothing`() {
        val library = library()
        library.put("a", noteJson("# Budget review\nnothing else", segments = listOf("we spoke about the Roadmap today")))
        library.put("b", noteJson("# Groceries\n- milk"))
        assertEquals(listOf("a"), library.search("budget").map { it.entry.id })
        val transcript = library.search("roadmap").single()
        assertEquals("Roadmap", transcript.snippet.substring(transcript.matchStart, transcript.matchEnd))
        assertEquals(listOf("b"), library.search("milk").map { it.entry.id })
        assertTrue(library.search("zzz").isEmpty())
        assertTrue(library.search("  ").isEmpty())
        library.trash("a")
        assertTrue("Recently Deleted is not searched", library.search("budget").isEmpty())
    }

    @Test fun `delete goes to Recently Deleted for 30 days, restores, and then goes for good`() {
        val library = library()
        library.put("a", noteJson("keep me")); library.put("b", noteJson("other"))
        assertTrue(library.trash("a"))
        assertEquals(listOf("b"), library.entries().map { it.id })
        assertEquals(listOf("a"), library.trashed().map { it.id })
        assertTrue(library.restore("a"))
        assertEquals(2, library.entries().size)
        library.trash("a")
        now += 29 * day
        assertEquals("still there on day 29", listOf("a"), library.trashed().map { it.id })
        now += 2 * day
        assertTrue("gone after 30 days", library.trashed().isEmpty())
        assertNull(library.open("a"))
        assertFalse(File(dir, "a.bin").exists())
        assertEquals(listOf("b"), library.entries().map { it.id })
        library.trash("b"); library.emptyTrash()
        assertTrue(library.entries(includeDeleted = true).isEmpty())
        assertEquals("the key stays: nothing was crypto-shredded", 0, keys.deletes)
    }

    @Test fun `retention is its own setting, never by default, and moves old notes to Recently Deleted`() {
        val library = library()
        assertEquals(NotesRetention.NEVER, library.retention)
        library.put("old", noteJson("old words"))
        now += 400 * day
        library.put("new", noteJson("new words"))
        assertEquals("never means never", 2, library.entries().size)
        library.retention = NotesRetention.YEAR
        assertEquals(listOf("new"), library.entries().map { it.id })
        assertEquals(listOf("old"), library.trashed().map { it.id })
        library.restore("old")
        assertEquals("a restored note starts fresh", listOf("old", "new"), library.entries().map { it.id })
        library.retention = NotesRetention.DAYS_30
        now += 31 * day
        assertTrue(library.entries().isEmpty())
        assertEquals(2, library.trashed().size)
        assertEquals(listOf(30, 90, 365, 0), listOf(NotesRetention.DAYS_30, NotesRetention.DAYS_90, NotesRetention.YEAR, NotesRetention.NEVER).map { it.days })
    }

    @Test fun `a corrupt note is quarantined, never deleted, and never takes the collection with it`() {
        val library = library()
        listOf("a", "b", "c").forEach { now += 1000; library.put(it, noteJson("note $it")) }
        File(dir, "b.bin").writeBytes(ByteArray(64) { 9 })
        assertNull(library.open("b"))
        assertEquals(listOf("c", "a"), library.entries().map { it.id })
        assertFalse(File(dir, "b.bin").exists())
        assertEquals(1, File(dir, NotesSessions.QUARANTINE).listFiles { f -> f.name.startsWith("b.bin") }!!.size)
        assertEquals("note a", library.open("a")!!.document.getString("text"))
        assertEquals(0, keys.deletes)

        // A broken index is rebuilt from the notes; a broken note met meanwhile is set aside as well.
        File(dir, "c.bin").writeBytes(ByteArray(64) { 5 })
        File(dir, NotesSessions.INDEX_FILE).writeBytes(ByteArray(64) { 1 })
        assertEquals(listOf("a"), library().entries().map { it.id })
        assertEquals(1, File(dir, NotesSessions.QUARANTINE).listFiles { f -> f.name.startsWith("index.bin") }!!.size)
        assertEquals(1, File(dir, NotesSessions.QUARANTINE).listFiles { f -> f.name.startsWith("c.bin") }!!.size)
        assertEquals("note a", library().open("a")!!.document.getString("text"))
    }

    @Test fun `a lost key quarantines everything and deletes nothing`() {
        val library = library()
        library.put("a", noteJson("note a"))
        keys.key = null
        assertTrue(library().entries().isEmpty())
        assertTrue("set aside for a user who can still recover the key", File(dir, NotesSessions.QUARANTINE).listFiles { f -> f.name.startsWith("a.bin") }!!.isNotEmpty())
    }

    @Test fun `the old single blob migrates once, with its notes, and its file goes but the key stays`() {
        val legacyHeader = byteArrayOf('C'.code.toByte(), 'S'.code.toByte(), 1)
        val old = File(context.filesDir, NotesSessions.FILE_NAME)
        val blob = JSONArray()
            .put(JSONObject().put("id", "old-1").put("time", now - 3 * day).put("title", "Weekly sync").put("chars", 9).put("doc", noteJson("# Weekly sync\nthe plan", startedAt = now - 4 * day)))
            .put(JSONObject().put("id", "old-2").put("time", now - day).put("title", "x").put("chars", 4).put("doc", noteJson("- [ ] one\n- [x] two\n- [ ] three")))
        SealedFile(old, keys, legacyHeader).write(blob.toString().toByteArray())
        val library = library()
        val entries = library.entries()
        assertEquals(listOf("old-2", "old-1"), entries.map { it.id })
        assertEquals(2, entries.first().openTodos)
        assertEquals("Weekly sync", entries.last().title)
        assertEquals(now - 3 * day, entries.last().updatedAt)
        assertEquals("the plan", library.open("old-1")!!.document.getString("text").substringAfter("\n"))
        assertFalse(old.exists())
        assertEquals(0, keys.deletes)
        assertEquals("a second read changes nothing", 2, library().entries().size)
    }

    @Test fun `an unreadable old blob is set aside, not deleted, and the library starts empty`() {
        val old = File(context.filesDir, NotesSessions.FILE_NAME)
        old.writeBytes(ByteArray(80) { 2 })
        assertTrue(library().entries().isEmpty())
        assertFalse(old.exists())
        assertEquals(1, File(dir, NotesSessions.QUARANTINE).listFiles { f -> f.name.startsWith(NotesSessions.FILE_NAME) }!!.size)
    }

    @Test fun `an explicit earlier opt-out is preserved, offers enable, and turning off never deletes notes`() {
        val library = library()
        library.put("a", noteJson("note a"))
        context.getSharedPreferences("chirp_notes_sessions", android.content.Context.MODE_PRIVATE).edit().putBoolean("enabled", false).commit()
        assertFalse(library.enabled)
        assertTrue(library.optedOut)
        assertFalse("nothing new is kept while it is off", library.put("b", noteJson("note b")))
        assertEquals("what was kept stays readable", listOf("a"), library.entries().map { it.id })
        library.enable()
        assertTrue(library.enabled); assertFalse(library.optedOut)
        assertTrue(library.put("b", noteJson("note b")))
        library.disable()
        assertEquals(2, library.entries().size)
        assertTrue(library.optedOut)
        library.deleteAll()
        assertTrue(library.entries(includeDeleted = true).isEmpty())
        assertFalse(dir.exists())
        assertNull(keys.key)
    }

    @Test fun `the index flow follows every change`() {
        val library = library()
        assertTrue(library.index.value.isEmpty())
        library.put("a", noteJson("note a"))
        assertEquals(listOf("a"), library.index.value.map { it.id })
        library.trash("a")
        assertTrue(library.index.value.single().deleted)
        library.purge("a")
        assertTrue(library.index.value.isEmpty())
    }

    @Test fun `kept audio round-trips sealed with its offset, duration and sample rate, and deletes with the note or alone`() {
        val encoder = FakeAudioEncoder()
        val library = library(encoder)
        assertFalse("off by default", library.keepAudio)
        library.put("a", noteJson("note a"))
        val pcm = ByteArray(16000 * 2 * 3) { (it % 100).toByte() } // 3 s at 16 kHz
        val clip = library.saveClip("a", segment = 2, offset = 41.5, pcm = pcm)!!
        assertEquals(NotesAudioClip(2, 41.5, 3.0, 16000, clip.bytes), clip)
        assertEquals("m4a:".length + 16L, clip.bytes)
        assertEquals("m4a:".toByteArray().toList() + pcm.copyOf(16).toList(), library.clipBytes("a", 2)!!.toList())
        val sealed = File(dir, "a/audio/2.m4a").readBytes().toString(Charsets.ISO_8859_1)
        assertFalse("sealed, not plain", sealed.contains("m4a:"))
        assertEquals(clip.bytes, library.totalAudioBytes())
        assertEquals(clip.bytes, library.entries().single().audioBytes)
        assertEquals(listOf(clip), library.open("a")!!.clips)
        // A new snapshot of the same note (made before the clip landed) does not lose it.
        library.put("a", noteJson("note a, edited"))
        assertEquals(listOf(clip), library.open("a")!!.clips)
        library.saveClip("a", 0, 0.0, pcm)
        assertEquals(listOf(0, 2), library.open("a")!!.clips.map { it.segment })

        assertTrue(library.deleteAudio("a"))
        assertNull(library.clipBytes("a", 2))
        assertEquals(0L, library.totalAudioBytes())
        assertTrue(library.open("a")!!.clips.isEmpty())
        assertEquals("the text stays", "note a, edited", library.open("a")!!.document.getString("text"))

        library.saveClip("a", 1, 10.0, pcm)
        library.purge("a")
        assertFalse(File(dir, "a").exists())
        assertNull("no clip for a note that is gone", library.saveClip("a", 1, 10.0, pcm))
        assertFalse(File(dir, "a/audio/1.m4a").exists())
    }

    @Test fun `a clip that cannot be opened is set aside, not deleted`() {
        val library = library()
        library.put("a", noteJson("note a"))
        library.saveClip("a", 0, 0.0, ByteArray(3200))
        File(dir, "a/audio/0.m4a").writeBytes(ByteArray(40) { 4 })
        assertNull(library.clipBytes("a", 0))
        assertEquals(1, File(dir, NotesSessions.QUARANTINE).listFiles { f -> f.name.startsWith("a-0.m4a") }!!.size)
        assertEquals("the note itself is fine", "note a", library.open("a")!!.document.getString("text"))
    }
}
