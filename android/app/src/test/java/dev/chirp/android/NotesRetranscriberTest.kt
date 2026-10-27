package dev.chirp.android

import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

internal class FakeAudioDecoder : AudioDecoder {
    val inputs = mutableListOf<ByteArray>()
    override fun decode(encoded: ByteArray): ByteArray {
        inputs += encoded
        if (encoded.firstOrNull() == 0.toByte()) error("bad clip")
        return ByteArray(6400) { 1 }
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37])
class NotesRetranscriberTest {
    private val health = notesMac.copy(notesRetranscribe = true, notesContext = true)
    private fun clip(index: Int) = NotesAudioClip(index, index * 10.0, 10.0, 16000, 20)
    private class Wire(private val event: (ServerEvent) -> Unit, val answer: ServerEvent, val busy: Boolean = false) : ImeTransport {
        var context: String? = null
        var frames = 0
        var cancelled = false
        override fun retranscription(context: String?) { this.context = context }
        override fun connect() {}
        override fun start(correction: Boolean): Boolean {
            event(if (busy) ServerEvent.Failure("busy") else ServerEvent.Ready(false, "new-engine")); return true
        }
        override fun audio(bytes: ByteArray): Boolean { assertTrue(bytes.size <= 3200); frames++; return true }
        override fun stop(): Boolean { event(answer); return true }
        override fun close(cancel: Boolean, immediate: Boolean) { cancelled = cancel }
    }
    private fun final(text: String) = ServerEvent.Final(text, text, false)

    @Test fun `ordered clips stage words and chain only the preceding new text`() = runBlocking {
        val decoder = FakeAudioDecoder()
        val wires = mutableListOf<Wire>()
        val runner = NotesRetranscriber({ event, _ -> Wire(event, final(if (wires.isEmpty()) "new first" else "new second")).also { wires += it } }, decoder, decode = { it() })
        val progress = mutableListOf<RetranscribeProgress>()
        val results = runner.run("note", listOf(clip(0), clip(1)), health, true, { byteArrayOf(1) }, progress::add)
        assertEquals(listOf(0, 1), results.keys.toList())
        assertEquals(listOf("", "new first"), wires.map { it.context })
        assertTrue(wires.all { it.frames == 2 })
        assertEquals("new-engine", results[0]?.engine)
        assertEquals(2, progress.last().done)
        assertTrue(decoder.inputs.all { input -> input.all { it == 0.toByte() } })
    }

    @Test fun `busy retries bounded backoff and preserves staged work on exhaustion`() = runBlocking {
        var calls = 0
        val delays = mutableListOf<Long>()
        val runner = NotesRetranscriber({ event, _ -> Wire(event, final("new"), busy = calls++ > 0) }, FakeAudioDecoder(), decode = { it() }, backoff = { delays += it })
        try { runner.run("note", listOf(clip(0), clip(1)), health, false, { byteArrayOf(1) }, {}) ; fail("busy must stop") }
        catch (e: RetranscribeError) { assertEquals("busy", e.code) }
        assertEquals(listOf(2000L, 4000L, 8000L, 16000L, 30000L, 30000L, 30000L, 30000L, 30000L), delays)
        assertEquals(setOf(0), runner.staged.keys)
    }

    @Test fun `decode and per-segment engine failures keep their old segments`() = runBlocking {
        var calls = 0
        val runner = NotesRetranscriber({ event, _ -> Wire(event, if (calls++ == 0) ServerEvent.Failure("engine") else final("new")) }, FakeAudioDecoder(), decode = { it() })
        val result = runner.run("note", (0..2).map(::clip), health, false, { byteArrayOf(if (it == 0) 0 else 1) }, {})
        assertEquals(setOf(2), result.keys)
    }

    @Test fun `cancel closes in-flight socket and discards every staged result`() = runBlocking {
        lateinit var wire: ImeTransport
        val runner = NotesRetranscriber({ _, _ -> object : ImeTransport {
            override fun connect() {}
            override fun start(correction: Boolean) = true
            override fun audio(bytes: ByteArray) = true
            override fun stop() = true
            var closed = false
            override fun close(cancel: Boolean, immediate: Boolean) { closed = true }
        }.also { wire = it } }, FakeAudioDecoder(), decode = { it() })
        val job = launch(start = CoroutineStart.UNDISPATCHED) { runner.run("note", listOf(clip(0)), health, false, { byteArrayOf(1) }, {}) }
        job.cancelAndJoin(); runner.cancel()
        assertNotNull(wire)
        assertTrue(runner.staged.isEmpty())
    }

    @Test fun `old server never opens a socket`() = runBlocking {
        val runner = NotesRetranscriber({ _, _ -> error("must not send") }, FakeAudioDecoder(), decode = { it() })
        try { runner.run("note", listOf(clip(0)), notesMac, false, { byteArrayOf(1) }, {}); fail() }
        catch (_: IllegalArgumentException) { }
    }

    @Test fun `reauthentication stops without applying staged answers`() = runBlocking {
        val runner = NotesRetranscriber({ event, _ -> Wire(event, ServerEvent.Failure("auth")) }, FakeAudioDecoder(), decode = { it() })
        try { runner.run("note", listOf(clip(0)), health, false, { byteArrayOf(1) }, {}); fail() }
        catch (e: RetranscribeError) { assertEquals("auth", e.code) }
        assertTrue(runner.staged.isEmpty())
    }

