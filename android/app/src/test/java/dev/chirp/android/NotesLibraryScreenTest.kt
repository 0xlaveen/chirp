package dev.chirp.android

import android.graphics.Bitmap
import androidx.activity.ComponentActivity
import androidx.compose.runtime.*
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.text.input.TextFieldValue
import dev.chirp.android.shell.AppShell
import dev.chirp.android.shell.ShellTab
import java.io.File
import java.time.Instant
import java.time.ZoneOffset
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.robolectric.RobolectricTestRunner

class NotesGroupsTest {
    @Test fun `groups use calendar days and include older months and years`() {
        val now = Instant.parse("2026-10-24T00:10:00Z").toEpochMilli()
        fun group(date: String) = notesGroup(now, Instant.parse(date).toEpochMilli(), ZoneOffset.UTC)
        assertEquals("Today", group("2026-10-24T00:01:00Z"))
        assertEquals("Yesterday", group("2026-10-23T23:59:00Z"))
        assertEquals("Previous 7 days", group("2026-10-17T12:00:00Z"))
        assertEquals("Previous 30 days", group("2026-09-24T12:00:00Z"))
        assertEquals("September", group("2026-09-01T12:00:00Z"))
        assertEquals("October 2025", group("2025-10-24T12:00:00Z"))
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37], qualifiers = "w411dp-h891dp-mdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class NotesLibraryScreenTest {
    @org.junit.Before fun noMotion() {
        android.provider.Settings.Global.putFloat(RuntimeEnvironment.getApplication().contentResolver, android.provider.Settings.Global.ANIMATOR_DURATION_SCALE, 0f)
    }

    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private val context get() = RuntimeEnvironment.getApplication()
    private val now = Instant.parse("2026-10-24T14:00:00Z").toEpochMilli()
    private var time = now
    private val keys = SoftwareHistoryKeys()
    private val library by lazy { NotesSessions(context, keys, { time }) }
    private val live by lazy { NotesModelRig(context, sessions = library) }
    private val reader by lazy { NotesModelRig(context, sessions = library) }
    private val dark = mutableStateOf(false)
    private val tab = mutableStateOf(ShellTab.Notes)
    private val setup = SetupState().apply { mic = true; paired = true; reachable = true; inputEnabled = true }
    private var connections = 0
    private var dictations = 0

    private fun note(title: String, text: String, hoursAgo: Int = 0, transcript: String = "", audio: Boolean = false): String {
        time = now - hoursAgo * 3_600_000L
        val doc = NotesDocument().apply {
            name = title; userEdit(0, 0, text)
            if (transcript.isNotBlank()) append(NotesSegment(0, 0.0, transcript))
        }
        library.put(doc.uid, doc.toJson().put("elapsed", 732.0))
        if (audio) library.storeClip(doc.uid, 0, 0.0, 32000, byteArrayOf(1, 2, 3))
        return doc.uid
    }

    private fun show() {
        library.refresh()
        compose.setContent { ChirpTheme(dark.value) {
            AppShell(tab.value, { tab.value = it }) {
                if (it == ShellTab.Notes) NotesLibraryScreen(live.model, reader.model,
                    record = { id -> if (id == null) { live.model.keepSession(); live.model.clear(); live.model.start() } else live.model.continueRecording(id, stopCurrent = true) },
                    copy = {}, share = {}, save = {}, act = {}, state = setup, connection = { connections++ }, dictate = { dictations++ }, now = { now })
                else androidx.compose.material3.Text("Other tab")
            }
        } }
    }
    private fun search(text: String) = compose.onNode(hasSetTextAction()).performTextReplacement(text)
    private fun back() = compose.runOnIdle { compose.activity.onBackPressedDispatcher.onBackPressed() }
    private fun open(title: String) = compose.onNode(hasText(title) and hasClickAction()).performClick()
    private fun trash() { compose.onNodeWithContentDescription("Library options").performClick(); compose.onNodeWithText("Recently Deleted").performClick() }
    private fun loaded(title: String) { compose.waitUntil(5000) { compose.onAllNodesWithContentDescription("Rename notes: $title").fetchSemanticsNodes().isNotEmpty() } }

