package dev.chirp.android

import dev.chirp.android.AppColour

import androidx.activity.ComponentActivity
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import dev.chirp.android.settings.*
import dev.chirp.android.ui.ChirpTheme
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import okhttp3.OkHttpClient
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** A paired, reachable Mac with clean-up on, with no network, keystore or clock behind it. */
internal fun settingsFixture(): Triple<SetupState, DictationHistory, UpdateController> {
    val context = RuntimeEnvironment.getApplication()
    val health = Health(true, false, true, false, null, engine = "Parakeet")
    SettingsStore(context).apply { this.health = health } // Robolectric has no AndroidKeyStore, so no saved pairing.
    val state = SetupState().apply { paired = true; host = "mac.example.test"; this.health = health; reachable = true }
    val updates = UpdateController(context, CoroutineScope(Dispatchers.Unconfined), OkHttpClient(), pairing = { null }, installed = { 1 })
    return Triple(state, DictationHistory(context, SoftwareHistoryKeys()), updates)
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37], qualifiers = "w411dp-h891dp-mdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class SettingsScreenTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private val context = RuntimeEnvironment.getApplication()

    private fun show(state: SetupState, history: DictationHistory, updates: UpdateController, actions: SettingsActions = SettingsActions(),
                     initialPage: SettingsPage? = null, onExit: (() -> Unit)? = null) =
        compose.setContent { ChirpTheme(colour = AppColour.POND) { SettingsScreen(state, actions, initialPage, history, updates, onExit) } }

    private fun assertOnce(label: String) = compose.onAllNodesWithText(label).assertCountEquals(1)

    private fun open(page: SettingsPage) = compose.onNodeWithText(page.title).performScrollTo().performClick()

    /** Every control reachable by the label it has, one page per category; each must exist somewhere in that page's tree. */
    private val tree = linkedMapOf<SettingsPage?, List<String>>(
        null to listOf("Connection", "Dictation", "Keyboard", "Feedback & look", "Notes", "Privacy & history", "About"),
        SettingsPage.Connection to listOf("Check connection", "Change pairing", "Forget pairing", "Use this phone's recogniser"),
        SettingsPage.Dictation to listOf("Clean-up · Correction on Mac", "Styles", "Stop dictation", "Spoken commands",
            "Press Send after dictating", "Floating mic (Accessibility)"),
        SettingsPage.Keyboard to listOf("Keyboard look", "Swipe typing", "Hardware keyboard shortcut", "Larger mic on the inner screen",
            "Layouts, languages & typing"),
        SettingsPage.Feedback to listOf("App colours", "Haptic cues", "Sound cues"),
        SettingsPage.Notes to listOf("Save battery while the screen is off", "Keep a recovery copy until notes are saved", "Keep notes on this phone"),
        SettingsPage.History to listOf("Keep dictation history on this phone", "What Chirp keeps"),
        SettingsPage.About to listOf("Check for updates", "Debug overlay (timings only)", "Copy diagnostics", "Clear timings"),
    )

    @Test fun `every setting is reachable from its category page exactly once, and back returns to the list`() {
        val (state, history, updates) = settingsFixture()
        show(state, history, updates)
        tree.getValue(null).forEach(::assertOnce)
        for (page in SettingsPage.entries) {
            open(page)
            assertTrue(compose.onAllNodes(hasText(page.title).and(SemanticsMatcher.keyIsDefined(SemanticsProperties.Heading))).fetchSemanticsNodes().isNotEmpty())
            for (label in tree.getValue(page)) {
                assertTrue("$label missing on ${page.title}", compose.onAllNodesWithText(label).fetchSemanticsNodes().isNotEmpty() ||
                    run { compose.onNodeWithText(page.title).performScrollTo(); compose.onAllNodesWithText(label).fetchSemanticsNodes().isNotEmpty() })
            }
            compose.onNodeWithContentDescription("Back").performClick()
            assertTrue("back from ${page.title} shows the list", compose.onAllNodesWithText("Settings").fetchSemanticsNodes().isNotEmpty())
            assertOnce("About")
        }
    }

    @Test fun `each category row carries a live one-line summary`() {
        val (state, history, updates) = settingsFixture()
        show(state, history, updates)
        compose.onNodeWithText("Parakeet · clean-up on Mac").assertExists()                       // Connection
        compose.onNodeWithText("Clean-up on · stops on tap").assertExists()  // Dictation
        compose.onNodeWithText("Battery saver · recovery copy · keeps notes").assertExists()      // Notes (defaults)
        compose.onNodeWithText("Dictation history off").assertExists()                            // Privacy & history
        compose.onNodeWithText("Chirp ${BuildConfig.VERSION_NAME}").assertExists()                // About
    }

    @Config(qualifiers = "w840dp-h900dp-mdpi")
    @Test fun `two pane summaries update while their detail page stays open`() {
        val (state, history, updates) = settingsFixture()
        show(state, history, updates)
        open(SettingsPage.Dictation)
        compose.onNodeWithText("Clean-up · Correction on Mac").performClick()
        compose.onNodeWithText("Clean-up off · stops on tap").assertExists()
        open(SettingsPage.Feedback)
        compose.onNodeWithText("Haptic cues").performScrollTo().performClick()
        compose.onNodeWithText("Pond · haptic cues off").assertExists()
        open(SettingsPage.History)
        compose.onNodeWithText("Keep dictation history on this phone").performClick()
        compose.onNodeWithText("History on · keeps 7 days").assertExists()
    }

    @Test fun `paragraph help sits behind an info sheet, not on the row`() {
        val (state, history, updates) = settingsFixture()
        show(state, history, updates)
        open(SettingsPage.Dictation)
        compose.onNodeWithText("Off by default").assertExists()
        compose.onNodeWithText("Ending a dictation with \"new line\" or \"new paragraph\" types a line break instead of the words.").assertDoesNotExist()
        compose.onNodeWithContentDescription("About Spoken commands").performClick()
        compose.onNodeWithText("Ending a dictation with \"new line\" or \"new paragraph\" types a line break instead of the words.").assertExists()
        compose.onNodeWithText("Close").performClick()
        compose.onNodeWithText("Ending a dictation with \"new line\" or \"new paragraph\" types a line break instead of the words.").assertDoesNotExist()
    }

    @Test fun `notes retention and audio live under Notes, history retention under Privacy and history`() {
        val (state, history, updates) = settingsFixture()
        show(state, history, updates)
        open(SettingsPage.Notes)
        compose.onNodeWithText("Delete notes older than").performScrollTo().assertExists()
        compose.onNodeWithText("Keep audio with notes").performScrollTo().assertExists()
        compose.onNodeWithContentDescription("Back").performClick()
        open(SettingsPage.History)
        compose.onNodeWithText("Keep for").assertDoesNotExist()   // history is off: only the opt-in row shows
        compose.onNodeWithText("Keep dictation history on this phone").performClick()
        compose.onNodeWithText("Keep for").assertExists()
        compose.onNodeWithText("Keep audio with notes").assertDoesNotExist()
    }

    @Test fun `an unreachable Mac offers Open Tailscale only when it is installed`() {
        val (state, history, updates) = settingsFixture()
        state.reachable = false
        var opened = 0
        show(state, history, updates, SettingsActions(openTailscale = { opened++ }), SettingsPage.Connection)
        compose.onNodeWithText("Open Tailscale").performClick()
        assertEquals(1, opened)
        compose.runOnIdle { state.reachable = true }
        compose.onNodeWithText("Open Tailscale").assertDoesNotExist()
    }

    @Test fun `without Tailscale installed the unreachable banner has no button`() {
        val (state, history, updates) = settingsFixture()
        state.reachable = false
        show(state, history, updates, SettingsActions(), SettingsPage.Connection)
        compose.onNodeWithText("Open Tailscale").assertDoesNotExist()
    }

    @Test fun `forgetting a pairing asks first - dismiss keeps it and confirm forgets it`() {
        val (state, history, updates) = settingsFixture()
        var forgotten = 0
        show(state, history, updates, SettingsActions(forgetPairing = { forgotten++ }), SettingsPage.Connection)
        compose.onNodeWithText("Forget pairing").performClick()
        compose.onNodeWithText("Forget mac.example.test?").assertExists()
        compose.onNodeWithText("You'll need the QR code to pair again.").assertExists()
        compose.onNodeWithText("Keep pairing").performClick()
        compose.onNodeWithText("Forget mac.example.test?").assertDoesNotExist()
        assertEquals(0, forgotten)
        compose.onNodeWithText("Forget pairing").performClick()
        compose.onNodeWithText("Forget", substring = false).performClick()
        compose.runOnIdle { assertEquals(1, forgotten) }
        compose.onNodeWithText("Forget mac.example.test?").assertDoesNotExist()
    }

    @Test fun `back leaves a detail page for the list, then the list leaves the screen`() {
        val (state, history, updates) = settingsFixture()
        var exits = 0
        show(state, history, updates, onExit = { exits++ })
        val dispatcher = compose.activity.onBackPressedDispatcher
        open(SettingsPage.About)
        compose.onNodeWithText("Copy diagnostics").assertExists()
        compose.runOnIdle { dispatcher.onBackPressed() }
        compose.onNodeWithText("Copy diagnostics").assertDoesNotExist()
        assertEquals(0, exits)
        compose.runOnIdle { dispatcher.onBackPressed() }
        assertEquals(1, exits)
    }

    @Test fun `without an exit handler the list leaves back to the system`() {
        val (state, history, updates) = settingsFixture()
        show(state, history, updates)
        open(SettingsPage.Dictation)
        compose.runOnIdle { assertTrue(compose.activity.onBackPressedDispatcher.hasEnabledCallbacks()) }
        compose.onNodeWithContentDescription("Back").performClick()
        compose.runOnIdle { assertFalse(compose.activity.onBackPressedDispatcher.hasEnabledCallbacks()) }
    }

    @Test fun `the clean-up switch records an explicit choice only when toggled`() {
        val (state, history, updates) = settingsFixture()
        show(state, history, updates)
        open(SettingsPage.Dictation)
        compose.onNodeWithText("Clean-up · Correction on Mac").assertIsDisplayed().assertIsOn()
        compose.onNodeWithText("Polishes punctuation and filler words on your Mac").assertIsDisplayed()
        compose.runOnIdle { assertFalse(context.getSharedPreferences("chirp", 0).contains("correction_explicit")) }
        compose.onNodeWithText("Clean-up · Correction on Mac").performClick()
        compose.runOnIdle { assertFalse(SettingsStore(context).correction); assertTrue(context.getSharedPreferences("chirp", 0).getBoolean("correction_explicit", false)) }
    }

    @Test fun `a Mac with clean-up off says so instead of hiding the feature`() {
        val (state, history, updates) = settingsFixture()
        state.health = Health(true, false, false, false, null)
        show(state, history, updates)
        open(SettingsPage.Dictation)
        compose.onNodeWithText("Mac has clean-up off").assertIsDisplayed()
        compose.onNodeWithText("Clean-up · Correction on Mac").assertDoesNotExist()
    }

    @Test fun `stop dictation no longer promises 119 seconds`() {
        val (state, history, updates) = settingsFixture()
        show(state, history, updates)
        open(SettingsPage.Dictation)
        compose.onNodeWithText("Stop dictation").performScrollTo()
        compose.onNodeWithText("Learn more").performScrollTo().performClick()
        compose.onNodeWithText("Tap the stop button to finish. Either way, a countdown starts 15 seconds before the limit and dictation ends at 10 minutes.").assertExists()
    }

    @Test fun `connection summary reflects pairing and reachability`() {
        assertEquals("Not paired", connectionSummary(false, "", null, false, null).title)
        val health = Health(true, false, true, false, null, engine = "Parakeet")
        assertEquals("Connected · mac.example.test", connectionSummary(true, "mac.example.test", true, false, health).title)
        assertEquals("Parakeet · clean-up on Mac", connectionSummary(true, "mac.example.test", true, false, health).summary)
        assertEquals("Paired · mac.example.test", connectionSummary(true, "mac.example.test", null, false, health).title)
        assertEquals("Checking · mac.example.test", connectionSummary(true, "mac.example.test", true, true, health).title)
        val down = connectionSummary(true, "mac.example.test", false, false, health)
        assertEquals("Mac unreachable · mac.example.test", down.title); assertNotNull(down.hint)
        assertEquals("Mac is loading its speech model", connectionSummary(true, "m", null, false, health.copy(ready = false)).summary)
    }
}
