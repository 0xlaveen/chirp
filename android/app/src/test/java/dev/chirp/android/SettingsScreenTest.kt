package dev.chirp.android

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
        compose.setContent { ChirpTheme(dynamic = false) { SettingsScreen(state, actions, initialPage, history, updates, onExit) } }

    private fun assertOnce(label: String) = compose.onAllNodesWithText(label).assertCountEquals(1)

    /** Every control reachable before this change, by the label it had; each must exist exactly once across the whole tree. */
    private val tree = linkedMapOf<SettingsPage?, List<String>>(
        null to listOf("Clean-up · Correction on Mac", "Styles", "Stop dictation", "Spoken commands", "Press Send after dictating", "Look", "Swipe typing",
            "Hardware keyboard shortcut", "Larger mic on the inner screen", "Layouts, languages & typing", "Haptic cues", "Sound cues",
            "Dictation history", "Notes", "Floating mic (Accessibility)", "Updates", "Diagnostics"),
        SettingsPage.Connection to listOf("Check connection", "Change pairing", "Forget pairing", "Use this phone's recogniser"),
        SettingsPage.Look to listOf("Keyboard look", "App colours"),
        SettingsPage.SwipeTyping to listOf("Add gesture library…"),
        SettingsPage.History to listOf("Keep dictation history on this phone"),
        SettingsPage.Notes to listOf("Save battery while the screen is off", "Keep a recovery copy until notes are saved", "Keep notes on this phone"),
        SettingsPage.FloatingMic to listOf("Turn on floating mic"),
        SettingsPage.Updates to listOf("Check for updates"),
        SettingsPage.Diagnostics to listOf("Debug overlay (timings only)", "Copy diagnostics", "Clear timings"),
    )

    @Test fun `every setting is reachable from the list exactly once, and back returns to the list`() {
        val (state, history, updates) = settingsFixture()
        show(state, history, updates)
        val rows = mapOf(SettingsPage.Connection to "Connected · mac.example.test", SettingsPage.Look to "Look", SettingsPage.SwipeTyping to "Swipe typing",
            SettingsPage.History to "Dictation history", SettingsPage.Notes to "Notes", SettingsPage.FloatingMic to "Floating mic (Accessibility)", SettingsPage.Updates to "Updates",
            SettingsPage.Diagnostics to "Diagnostics")
        tree.getValue(null).forEach(::assertOnce)
        for ((page, row) in rows) {
            compose.onNodeWithText(row).performScrollTo().performClick()
            assertTrue(compose.onAllNodes(hasText(page.title).and(SemanticsMatcher.keyIsDefined(SemanticsProperties.Heading))).fetchSemanticsNodes().isNotEmpty())
            tree.getValue(page).forEach { label -> assertTrue("$label missing on ${page.title}", compose.onAllNodesWithText(label).fetchSemanticsNodes().isNotEmpty()) }
            compose.onNodeWithContentDescription("Back").performClick()
            compose.onAllNodesWithText("Settings")[0].assertExists()
            assertOnce("Updates")
        }
    }

    @Test fun `every detail page fits one screen at 100 percent font`() {
        val (state, history, updates) = settingsFixture()
        val shown = androidx.compose.runtime.mutableStateOf(SettingsPage.entries.first())
        compose.setContent { ChirpTheme(dynamic = false) { androidx.compose.runtime.key(shown.value) {
            SettingsScreen(state, SettingsActions(), shown.value, history, updates) } } }
        for (page in SettingsPage.entries) {
            compose.runOnIdle { shown.value = page }
            compose.waitForIdle()
            val scroll = compose.onAllNodes(SemanticsMatcher.keyIsDefined(SemanticsProperties.VerticalScrollAxisRange)).fetchSemanticsNodes().first()
            assertEquals("${page.title} scrolls", 0f, scroll.config[SemanticsProperties.VerticalScrollAxisRange].maxValue(), 0.5f)
        }
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
        compose.onNodeWithText("Diagnostics").performScrollTo().performClick()
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
        compose.onNodeWithText("Floating mic (Accessibility)").performScrollTo().performClick()
        compose.runOnIdle { assertTrue(compose.activity.onBackPressedDispatcher.hasEnabledCallbacks()) }
        compose.onNodeWithContentDescription("Back").performClick()
        compose.runOnIdle { assertFalse(compose.activity.onBackPressedDispatcher.hasEnabledCallbacks()) }
    }

    @Test fun `clean-up sits at the top of the Dictation group and only its toggle records an explicit choice`() {
        val (state, history, updates) = settingsFixture()
        show(state, history, updates)
        compose.onNodeWithText("Clean-up · Correction on Mac").assertIsDisplayed().assertIsOn()
        compose.onNodeWithText("Polishes punctuation and filler words on your Mac; text never leaves it").assertIsDisplayed()
        compose.onNodeWithText("Haptic cues").performScrollTo().performClick()
        compose.runOnIdle { assertFalse(context.getSharedPreferences("chirp", 0).contains("correction_explicit")) }
        compose.onNodeWithText("Clean-up · Correction on Mac").performScrollTo().performClick()
        compose.runOnIdle { assertFalse(SettingsStore(context).correction); assertTrue(context.getSharedPreferences("chirp", 0).getBoolean("correction_explicit", false)) }
    }

    @Test fun `a Mac with clean-up off says so instead of hiding the feature`() {
        val (state, history, updates) = settingsFixture()
        state.health = Health(true, false, false, false, null)
        show(state, history, updates)
        compose.onNodeWithText("Mac has clean-up off").assertIsDisplayed()
        compose.onNodeWithText("Clean-up · Correction on Mac").assertDoesNotExist()
    }

    @Test fun `stop dictation no longer promises 119 seconds`() {
        val (state, history, updates) = settingsFixture()
        show(state, history, updates)
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