    @Test fun `full transcript search highlights results and Back preserves the query and list position`() {
        val id = note("Garden plans", "- Buy seeds", transcript = "A quiet pond beside the terrace")
        repeat(14) { note("Earlier note $it", "- A synthetic example", 25 + it) }
        show()
        search("pond")
        compose.waitUntil(5000) { compose.onAllNodesWithText("A quiet pond beside the terrace").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("A quiet pond beside the terrace").assertIsDisplayed()
        open("Garden plans"); loaded("Garden plans")
        compose.onNodeWithText("Continue").assertIsDisplayed()
        back()
        compose.onNode(hasSetTextAction()).assertTextEquals("pond")
        compose.onNodeWithText("Garden plans").assertIsDisplayed()
        assertEquals(id, reader.model.document.uid)
        search("no such phrase")
        compose.waitUntil(5000) { compose.onAllNodesWithText("No results for ‘no such phrase’").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("No results for ‘no such phrase’").assertExists()
        compose.onNodeWithText("Your notes will live here").assertDoesNotExist()
    }

    @Test fun `swipe deletes with Undo and recently deleted can restore`() {
        val id = note("Garden plans", "- Buy seeds")
        show()
        compose.onNode(hasText("Garden plans") and hasClickAction()).performTouchInput { swipeLeft() }
        compose.onNodeWithText("Note deleted").assertIsDisplayed()
        compose.onNodeWithText("Undo").performClick()
        compose.onNodeWithText("Garden plans").assertIsDisplayed()
        compose.runOnIdle { assertFalse(library.open(id)!!.entry.deleted) }
        compose.onNode(hasText("Garden plans") and hasClickAction()).performTouchInput { swipeLeft() }
        trash()
        compose.onNodeWithText("Restore").performClick()
        compose.onNodeWithText("Nothing recently deleted").assertExists()
        compose.runOnIdle { assertFalse(library.open(id)!!.entry.deleted) }
    }

    @Test fun `long press selects notes and bulk delete leaves a recording alone`() {
        val id = note("Garden plans", "- Buy seeds")
        note("A second thought", "- Make time to think")
        show()
        compose.runOnIdle { live.record().final("A synthetic recording"); live.idle() }
        compose.onNode(hasText("Garden plans") and hasClickAction()).performTouchInput { longClick() }
        compose.onNodeWithText("1 selected").assertExists()
        open("A second thought")
        compose.onNodeWithText("2 selected").assertExists()
        compose.onNodeWithContentDescription("Delete selected notes").performClick()
        compose.onNodeWithText("2 notes deleted").assertExists()
        assertTrue(live.model.state.active)
        compose.runOnIdle { assertTrue(library.open(id)!!.entry.deleted) }
    }

    @Test fun `browsing and renaming another note preserves the live recording`() {
        val id = note("Garden plans", "- Buy seeds")
        show()
        compose.runOnIdle { live.record().final("A synthetic recording"); live.idle() }
        val recordingId = live.model.document.uid
        open("Garden plans"); loaded("Garden plans")
        compose.onNodeWithContentDescription("Rename notes: Garden plans").performClick()
        compose.onNodeWithContentDescription("Note title").performTextReplacement("Garden journal")
        compose.onNodeWithContentDescription("Save title").performClick()
        assertEquals("Garden journal", reader.model.displayTitle)
        assertEquals(recordingId, live.model.document.uid)
        assertTrue(live.model.recording)
        compose.runOnIdle { assertEquals("Garden journal", library.open(id)!!.entry.title) }
        compose.onNodeWithText("Continue").performClick()
        compose.onNodeWithText("Stop current and continue here").assertExists()
    }

    @Test fun `connection and Dictate actions and the dismissible setup card are reachable`() {
        setup.mic = false
        show()
        compose.onNodeWithContentDescription("Connection: Mac. Open connection settings").performClick()
        assertEquals(1, connections)
        compose.onNodeWithContentDescription("Dictate").performClick()
        assertEquals(1, dictations)
        compose.onNodeWithText("Make yourself at home").assertExists()
        compose.onNodeWithContentDescription("Dismiss setup").performClick()
        compose.onNodeWithText("Make yourself at home").assertDoesNotExist()
        assertTrue(SettingsStore(context).tryItDismissed)
    }

    @Test fun `Back restores the scrolled list and switching tabs restores the search`() {
        repeat(24) { note("Notebook $it", "A synthetic page", it + 1) }
        show()
        compose.onNodeWithTag("notes-library-list").performScrollToNode(hasText("Notebook 20"))
        val before = compose.onNode(hasText("Notebook 20") and hasClickAction()).fetchSemanticsNode().boundsInRoot.top
        open("Notebook 20"); loaded("Notebook 20"); back()
        val after = compose.onNode(hasText("Notebook 20") and hasClickAction()).fetchSemanticsNode().boundsInRoot.top
        assertEquals(before, after, 1f)
        search("Notebook 2")
        compose.onNode(hasText("History") and isSelectable()).performClick()
        compose.onNode(hasText("Notes") and isSelectable()).performClick()
        compose.onNode(hasSetTextAction()).assertTextEquals("Notebook 2")
    }

    @Test @Config(qualifiers = "w1280dp-h800dp-land-mdpi") fun `wide landscape has a third transcript pane`() {
        note("Launch sync", "## A smaller beta\n- [ ] Draft the invitation", transcript = "Synthetic speech for this review.", audio = true)
        show(); open("Launch sync"); loaded("Launch sync")
        compose.onNodeWithText("Show raw").assertExists()
        compose.onNodeWithContentDescription("Close transcript").assertDoesNotExist()
        compose.onNodeWithContentDescription("Play segment 1").assertExists()
        for (night in listOf(false, true)) {
            compose.runOnIdle { dark.value = night }
            compose.mainClock.advanceTimeBy(2000); compose.waitForIdle()
            val bitmap = compose.onRoot().captureToImage().asAndroidBitmap()
            File(System.getProperty("chirp.screenshots"), "notes-library-wide-landscape-${if (night) "dark" else "light"}.png")
                .outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        }
    }

    private fun render(width: String) {
        show()
        val output = File(System.getProperty("chirp.screenshots")).apply { mkdirs() }
        fun shot(state: String) {
            for (night in listOf(false, true)) {
                compose.runOnIdle { dark.value = night }
                compose.mainClock.advanceTimeBy(2000); compose.waitForIdle()
                // A modal sheet has its own window/root. Capture that window when present.
                val target = if (state == "transcript-sheet") compose.onNode(isRoot() and hasAnyDescendant(hasText("Show raw"))) else compose.onRoot()
                val bitmap = notesScreenshot(target, state == "transcript-sheet")
                File(output, "notes-library-$width-$state-${if (night) "dark" else "light"}.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            }
        }
        shot("empty")
        val first = note("Launch sync", "## A smaller, better beta\nThe first release goes to ten design partners.\n- [ ] Draft the invitation\n- [ ] Check pricing with finance", transcript = "The beta goes to ten design partners. We agreed to ship on Friday.", audio = true)
        note("A walk by the water", "A quiet morning, a notebook, and a little room to think.", 5)
        note("Ideas for the studio", "- A long table by the window\n- [ ] Find a reading lamp", 25)
        val deleted = note("An earlier draft", "A few thoughts worth returning to.", 50)
        library.trash(deleted); time = now
        compose.onNodeWithText("☐ 0 open").assertDoesNotExist()
        val listBottom = compose.onNodeWithTag("notes-library-list").fetchSemanticsNode().boundsInRoot.bottom
        val fabTop = compose.onNodeWithContentDescription("Record new note").fetchSemanticsNode().boundsInRoot.top
        assertTrue("list viewport stays above the capture controls", listBottom <= fabTop)
        shot("populated")
        compose.runOnIdle { live.model.rename("Product conversation"); live.record().final("We can keep the first release small."); live.idle() }
        shot("recording")
        search("design")
        compose.waitUntil(5000) { compose.onAllNodesWithText("Launch sync").fetchSemanticsNodes().isNotEmpty() }
        shot("search")
        search("summer holiday")
        compose.waitUntil(5000) { compose.onAllNodesWithText("No results for ‘summer holiday’").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("No results for ‘summer holiday’").assertExists()
        shot("no-results")
        search("")
        compose.onNode(hasText("Launch sync") and hasClickAction()).performTouchInput { longClick() }
        open("A walk by the water")
        shot("multi-select")
        back()
        trash(); shot("recently-deleted"); back()
        open("Launch sync"); loaded("Launch sync")
        shot("detail")
        compose.onNodeWithText("Transcript").performClick()
        compose.onNodeWithContentDescription("Play segment 1").assertExists()
        shot("transcript-sheet")
        // The note being read is independent of the recording in every viewport.
        assertEquals(first, reader.model.document.uid)
        assertTrue(live.model.recording)
    }

    @Test fun `render library on cover in light and dark`() = render("cover")
    @Test @Config(qualifiers = "w840dp-h900dp-mdpi") fun `render library on inner in light and dark`() = render("inner")
}
