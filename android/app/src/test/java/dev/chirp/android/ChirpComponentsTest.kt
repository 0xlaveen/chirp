package dev.chirp.android

import android.graphics.Bitmap
import androidx.compose.foundation.layout.*
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import dev.chirp.android.settings.SettingsScreen
import dev.chirp.android.ui.*
import dev.chirp.android.ui.ChirpTheme
import java.io.File
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37], qualifiers = "w411dp-h3200dp-mdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class ChirpComponentsTest {
    @get:Rule val compose = createComposeRule()
    private val context = RuntimeEnvironment.getApplication()

    @Composable private fun Gallery() {
        var haptics by remember { mutableStateOf(true) }
        var sounds by remember { mutableStateOf(false) }
        var history by remember { mutableStateOf(false) }
        var stop by remember { mutableStateOf("When I tap") }
        Surface(Modifier.testTag("gallery")) {
            Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                SettingsGroup("Sounds & haptics") {
                    SwitchRow("Haptic cues", haptics, { haptics = it }, summary = "Vibrate on start and stop")
                    SwitchRow("Sound cues", sounds, { sounds = it }, icon = R.drawable.ic_mic)
                }
                SettingsGroup("Privacy") {
                    SwitchRow("Dictation history", history, { history = it }, summary = "Off · on this phone only", icon = R.drawable.ic_history)
                    NavRow("Open history", {}, icon = R.drawable.ic_history)
                    ActionRow("Forget pairing", {}, icon = R.drawable.ic_warning, destructive = true)
                }
                SettingsGroup("Stop dictation") {
                    SettingsItem { ChoiceChips(listOf("When I tap", "When I pause"), stop, { it }) { stop = it } }
                }
                StatusBanner(StatusKind.Info, "Paired · Mac ready", live = true)
                StatusBanner(StatusKind.Success, "Chirp is up to date.")
                StatusBanner(StatusKind.Warning, "Mac unreachable", body = "Check Tailscale is connected on both devices.", action = "Retry")
                StatusBanner(StatusKind.Error, "DEBUG RETENTION IS ON — the Mac may retain audio and text")
                Surface(shape = MaterialTheme.shapes.extraLarge, tonalElevation = 1.dp) {
                    Column(Modifier.padding(top = 24.dp)) {
                        InfoSheetContent("Optional floating microphone", "Off by default. Enable only if you want a floating mic with another keyboard.") {}
                    }
                }
            }
        }
    }

    private fun texts(node: SemanticsNode): List<SemanticsNode> =
        (if (node.config.contains(SemanticsProperties.Text)) listOf(node) else emptyList()) + node.children.flatMap(::texts)

    private fun inside(outer: Rect, inner: Rect) = inner.left >= outer.left - 1 && inner.top >= outer.top - 1 &&
        inner.right <= outer.right + 1 && inner.bottom <= outer.bottom + 1

    @Test fun `render components in Pond and wallpaper colours, light, dark and at 200 percent font`() {
        val output = File(System.getProperty("chirp.screenshots")).apply { mkdirs() }
        val dark = mutableStateOf(false)
        val colour = mutableStateOf(AppColour.POND)
        val fontScale = mutableFloatStateOf(1f)
        compose.setContent {
            CompositionLocalProvider(LocalDensity provides Density(LocalDensity.current.density, fontScale.floatValue)) {
                ChirpTheme(dark.value, colour.value) { Box { Gallery() } }
            }
        }
        for ((name, setting) in listOf("light" to Triple(false, AppColour.POND, 1f), "dark" to Triple(true, AppColour.POND, 1f),
            "dynamic-light" to Triple(false, AppColour.DYNAMIC, 1f), "dynamic-dark" to Triple(true, AppColour.DYNAMIC, 1f), "font-200" to Triple(false, AppColour.DYNAMIC, 2f))) {
            compose.runOnIdle { dark.value = setting.first; colour.value = setting.second; fontScale.floatValue = setting.third }
            compose.waitForIdle()
            val gallery = compose.onNodeWithTag("gallery").fetchSemanticsNode()
            // Every label is laid out in full and sits inside its row, toggle or card: nothing clipped at any font scale.
            compose.onAllNodes(isToggleable().or(hasClickAction()), useUnmergedTree = true).fetchSemanticsNodes().forEach { row ->
                texts(row).forEach { text ->
                    assertTrue("${text.config[SemanticsProperties.Text]} clipped at ${setting.third}x", inside(row.boundsInRoot, text.boundsInRoot))
                }
            }
            texts(gallery).forEach { text ->
                val layout = mutableListOf<TextLayoutResult>()
                text.config.getOrNull(SemanticsActions.GetTextLayoutResult)?.action?.invoke(layout)
                layout.forEach { assertFalse("${text.config[SemanticsProperties.Text]} clipped at ${setting.third}x", it.didOverflowHeight || it.multiParagraph.didExceedMaxLines) }
                assertTrue(inside(gallery.boundsInRoot, text.boundsInRoot))
            }
            // Full-width rows; chips and text buttons keep Material's own 48 dp touch-target expansion around a smaller body.
            compose.onAllNodes(isToggleable().or(hasClickAction())).fetchSemanticsNodes().filter { it.size.width > gallery.size.width / 2 }.forEach {
                assertTrue("${it.config.getOrNull(SemanticsProperties.Text)} is under 48 dp", it.size.height >= 48)
            }
            val bitmap = compose.onNodeWithTag("gallery").captureToImage().asAndroidBitmap()
            if (setting.third == 1f) assertTrue("$name gallery fits one render", bitmap.height < 1800)
            File(output, "components-$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        }
    }

    @Test fun `switch row is one merged switch node read as title then summary, toggled from anywhere on the row`() {
        var checked by mutableStateOf(false)
        compose.setContent { ChirpTheme(colour = AppColour.POND) { SwitchRow("Haptic cues", checked, { checked = it }, summary = "Vibrate on start and stop") } }
        val row = compose.onNode(isToggleable())
        row.assertIsOff().assert(SemanticsMatcher.expectValue(SemanticsProperties.Role, Role.Switch))
            .assert(SemanticsMatcher.expectValue(SemanticsProperties.Text, listOf(AnnotatedString("Haptic cues"), AnnotatedString("Vibrate on start and stop"))))
            .assert(SemanticsMatcher.keyNotDefined(SemanticsProperties.ContentDescription))
            .assertHeightIsAtLeast(56.dp)
        assertEquals("The switch adds no second focusable node", 1, compose.onAllNodes(isToggleable(), useUnmergedTree = true).fetchSemanticsNodes().size)
        row.performTouchInput { click(centerLeft + Offset(8f, 0f)) }
        row.assertIsOn(); assertTrue(checked)
    }

    @Test fun `every switch in settings, HeliBoard's Chirp section and history is a full-row SwitchRow`() {
        val store = SettingsStore(context)
        store.health = Health(true, false, true, false, null)
        val history = DictationHistory(context, SoftwareHistoryKeys()).apply { enable() }
        val state = SetupState().apply { step = 3; paired = true; host = "mac.example.test"; health = store.health }
        val screen = mutableIntStateOf(0)
        compose.setContent { ChirpTheme { when (screen.intValue) { 0 -> SettingsScreen(state); 1 -> ChirpSettingsSection(); else -> androidx.compose.foundation.layout.Column { HistorySettings(store = history) } } } }
        for (index in 0..2) {
            compose.runOnIdle { screen.intValue = index }
            compose.waitForIdle()
            val switches = compose.onAllNodes(isToggleable()).fetchSemanticsNodes()
            assertTrue(switches.size >= if (index == 0) 4 else 1)
            assertEquals("No switch nested inside another toggle", switches.size, compose.onAllNodes(isToggleable(), useUnmergedTree = true).fetchSemanticsNodes().size)
            switches.forEach { node ->
                val label = node.config.getOrNull(SemanticsProperties.Text)
                assertEquals(Role.Switch, node.config.getOrNull(SemanticsProperties.Role))
                assertFalse("Switch without its own label: $label", label.isNullOrEmpty())
                assertFalse(node.config.contains(SemanticsProperties.ContentDescription))
                assertTrue("$label is under 48 dp", node.size.height >= 48)
            }
        }
    }

    @Test fun `app colours default to Pond, and Match wallpaper persists and restyles the app and floating mic`() {
        val store = SettingsStore(context)
        assertEquals(AppColour.POND, store.appColour)
        val wallpaper = dynamicLightColorScheme(context).primary
        assertNotEquals(PondLight.primary, wallpaper)
        var primary = Color.Unspecified
        compose.setContent { ChirpTheme(dark = false) { primary = MaterialTheme.colorScheme.primary; AppColoursSettings() } }
        compose.runOnIdle { assertEquals(PondLight.primary, primary) }
        assertEquals(PondLight.primary.toArgb(), VoicePalette.of(context).accent)
        compose.onNodeWithText("Pond").assertIsSelected()
        compose.onNodeWithText("Match wallpaper").performClick()
        compose.runOnIdle { assertEquals(AppColour.DYNAMIC, SettingsStore(context).appColour); assertEquals(wallpaper, primary) }
        assertEquals(wallpaper.toArgb(), VoicePalette.of(context).accent)
        store.appColour = AppColour.POND
        compose.runOnIdle { assertEquals(PondLight.primary, primary) }
    }

    @Test fun `status banner announces politely and learn more opens and closes its sheet`() {
        compose.setContent { ChirpTheme { Column {
            StatusBanner(StatusKind.Info, "Mac ready", live = true)
            LearnMore("Optional floating microphone", "Synthetic explanation")
        } } }
        compose.onNodeWithText("Mac ready").assert(SemanticsMatcher.expectValue(SemanticsProperties.LiveRegion, LiveRegionMode.Polite))
        compose.onNodeWithText("Learn more").performClick()
        compose.onNodeWithText("Synthetic explanation").assertExists()
        compose.onNodeWithText("Close").performClick()
        compose.onNodeWithText("Synthetic explanation").assertDoesNotExist()
    }
}
