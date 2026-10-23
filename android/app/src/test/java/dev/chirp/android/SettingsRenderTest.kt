package dev.chirp.android

import android.graphics.Bitmap
import androidx.compose.runtime.*
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.Density
import dev.chirp.android.settings.SettingsPage
import dev.chirp.android.settings.SettingsScreen
import dev.chirp.android.ui.ChirpTheme
import java.io.File
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** Renders the settings tree to docs/screenshots/android/settings-*.png: cover width, Fold inner width (two panes), light, dark and 200% font. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37], qualifiers = "w411dp-h891dp-mdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class SettingsRenderTest {
    @get:Rule val compose = createComposeRule()
    private val output = File(System.getProperty("chirp.screenshots")).apply { mkdirs() }

    private fun save(name: String, cropAt: String? = null) {
        compose.waitForIdle()
        var bitmap = compose.onRoot().captureToImage().asAndroidBitmap()
        val first = bitmap.getPixel(0, 0)
        assertTrue("$name is blank", (0 until bitmap.height step 7).any { y -> (0 until bitmap.width step 7).any { x -> bitmap.getPixel(x, y) != first } })
        if (cropAt != null) {
            val bottom = compose.onAllNodesWithText(cropAt).fetchSemanticsNodes().last().boundsInRoot.bottom.toInt() + 64
            bitmap = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, minOf(bottom, bitmap.height))
        }
        File(output, "settings-$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }

    private val page = mutableStateOf<SettingsPage?>(null)
    private val dark = mutableStateOf(false)
    private val fontScale = mutableFloatStateOf(1f)

    private fun start() {
        val (state, history, updates) = settingsFixture()
        compose.setContent {
            CompositionLocalProvider(LocalDensity provides Density(LocalDensity.current.density, fontScale.floatValue)) {
                ChirpTheme(dark.value, dynamic = false) { key(page.value) { SettingsScreen(state, initialPage = page.value, history = history, updates = updates) } }
            }
        }
    }

    private fun shot(prefix: String, shown: SettingsPage?, night: Boolean, font: Float = 1f, cropAt: String? = null) {
        compose.runOnIdle { page.value = shown; dark.value = night; fontScale.floatValue = font }
        save("$prefix-${if (night) "dark" else "light"}", cropAt)
    }

    @Config(qualifiers = "w411dp-h2400dp-mdpi") @Test fun `top level in light and dark`() {
        start()
        for (night in listOf(false, true)) shot("top", null, night, cropAt = "Diagnostics")
    }

    @Config(qualifiers = "w411dp-h5000dp-mdpi") @Test fun `top level at 200 percent font`() {
        start()
        shot("top-font-200", null, false, 2f, cropAt = "Diagnostics")
    }

    @Test fun `every detail page in light and dark`() {
        start()
        for (shown in SettingsPage.entries) for (night in listOf(false, true)) shot(shown.name.lowercase(), shown, night)
    }

    @Config(qualifiers = "w840dp-h900dp-mdpi") @Test fun `Fold inner screen shows the list and the detail side by side`() {
        start()
        for (night in listOf(false, true)) shot("two-pane", null, night)
        compose.onAllNodesWithContentDescription("Back").assertCountEquals(0)
        compose.onNodeWithText("Mac connection").assertExists()
        compose.onNodeWithText("Updates").performScrollTo().performClick()
        compose.onNodeWithText("Check for updates").assertExists()
        compose.onNodeWithText("Diagnostics").assertExists()
        shot("two-pane-updates", SettingsPage.Updates, false)
    }
}