    @Test fun `word times use clip offset and preserve empty turns and overrides`() {
        val doc = NotesDocument(text = "My edited body")
        val person = doc.roster.addPerson(); doc.roster.rename(person, "Maya")
        doc.append(NotesSegment(0, 10.0, "WRONG TEXT", turns = listOf(
            SpeakerTurn(person, 10.0, "wrong", overridePerson = 2), SpeakerTurn(person, 13.0, "wrong"), SpeakerTurn(person, 18.0, "wrong"))))
        doc.addBoundary(10.0, 1)
        val old = doc.segments.toList()
        val result = RetranscribedSegment(clip(1).copy(segment = 0), final("first last").copy(words = listOf(TranscriptWord("first", 0.0, 1.0), TranscriptWord("last", 4.0, 5.0))), "new")
        assertTrue(doc.applyRetranscription(mapOf(0 to result)))
        assertEquals(listOf("first", "last", ""), doc.segments[0].turns!!.map { it.text })
        assertEquals(2, doc.segments[0].turns!![0].overridePerson)
        assertEquals("Maya", doc.roster.displayName(person))
        assertEquals("My edited body", doc.text)
        assertEquals(listOf(NotesBoundary(10.0, 1)), doc.boundaries)
        val reopened = NotesDocument.fromJson(doc.toJson())
        assertEquals(old, reopened.previousTranscript!!.segments)
        assertTrue(reopened.restorePreviousTranscript()); assertEquals(old, reopened.segments)
        assertTrue(reopened.restorePreviousTranscript()); assertEquals(doc.segments, reopened.segments)
    }

    @Test fun `no timings apportions by duration and keeps reassigned people`() {
        val doc = NotesDocument()
        doc.append(NotesSegment(0, 0.0, "old", turns = listOf(SpeakerTurn(1, 0.0, "old", overridePerson = 3), SpeakerTurn(2, 2.5, "old"))))
        doc.applyRetranscription(mapOf(0 to RetranscribedSegment(clip(0), final("one two three four"), "new")))
        assertEquals(listOf("one", "two three four"), doc.segments[0].turns!!.map { it.text })
        assertTrue(doc.segments[0].turns!!.all { it.approximate })
        assertEquals(3, doc.segments[0].turns!![0].overridePerson)
    }

    @Test fun `previous transcript is sealed in library and old notes remain readable`() {
        val context = RuntimeEnvironment.getApplication()
        val sessions = NotesSessions(context, SoftwareHistoryKeys())
        val doc = NotesDocument(text = "Body").apply { append(NotesSegment(0, 0.0, "WRONG TEXT")) }
        assertNull(NotesDocument.fromJson(doc.toJson()).previousTranscript)
        doc.applyRetranscription(mapOf(0 to RetranscribedSegment(clip(0), final("new"), "new")))
        assertTrue(sessions.put(doc.uid, doc.toJson()))
        val saved = sessions.open(doc.uid)!!
        val restored = NotesDocument.fromJson(saved.document)
        assertEquals("WRONG TEXT", restored.previousTranscript!!.segments[0].text)
        assertTrue(restored.restorePreviousTranscript())
        assertEquals("WRONG TEXT", restored.segments[0].text)
        assertFalse(sessions.put(doc.uid, restored.toJson(), expectedRevision = "stale"))
    }

    @Test fun `rebuild reuses bounded windows outline chaining and fallback blocks`() = runBlocking {
        val source = NotesDocument()
        repeat(3) { source.append(NotesSegment(it, it * 10.0, "word ".repeat(400))) }
        val calls = mutableListOf<NotesStructureRequest>()
        val recorder = NotesRecorder({ _, _ -> error("no audio") }, { _, _, _ -> error("no capture") },
            structure = { request -> calls += request; if (calls.size == 2) NotesStructureResponse.failed("timeout") else NotesStructureResponse("## Part ${calls.size}\n- Point", true) },
            reorganize = { NotesReorganizeResponse.failed("off") }, options = NotesRecorder.Options(false), health = notesMac, structuringEnabled = true)
        val result = recorder.rebuildNotes(source)!!
        assertEquals(3, calls.size)
        assertTrue(calls.all { it.transcript.scalars <= NotesDocument.MAX_WINDOW_CHARS })
        assertEquals(listOf(false, false, true), calls.map { it.final })
        assertEquals(listOf("Part 1"), calls.last().outline)
        assertTrue(result.contains(NotesDocument.FALLBACK_HEADER))
        assertTrue(result.contains("## Part 3"))
    }

    @Test fun `protocol advertises only optional retranscription fields and parses provenance`() {
        val live = org.json.JSONObject(Protocol.start(true))
        assertFalse(live.has("retranscribe")); assertFalse(live.has("word_timings"))
        val retry = org.json.JSONObject(Protocol.start(true, "live_notes", retranscribe = true))
        assertTrue(retry.getBoolean("retranscribe")); assertTrue(retry.getBoolean("word_timings"))
        assertEquals(500, org.json.JSONObject(Protocol.stop("x".repeat(600))).getString("context").length)
        val health = Protocol.health("""{"ok":true,"ready":true,"debug_retention":false,"capabilities":["notes_retranscribe"],"notes_context":true,"speech_model":"Parakeet"}""")
        assertTrue(health.notesRetranscribe); assertTrue(health.notesContext); assertEquals("Parakeet", health.speechModel)
        assertEquals("new", (Protocol.decode("""{"type":"ready","debug_retention":false,"engine":"new"}""") as ServerEvent.Ready).engine)
    }
}
