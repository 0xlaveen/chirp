package dev.chirp.android

import android.graphics.Bitmap
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.foundation.layout.padding
import androidx.compose.ui.unit.dp
import java.io.File
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

private fun result(generation: String, vararg turns: ServerTurn) = SpeakersResult(generation, turns.toList())
private fun turn(slot: Int, start: Double, text: String) = ServerTurn(slot, start, text, text.lowercase().trimEnd('.', '?', '!'))

/** Speaker labels (#187): the protocol fields, the roster, the document, the recorder and the screens. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37])
class NotesSpeakersTest {
    // Protocol

    @Test fun `start carries the speaker session only when labels are on`() {
        assertFalse(JSONObject(Protocol.start(false)).has("speakers"))
        val session = NotesRecorder.newSpeakerSession()
        assertTrue(Protocol.SPEAKER_SESSION.matches(session))
        assertEquals(session, JSONObject(Protocol.start(true, "live_notes", speakers = session)).getJSONObject("speakers").getString("session"))
        assertThrows(IllegalArgumentException::class.java) { Protocol.start(false, speakers = "short") }
    }

    @Test fun `final decodes turns, errors, and ignores malformed labels`() {
        val final = Protocol.decode("""{"type":"final","text":"We ship. Okay.","raw":"we ship okay","corrected":true,"speakers":
            {"generation":"g1","turns":[{"speaker":0,"start":0.5,"end":1.2,"text":"We ship.","raw":"we ship","approximate":false,"kept_original":false},
            {"speaker":1,"start":2.0,"end":2.4,"text":"Okay.","raw":"okay","approximate":true,"kept_original":true}]}}""") as ServerEvent.Final
        assertEquals(SpeakersResult("g1", listOf(ServerTurn(0, 0.5, "We ship.", "we ship"), ServerTurn(1, 2.0, "Okay.", "okay", true, true))), final.speakers)
        val missing = Protocol.decode("""{"type":"final","text":"a","raw":"a","corrected":false,"speakers":{"error":"unavailable"}}""") as ServerEvent.Final
        assertEquals("unavailable", missing.speakers?.error)
        // A broken label payload never breaks the segment's text.
        val broken = Protocol.decode("""{"type":"final","text":"a","raw":"a","corrected":false,"speakers":{"generation":"g","turns":[{"speaker":99}]}}""") as ServerEvent.Final
        assertEquals("a", broken.text); assertNull(broken.speakers)
        assertNull((Protocol.decode("""{"type":"final","text":"a","raw":"a","corrected":false}""") as ServerEvent.Final).speakers)
    }

    @Test fun `health says whether the Mac labels speakers and where its model is`() {
        val health = Protocol.health("""{"ok":true,"ready":true,"debug_retention":false,"notes_speakers":true,"speakers_model":{"state":"not_downloaded","size_bytes":1}}""")
        assertTrue(health.notesSpeakers); assertEquals("not_downloaded", health.speakersModel)
        val old = Protocol.health("""{"ok":true,"ready":true,"debug_retention":false}""")
        assertFalse(old.notesSpeakers); assertNull(old.speakersModel)
        // The cached copy keeps both.
        val store = SettingsStore(RuntimeEnvironment.getApplication())
        store.health = health
        assertEquals("not_downloaded", store.health?.speakersModel); assertTrue(store.health!!.notesSpeakers)
        assertFalse(store.notesLabelSpeakers)
    }

    // Roster

    @Test fun `people are numbered by first appearance and a new generation keeps them`() {
        val roster = SpeakerRoster()
        assertEquals(1, roster.id(3, "g1")); assertEquals(2, roster.id(0, "g1")); assertEquals(1, roster.id(3, "g1"))
        // The Mac restarted: its slots mean new voices now, the people stay.
        assertEquals(3, roster.id(3, "g2"))
        assertEquals(listOf(1, 2, 3), roster.active)
        assertEquals("Person 2", roster.displayName(2))
    }

    @Test fun `rename, merge and separate resolve everywhere`() {
        val roster = SpeakerRoster()
        repeat(3) { roster.addPerson() }
        roster.rename(2, "  Maya ")
        assertEquals("Maya", roster.displayName(2))
        roster.rename(2, " "); assertEquals("Person 2", roster.displayName(2))
        roster.rename(1, "Sam")
        roster.merge(3, 1)
        assertEquals("Sam", roster.displayName(3)); assertEquals(1, roster.resolve(3)); assertEquals(roster.colorIndex(1), roster.colorIndex(3))
        assertEquals(listOf(1, 2), roster.active); assertEquals(listOf(3), roster.merged(1))
        roster.merge(1, 3) // a cycle is refused
        assertEquals(1, roster.resolve(1))
        roster.separate(3)
        assertEquals("Person 3", roster.displayName(3))
        val copy = SpeakerRoster.fromJson(roster.apply { merge(2, 1) }.toJson())
        assertEquals(listOf("Sam", "Sam", "Person 3"), (1..3).map(copy::displayName))
    }

    // Document

    private fun labelledDocument() = NotesDocument(0L).apply {
        roster.id(0, "g"); roster.id(1, "g")
        append(NotesSegment(0, 0.0, "we ship friday okay", "We ship Friday. Okay.", turns = listOf(
            SpeakerTurn(1, 0.4, "We ship Friday.", "we ship friday"), SpeakerTurn(2, 65.0, "Okay.", "okay"))))
        append(NotesSegment(1, 70.0, "plain words", "Plain words."))
    }

    @Test fun `structuring reads Name lines and a rename applies across the note`() {
        val document = labelledDocument()
        assertEquals("Person 1: We ship Friday.\nPerson 2: Okay.\nPlain words.", document.nextStructureRequest()!!.transcript)
        document.renameSpeaker(2, "Maya")
        assertEquals(1, document.speakerVersion)
        assertEquals("Person 1: We ship Friday.\nMaya: Okay.\nPlain words.", document.nextStructureRequest()!!.transcript)
        assertEquals(listOf("**[00:00:00] Person 1:** We ship Friday.\n\n**[00:01:05] Maya:** Okay.", "**[00:01:10]** Plain words."),
            document.transcriptLines())
        assertTrue(document.exportMarkdown().contains("**[00:01:05] Maya:** Okay."))
        assertEquals("**[00:00:00] Person 1:** we ship friday\n\n**[00:01:05] Maya:** okay", document.transcriptLines(raw = true)[0])
    }

    @Test fun `names are replaced as whole words only`() {
        val document = NotesDocument(0L, "- [ ] **Person 2** to send the spec\n- Person 21 joins\n- Ask Person 2")
        assertEquals(2, document.nameCount("Person 2"))
        assertEquals("- [ ] **Maya** to send the spec\n- Person 21 joins\n- Ask Maya", document.replacingName("Person 2", "Maya"))
        assertEquals(0, document.nameCount(""))
    }

    @Test fun `turns and people survive the saved note`() {
        val document = labelledDocument().apply { renameSpeaker(1, "Sam"); mergeSpeaker(2, 1) }
        val copy = NotesDocument.fromJson(document.toJson())
        assertEquals(document.segments.map { it.turns }, copy.segments.map { it.turns })
        assertEquals("Sam", copy.roster.displayName(2))
        assertTrue(copy.labelled)
        // An unlabelled note writes nothing new.
        val plain = NotesDocument(0L).apply { append(NotesSegment(0, 0.0, "a")) }.toJson()
        assertFalse(plain.has("people")); assertFalse(plain.getJSONArray("segments").getJSONObject(0).has("turns"))
    }

    // Recorder

    @Test fun `segments ask for labels only when on, with one session per note`() {
        val rig = NotesRig()
        rig.recorder.start(); rig.wire.ready(); rig.idle()
        assertNull(rig.wire.speakers)
        rig.recorder.labelSpeakers = true
        rig.segment()
        val session = rig.wire.speakers
        assertNotNull(session); assertTrue(Protocol.SPEAKER_SESSION.matches(session!!))
        rig.segment()
        assertEquals(session, rig.wire.speakers)
        rig.recorder.cancel(); rig.recorder.reset()
        rig.recorder.start(); rig.wire.ready(); rig.idle()
        assertNotEquals("New starts a new speaker session", session, rig.wire.speakers)
    }

    @Test fun `people are numbered in transcript order even when finals arrive out of order`() {
        val rig = NotesRig()
        rig.recorder.labelSpeakers = true
        rig.recorder.start(); rig.wire.ready(); rig.idle()
        val first = rig.segment(); val second = rig.segment()
        second.final("Okay. Sure.", speakers = result("g", turn(1, 0.0, "Okay."), turn(1, 1.0, "Sure.")))
        first.final("We ship.", speakers = result("g", turn(0, 0.2, "We ship.")))
        rig.idle()
        val segments = rig.recorder.document.segments
        assertEquals(listOf(SpeakerTurn(1, 0.2, "We ship.", "we ship")), segments[0].turns)
        // One person's turns in a row join; the start is in note seconds.
        assertEquals(listOf(SpeakerTurn(2, 45.0, "Okay. Sure.", "okay sure")), segments[1].turns)
        assertNull(rig.recorder.speakerError)
    }

    @Test fun `a missing model leaves segments unlabelled and says so`() {
        val rig = NotesRig()
        rig.recorder.labelSpeakers = true
        rig.recorder.start(); rig.wire.ready(); rig.idle()
        rig.segment().final("Hello.", speakers = SpeakersResult(null, emptyList(), "unavailable")); rig.idle()
        assertNull(rig.recorder.document.segments.single().turns)
        assertEquals("unavailable", rig.recorder.speakerError)
    }

    // The model

    private val speakersMac = notesMac.copy(notesSpeakers = true, speakersModel = "not_downloaded")

    @Test fun `turning labels on asks before the Mac downloads its model`() {
        val app = RuntimeEnvironment.getApplication()
        val requests = mutableListOf<String>()
        val store = SettingsStore(app).apply { health = speakersMac }
        val model = NotesModel(app, store, captureFactory = { frame, _, done -> FakeNotesCapture(frame, done) },
            transportFactory = { _, _, event, failure -> NotesWire(event, failure) }, apiFactory = { _, _ -> ScriptedNotesApi() },
            micGranted = { true }, pairing = { Pairing.from("https://mac.example.test/chirp", "synthetic") }, fetchHealth = { _, _ -> null },
            speakerModel = { _, _, action -> requests += action; "downloading" }, tailscale = TailscalePromptTest.FakeTailscale(),
            foreground = {}, io = { it() }, journal = null, sessions = null, background = { it() }, audioWork = { it() })
        model.setSpeakerLabels(true)
        assertTrue(model.speakerConsent); assertFalse(model.labelSpeakers); assertTrue(requests.isEmpty())
        model.dismissSpeakerConsent()
        assertFalse(model.labelSpeakers); assertFalse(store.notesLabelSpeakers)
        model.setSpeakerLabels(true); model.confirmSpeakerDownload()
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle()
        assertEquals(listOf("download"), requests)
        assertTrue(model.labelSpeakers); assertTrue(store.notesLabelSpeakers); assertTrue(model.recorder.labelSpeakers)
        model.setSpeakerLabels(false)
        assertFalse(model.recorder.labelSpeakers); assertFalse(store.notesLabelSpeakers)
    }

    @Test fun `renaming offers to replace the old name in the notes`() {
        val rig = NotesModelRig(RuntimeEnvironment.getApplication(), speakersMac)
        rig.model.recorder.document.apply { roster.id(0, "g") }
        rig.model.edit(androidx.compose.ui.text.input.TextFieldValue("- [ ] **Person 1** to send the spec"))
        rig.model.renameSpeaker(1, "Maya", replaceInNotes = true)
        assertEquals("- [ ] **Maya** to send the spec", rig.model.document.text)
        assertEquals("Maya", rig.model.document.roster.displayName(1))
        rig.model.renameSpeaker(1, "Sam")
        assertEquals("- [ ] **Maya** to send the spec", rig.model.document.text)
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class NotesSpeakersRenderTest {
    @get:Rule val compose = createComposeRule()

    private fun rig(): NotesModelRig {
        val rig = NotesModelRig(RuntimeEnvironment.getApplication(), notesMac.copy(notesSpeakers = true, speakersModel = "ready"))
        rig.model.rename("Launch sync")
        rig.model.recorder.labelSpeakers = true
        rig.record().final("We ship the beta on Friday. Who owns the invite? I can draft it today.",
            speakers = result("g", turn(0, 0.4, "We ship the beta on Friday."), turn(1, 4.0, "Who owns the invite?"),
                turn(2, 7.5, "I can draft it today.")))
        rig.idle()
        return rig
    }

    @Test @Config(qualifiers = "w411dp-h891dp-mdpi") fun `transcript chips, rename and merge`() {
        val output = File(System.getProperty("chirp.screenshots")).apply { mkdirs() }
        val rig = rig()
        val dark = mutableStateOf(false)
        compose.setContent {
            dev.chirp.android.ui.ChirpTheme(dark.value) {
                // The sheet's and the side pane's surface.
                androidx.compose.material3.Surface(color = androidx.compose.material3.MaterialTheme.colorScheme.surfaceContainer) {
                    TranscriptPane(rig.model, androidx.compose.ui.Modifier.padding(horizontal = 24.dp))
                }
            }
        }
        fun shot(name: String) {
            compose.mainClock.advanceTimeBy(2000); compose.waitForIdle()
            val bitmap = notesScreenshot(compose.onRoot(), false)
            File(output, "notes-speakers-$name-${if (dark.value) "dark" else "light"}.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        }
        for (night in listOf(false, true)) { compose.runOnIdle { dark.value = night }; shot("transcript") }
        compose.runOnIdle { dark.value = false }
        listOf("Person 1", "Person 2", "Person 3").forEach { compose.onNodeWithText(it).assertIsDisplayed() }
        compose.onNodeWithText("Who owns the invite?").assertIsDisplayed()
        // Rename from the chip: everywhere in the note at once.
        compose.onNodeWithContentDescription("Person 2. Rename or merge this speaker").performClick()
        compose.onNodeWithText("Rename “Person 2”…").performClick()
        compose.onNode(hasSetTextAction()).performTextInput("Maya")
        shot("rename")
        compose.onNodeWithText("Rename").performClick()
        compose.onNodeWithText("Maya").assertIsDisplayed()
        assertTrue(rig.model.export().contains("Maya:** Who owns the invite?"))
        // Same person as: Person 3 becomes Maya, and Separate undoes it.
        compose.onNodeWithContentDescription("Person 3. Rename or merge this speaker").performClick()
        compose.onAllNodesWithText("Maya").onLast().performClick()
        compose.waitForIdle()
        assertEquals("Maya", rig.model.document.roster.displayName(3))
        compose.onNodeWithText("Person 3").assertDoesNotExist()
        shot("merged")
        compose.onNodeWithContentDescription("Maya. Rename or merge this speaker").performClick()
        compose.onNodeWithText("Separate Person 3").performClick()
        compose.onNodeWithText("Person 3").assertIsDisplayed()
    }

    @Test @Config(qualifiers = "w411dp-h891dp-mdpi") fun `the notes menu offers the switch and the consent dialog`() {
        val rig = NotesModelRig(RuntimeEnvironment.getApplication(), notesMac.copy(notesSpeakers = true, speakersModel = "not_downloaded"))
        compose.setContent { dev.chirp.android.ui.ChirpTheme(false) { NotesScreen(rig.model, rig.model::toggle, {}, {}, {}, {}) } }
        compose.onNodeWithContentDescription("More options").performClick()
        compose.onNodeWithText("Label speakers").performClick()
        compose.onNodeWithText("Label speakers?").assertIsDisplayed()
        compose.onNodeWithText("Not now").performClick()
        assertFalse(rig.model.labelSpeakers)
    }
}
