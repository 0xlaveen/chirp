package dev.chirp.android

import android.content.Intent
import android.os.Looper
import android.text.InputType
import android.view.inputmethod.EditorInfo
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.unit.dp
import dev.chirp.android.shell.*
import dev.chirp.android.ui.ChirpTheme
import dev.chirp.android.ui.StatusKind
import org.junit.After
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.android.controller.ActivityController
import java.time.ZoneOffset

class HomeStatusTest {
    private val health = Health(true, false, true, false, null, engine = "Parakeet")
    private fun status(paired: Boolean = true, microphone: Boolean = true, tailscaleOff: Boolean = false, checking: Boolean = false,
                       reachable: Boolean? = true, failure: ConnectionFailure.Kind? = null, health: Health? = this.health) =
        homeStatus(paired, "mac.example.test", microphone, tailscaleOff, checking, reachable, failure, health)

    @Test fun `each state has its card and one fix, most blocking first`() {
        val table = listOf(
            status() to Triple(StatusKind.Success, "Mac connected", null),
            status(paired = false, microphone = false, tailscaleOff = true, reachable = false) to Triple(StatusKind.Warning, "Not paired", HomeFix.Pair),
            status(microphone = false, tailscaleOff = true) to Triple(StatusKind.Warning, "Microphone is off", HomeFix.Microphone),
            status(tailscaleOff = true, reachable = false) to Triple(StatusKind.Warning, "Tailscale is off", HomeFix.TailscaleOn),
            status(reachable = false, failure = ConnectionFailure.Kind.DOWN) to Triple(StatusKind.Warning, "Mac offline", HomeFix.Retry),
            status(checking = true, reachable = false) to Triple(StatusKind.Info, "Checking your Mac…", null),
            status(health = health.copy(ready = false)) to Triple(StatusKind.Info, "Mac is loading its speech model", null),
            status(reachable = null) to Triple(StatusKind.Info, "Paired", HomeFix.Retry),
        )
        table.forEach { (shown, expected) -> assertEquals(expected, Triple(shown.kind, shown.title, shown.fix)) }
        assertEquals("mac.example.test · Parakeet", status().body)
        assertEquals("Mac may be asleep, or Chirp isn't running", status(reachable = false, failure = ConnectionFailure.Kind.DOWN).body)
        assertEquals("Mac unreachable — is Tailscale on?", status(reachable = false).body)
        assertEquals("Turn it on to reach your Mac", status(tailscaleOff = true).body)
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37])
class LauncherRoutingTest {
    class Launch : SetupActivity() {
        val fake = TailscalePromptTest.FakeTailscale()
        override val tailscale: TailscaleControl get() = fake
        var recentsScreenshots: Boolean? = null
        override fun setRecentsScreenshotEnabled(enabled: Boolean) { recentsScreenshots = enabled; super.setRecentsScreenshotEnabled(enabled) }
        override suspend fun checkMac(call: okhttp3.Call): Health = kotlinx.coroutines.awaitCancellation()
    }
    private val app get() = RuntimeEnvironment.getApplication()
    private var controller: ActivityController<Launch>? = null
    private fun launch(intent: Intent? = null): Launch = Robolectric.buildActivity(Launch::class.java, intent).also { controller = it }.setup().get()
    @After fun tearDown() { controller?.let { if (!it.get().isDestroyed) it.pause().stop().destroy() } }
    /** Runs the next frames too, so a state change has recomposed (and registered its back handlers). */
    private fun idle() = shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(100))

    @Test fun `the launcher opens onboarding until setup is complete, then Home`() {
        SettingsStore(app).onboarded = false
        val first = launch()
        assertFalse(first.state.shellOpen); assertEquals(PAGE_WELCOME, first.state.step)
        assertEquals("the whole app stays out of the Recents thumbnail", false, first.recentsScreenshots)
        controller!!.pause().stop().destroy()
        SettingsStore(app).onboarded = true
        val later = launch()
        assertTrue(later.state.shellOpen); assertEquals(ShellTab.Home, later.state.tab); assertFalse(later.state.exitOnBack)
        assertTrue("first run: Try it on Home", later.state.tryIt)
        assertEquals(false, later.recentsScreenshots)
    }

    @Test fun `Home's fixes act on the card's state`() {
        SettingsStore(app).onboarded = true
        val activity = launch()
        activity.fix(HomeFix.TailscaleOn)
        assertEquals(1, activity.fake.connects); assertEquals("Connecting Tailscale…", activity.state.status)
        activity.fix(HomeFix.Pair)
        assertFalse(activity.state.shellOpen); assertEquals(PAGE_PAIR, activity.state.step); assertTrue(activity.state.pairFromShell)
        activity.state.micDenied = true
        activity.fix(HomeFix.Microphone)
        assertEquals(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS, shadowOf(activity).nextStartedActivity.action)
    }

    @Test fun `the keyboard's history link is a thin deep link into the History tab`() {
        val history = Robolectric.buildActivity(HistoryActivity::class.java).setup().get()
        assertTrue(history.isFinishing)
        val forwarded = shadowOf(history).nextStartedActivity
        assertEquals(SetupActivity::class.java.name, forwarded.component?.className); assertEquals("history", forwarded.getStringExtra("section"))
        SettingsStore(app).onboarded = true
        val shell = launch(forwarded)
        assertEquals(ShellTab.History, shell.state.tab)
        idle(); shell.onBackPressedDispatcher.onBackPressed()
        assertTrue("opened from the keyboard: back returns there", shell.isFinishing)
    }
}

