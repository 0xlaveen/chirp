package dev.chirp.android

import android.app.Activity
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.ContextThemeWrapper
import android.view.View
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import java.io.File
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37], qualifiers = "w411dp-h891dp-mdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class VoiceUiTest {
    @get:Rule val compose = createComposeRule()
    @Test fun `wizard progresses keeps keyboard choice optional and offers connection repair`() {
        val state = SetupState()
        compose.setContent { ChirpTheme { SetupWizard(state) } }
        compose.onNodeWithText("Step 1 of 4 · Microphone").assertIsDisplayed()
        compose.onNodeWithText("Next").performScrollTo().performClick()
        compose.onNodeWithText("Keep Samsung Keyboard").assertExists()
        compose.onNodeWithText("Enable floating microphone").assertExists()
        compose.onNodeWithText("Next").performScrollTo().performClick()
        compose.onNodeWithContentDescription("Private Chirp pairing link").performTextInput("synthetic")
        compose.runOnIdle { assertEquals("synthetic", state.link) }
        compose.onNodeWithText("Next").performScrollTo().performClick()
        compose.onNodeWithText("Mac unreachable — is Tailscale on?").assertExists()
    }
    @Test fun `render setup wizard in light and dark`() {
        val output = File(System.getProperty("chirp.screenshots")).apply { mkdirs() }
        val state = SetupState()
        val dark = mutableStateOf(false)
        compose.setContent { ChirpTheme(dark.value) { SetupWizard(state) } }
        for (night in listOf(false, true)) {
            for (step in 0..3) {
                compose.runOnIdle { dark.value = night; state.step = step }
                compose.waitForIdle()
                val bitmap = compose.onRoot().captureToImage().asAndroidBitmap()
                File(output, "setup-${step + 1}-${if (night) "dark" else "light"}.png").outputStream().use {
                    bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
                }
            }
        }
    }
    @Test fun `render voice states at cover and inner widths in light and dark`() {
        val output = File(System.getProperty("chirp.screenshots")).apply { mkdirs() }
        val controller = Robolectric.buildActivity(Activity::class.java).setup()
        val activity = controller.get()
        try {
            for ((theme, night) in listOf("light" to Configuration.UI_MODE_NIGHT_NO, "dark" to Configuration.UI_MODE_NIGHT_YES)) {
                val config = Configuration(activity.resources.configuration).apply { uiMode = Configuration.UI_MODE_TYPE_NORMAL or night }
                val themed = ContextThemeWrapper(activity.createConfigurationContext(config), R.style.Theme_Chirp)
                for ((name, status, text) in listOf(
                    Triple("idle", "Ready to dictate", ""), Triple("connecting", "Connecting to Mac…", ""),
                    Triple("listening", "Listening…", "Synthetic example for visual review"),
                    Triple("finalizing", "Finishing…", "Synthetic example for visual review"),
                    Triple("error", "Mac unreachable — is Tailscale on?", ""),
                    Triple("raw", "Inserted · raw available for 5 seconds", ""),
                    Triple("debug", "Listening…", "Synthetic example"),
                )) {
                    val view = VoicePanel(themed)
                    view.show(status, text, "Synthetic example", name in listOf("connecting", "listening", "finalizing", "debug"), name == "finalizing")
                    view.level(.45)
                    view.control("Cancel", "Cancel dictation") { }
                    view.control("Keyboard", "Previous keyboard") { }
                    view.control("Fix setup", "Fix connection") { }
                    if (name == "debug") view.banner.retention(true)
                    if (name == "raw") view.raw.visibility = View.VISIBLE
                    val width = if (name == "listening") 700 else 360
                    activity.setContentView(view)
                    view.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(1600, View.MeasureSpec.AT_MOST))
                    view.layout(0, 0, width, view.measuredHeight)
                    val bitmap = Bitmap.createBitmap(width, view.measuredHeight, Bitmap.Config.ARGB_8888)
                    view.draw(Canvas(bitmap))
                    File(output, "panel-$name-$theme.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
                    bitmap.recycle()
                }
            }
            assertTrue(output.listFiles()!!.filter { it.extension == "png" }.sumOf { it.length() } < 2_000_000)
        } finally { controller.pause().stop().destroy() }
    }
}
