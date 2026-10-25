package dev.chirp.android

import android.graphics.Bitmap
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import java.io.File
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * The Scratchpad's style row with every style the Mac can advertise (Raw, Default, Chat, Email, Code, Notes, Custom) on the
 * 360 dp cover screen and at 200% font (#174). The old connected button group squeezed these into two-line broken words
 * ("Defa/ult"); the chip row keeps each label on one line and scrolls.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37], qualifiers = "w360dp-h780dp-xhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class ScratchpadStylesRenderTest {
    @get:Rule val compose = createComposeRule()

    private val styles = listOf("Default", "Chat", "Email", "Code", "Notes").map { CorrectionProfile(it.lowercase(), it) }
    private val health = Health(true, false, true, false, null, "synthetic", styles)
    private val labels = listOf("Raw") + styles.map { it.name } + "Custom"

    private fun lineCount(label: String): Int {
        val layout = mutableListOf<TextLayoutResult>()
        compose.onNode(hasText(label) and hasAnyAncestor(hasTestTag("style-chips")), useUnmergedTree = true)
            .fetchSemanticsNode().config[SemanticsActions.GetTextLayoutResult].action?.invoke(layout)
        return layout.single().lineCount
    }

    @Test fun `seven styles stay one line each on the cover screen at normal and 200 percent font, and the chosen one scrolls into view`() {
        val output = File(System.getProperty("chirp.screenshots")).apply { mkdirs() }
        val rig = Rig(RuntimeEnvironment.getApplication(), health = health)
        assertEquals(labels, listOf("Raw") + rig.model.profiles.map { it.name })
        val dark = mutableStateOf(false)
        val fontScale = mutableFloatStateOf(1f)
        compose.setContent {
            CompositionLocalProvider(LocalDensity provides Density(LocalDensity.current.density, fontScale.floatValue)) {
                ChirpTheme(dark.value) { Box(Modifier.width(360.dp).height(780.dp)) { ScratchpadScreen(rig.model, rig.model::toggle, {}, {}, {}) } }
            }
        }
        for ((name, night, font) in listOf(Triple("light", false, 1f), Triple("dark", true, 1f), Triple("font-200", false, 2f))) {
            compose.runOnIdle { dark.value = night; fontScale.floatValue = font; rig.model.choose(null) }
            compose.waitForIdle()
            // Every label that is laid out is one line; the chip row is horizontally scrollable, not squeezed.
            compose.onNodeWithTag("style-chips").assertExists()
            labels.filter { label -> compose.onAllNodes(hasText(label) and hasAnyAncestor(hasTestTag("style-chips")), useUnmergedTree = true)
                .fetchSemanticsNodes().isNotEmpty() }.forEach { label -> assertEquals("$label wraps at ${font}x", 1, lineCount(label)) }
            compose.onNode(hasText("Raw") and hasAnyAncestor(hasTestTag("style-chips")), useUnmergedTree = true).assertIsDisplayed()
            compose.onRoot().captureToImage().asAndroidBitmap().let { bitmap ->
                File(output, "scratchpad-styles-cover-$name-raw.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            }
            // Picking the last style brings it fully into view, whatever the width.
            compose.runOnIdle { rig.model.choose(rig.model.profiles.last()) }
            compose.waitForIdle()
            val chips = compose.onNodeWithTag("style-chips").fetchSemanticsNode().boundsInRoot
            val custom = compose.onNode(hasText("Custom") and hasAnyAncestor(hasTestTag("style-chips")), useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
            assertTrue("Custom is cut off at ${font}x: $custom in $chips", custom.left >= chips.left - 1 && custom.right <= chips.right + 1)
            assertEquals("Custom wraps at ${font}x", 1, lineCount("Custom"))
            compose.onRoot().captureToImage().asAndroidBitmap().let { bitmap ->
                File(output, "scratchpad-styles-cover-$name-custom.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            }
        }
    }

    @Test fun `choosing a chip chooses that style and Raw turns clean-up off`() {
        val rig = Rig(RuntimeEnvironment.getApplication(), health = health)
        compose.setContent { ChirpTheme(false) { Box(Modifier.width(360.dp).height(780.dp)) { ScratchpadScreen(rig.model, rig.model::toggle, {}, {}, {}) } } }
        compose.onNode(hasText("Code") and hasAnyAncestor(hasTestTag("style-chips")), useUnmergedTree = true).performClick()
        compose.runOnIdle { assertEquals("code", rig.model.style.id); assertTrue(rig.model.cleanup) }
        compose.onNodeWithTag("style-chips").performScrollToNode(hasText("Raw"))
        compose.onNode(hasText("Raw") and hasAnyAncestor(hasTestTag("style-chips")), useUnmergedTree = true).performClick()
        compose.runOnIdle { assertFalse(rig.model.cleanup) }
    }
}