/** The real activity under a compose rule, so its back handlers are composed. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37], qualifiers = "w411dp-h891dp-mdpi")
class ShellBackTest {
    @get:Rule val compose = createAndroidComposeRule<SetupActivity>()

    @Test fun `back from the pair page opened from Home returns to the shell, and Home's tiles switch tabs`() {
        val activity = compose.activity
        compose.runOnIdle { activity.state.apply { inputEnabled = true; inputSelected = true; mic = true; paired = true }; activity.advance() }
        compose.onNode(hasText("Notes") and hasText("Live Notes") and hasClickAction()).assertExists()
        compose.runOnIdle { activity.fix(HomeFix.Pair) }
        compose.waitForIdle()
        compose.runOnIdle { activity.onBackPressedDispatcher.onBackPressed() }
        assertTrue("back from the pair page returns to the shell", activity.state.shellOpen); assertFalse(activity.isFinishing)
        compose.onNode(hasText("History") and isSelectable()).performClick()
        compose.onNodeWithText("Dictation history is off").assertExists()
        compose.runOnIdle { activity.onBackPressedDispatcher.onBackPressed() }
        assertEquals(ShellTab.Home, activity.state.tab); assertFalse(activity.isFinishing)
        compose.onNode(hasText("Notes") and hasText("Live Notes") and hasClickAction()).performClick()
        assertEquals(ShellTab.Notes, activity.state.tab)
        compose.onNodeWithContentDescription("Record notes").assertExists()
        assertSame("the tab and NotesActivity share one session", NotesSessionHolder.current, NotesSessionHolder.model(activity) { error("already created") })
        compose.runOnIdle { activity.onBackPressedDispatcher.onBackPressed() }
        assertEquals("Back from Notes goes Home without asking to discard", ShellTab.Home, activity.state.tab)
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37], qualifiers = "w411dp-h891dp-mdpi")
class AppShellTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private val tab = mutableStateOf(ShellTab.Home)
    private val exit = mutableStateOf(false)
    private val page = mutableStateOf(false)

    private fun show() = compose.setContent {
        ChirpTheme(dynamic = false) {
            AppShell(tab.value, { tab.value = it; exit.value = false }, exit.value) { shown ->
                if (shown == ShellTab.Settings) BackHandler(enabled = page.value) { page.value = false }
                Text("${shown.label} content" + if (page.value) " page" else "")
            }
        }
    }
    private fun item(label: String) = compose.onNode(hasText(label) and isSelectable())
    private fun back() = compose.runOnIdle { compose.activity.onBackPressedDispatcher.onBackPressed() }

    @Test fun `the bar is labelled and Back pops within the tab, then goes Home, then leaves`() {
        show()
        ShellTab.entries.forEach { item(it.label).assertExists() }
        item("Home").assertIsSelected()
        val root = compose.onRoot().fetchSemanticsNode().boundsInRoot
        assertTrue("a bottom bar on the cover screen", item("Home").fetchSemanticsNode().boundsInRoot.top > root.height * .8f)
        item("Settings").performClick()
        compose.runOnIdle { page.value = true }
        compose.onNodeWithText("Settings content page").assertExists()
        back(); compose.onNodeWithText("Settings content").assertExists(); assertEquals(ShellTab.Settings, tab.value)
        back(); assertEquals(ShellTab.Home, tab.value); compose.onNodeWithText("Home content").assertExists()
        assertFalse(compose.activity.isFinishing)
        back(); assertTrue(compose.activity.isFinishing)
    }

    @Test fun `tabs keep their place while hidden`() {
        show()
        item("Notes").performClick(); compose.onNodeWithText("Notes content").assertExists()
        item("History").performClick(); item("History").assertIsSelected(); compose.onNodeWithText("Notes content").assertDoesNotExist()
    }

    @Test fun `opened from outside, Back from the tab leaves at once`() {
        tab.value = ShellTab.History; exit.value = true
        show()
        back(); assertTrue(compose.activity.isFinishing)
    }

    @Config(qualifiers = "w840dp-h900dp-mdpi") @Test fun `the inner screen has a rail`() {
        show()
        val home = item("Home").fetchSemanticsNode().boundsInRoot
        val settings = item("Settings").fetchSemanticsNode().boundsInRoot
        assertTrue("a rail down the start edge", home.right < 120f && settings.top > home.bottom)
        assertTrue("content beside the rail", compose.onNodeWithText("Home content").fetchSemanticsNode().boundsInRoot.left >= home.right)
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37], qualifiers = "w411dp-h1600dp-mdpi")
class HomeScreenTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private val context = RuntimeEnvironment.getApplication()
    private val now = 1_800_000_000_000L
    private val history = DictationHistory(context, SoftwareHistoryKeys()) { now }
    private val opened = mutableListOf<String?>()
    private val fixes = mutableListOf<HomeFix>()
    private var dictated = 0
    private var historySettings = 0

    private fun show(state: SetupState) = compose.setContent {
        ChirpTheme(dynamic = false) {
            HomeScreen(state, HomeActions(fix = { fixes += it }, dictate = { dictated++ }, history = { opened += it }, historySettings = { historySettings++ }),
                history, now = { now }, zone = ZoneOffset.UTC)
        }
    }

    @Test fun `tiles are one label each, the connection card is a polite live region with its fix`() {
        val (state) = settingsFixture()
        state.mic = true; state.tailscaleOff = true
        show(state)
        compose.onNodeWithText("Good morning").assertExists()
        val dictate = compose.onNode(hasText("Dictate") and hasText("Scratchpad") and hasClickAction())
        dictate.assertExists().assertHeightIsAtLeast(48.dp).performClick()
        assertEquals(1, dictated)
        compose.onNode(hasText("Notes") and hasText("Live Notes") and hasClickAction()).assertExists()
        val card = compose.onNode(hasText("Tailscale is off") and SemanticsMatcher.expectValue(SemanticsProperties.LiveRegion, LiveRegionMode.Polite))
        card.assertExists().assert(hasText("Turn it on to reach your Mac"))
        compose.onAllNodesWithText("Turn on")[0].performClick()
        assertEquals(listOf(HomeFix.TailscaleOn), fixes)
        compose.runOnIdle { state.tailscaleOff = false; state.reachable = false; state.failure = ConnectionFailure.Kind.DNS }
        compose.onNodeWithText("Mac offline").assertExists()
        compose.onNodeWithText("Check again").performClick()
        assertEquals(HomeFix.Retry, fixes.last())
        compose.runOnIdle { state.paired = false }
        compose.onNodeWithText("Pair Mac").performClick()
        assertEquals(HomeFix.Pair, fixes.last())
    }

    @Test fun `recent dictations show only with history on, otherwise a one-line opt-in`() {
        history.disable()
        val (state) = settingsFixture()
        show(state)
        compose.onNodeWithText("Keep recent dictations here, encrypted on this phone").assertExists()
        compose.onNodeWithText("Turn on").performClick()
        assertEquals(1, historySettings)
    }

    @Test fun `recent dictations open in History and copy privately`() {
        history.enable()
        val info = EditorInfo().apply { inputType = InputType.TYPE_CLASS_TEXT }
        listOf("One", "Two", "Three", "Four").forEach { history.record("Synthetic $it", null, "Messages", info) }
        val (state) = settingsFixture()
        show(state)
        compose.waitUntil(5000) { compose.onAllNodesWithText("Synthetic Four").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("Synthetic One").assertDoesNotExist()
        compose.onNodeWithText("Synthetic Three").performClick()
        assertEquals(history.entries()[1].id, opened.single())
        compose.onNodeWithText("All").performClick()
        assertEquals(null, opened.last())
        compose.onAllNodesWithContentDescription("Copy")[0].performClick()
        val clip = context.getSystemService(android.content.ClipboardManager::class.java).primaryClip!!
        assertEquals("Synthetic Four", clip.getItemAt(0).text.toString())
        assertTrue(clip.description.extras!!.getBoolean("android.content.extra.IS_SENSITIVE"))
        history.disable()
    }

    @Test fun `the first-run Try it card sits on Home until it is dismissed for good`() {
        val (state) = settingsFixture()
        state.tryIt = true
        show(state)
        compose.onNodeWithText("Try it").assertIsDisplayed()
        compose.onNodeWithText("Choose keyboard").assertExists()
        compose.onNodeWithText("Dismiss").performScrollTo().performClick()
        compose.onNodeWithText("Try it").assertDoesNotExist()
        assertFalse(state.tryIt); assertTrue(SettingsStore(context).tryItDismissed)
    }
}
