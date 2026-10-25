package dev.chirp.android

import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.ContextThemeWrapper
import android.view.View
import android.widget.FrameLayout
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.File

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37], qualifiers = "w360dp-h800dp-mdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class QuickDictateRenderTest {
    @get:Rule val compose = createComposeRule()
    private val app get() = RuntimeEnvironment.getApplication()
    private fun write(bitmap: Bitmap, name: String) {
        File(System.getProperty("chirp.screenshots"), "$name.png").apply { parentFile.mkdirs() }
            .outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }
    private fun render(screen: String) {
        android.provider.Settings.Global.putFloat(app.contentResolver, android.provider.Settings.Global.ANIMATOR_DURATION_SCALE, 0f)
        val night = mutableStateOf(false)
        val share = mutableStateOf(false)
        val current = mutableStateOf(QuickRig(app))
        compose.setContent { ChirpTheme(night.value) {
            Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.surfaceContainer)) {
                if (share.value) ShareToNotesDialog("Synthetic meeting", null, true, {}, {}, {})
                else QuickDictateScreen(current.value.model)
            }
        } }
        for (dark in listOf(false, true)) {
            compose.runOnIdle { night.value = dark; share.value = false; current.value = QuickRig(app); current.value.model.start(); current.value.wire.ready()
                current.value.wire.event(ServerEvent.Partial(1, "Synthetic words appear as you speak", "Synthetic words appear")) }
            compose.onNodeWithText("Listening…").assertExists()
            write(compose.onRoot().captureToImage().asAndroidBitmap(), "quick-dictate-listening-$screen-${if (dark) "dark" else "light"}")
            compose.runOnIdle { current.value.model.stop(); org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle(); current.value.wire.final("Synthetic words appear as you speak.", "synthetic words", true) }
            compose.onNodeWithText("Copied — paste anywhere").assertExists()
            compose.onNodeWithContentDescription("Use raw, available for 4 seconds").assertExists()
            write(compose.onRoot().captureToImage().asAndroidBitmap(), "quick-dictate-copied-$screen-${if (dark) "dark" else "light"}")
            compose.runOnIdle { current.value = QuickRig(app, paired = false); current.value.model.start() }
            compose.onNodeWithText("Pair Mac").assertExists()
            write(compose.onRoot().captureToImage().asAndroidBitmap(), "quick-dictate-error-$screen-${if (dark) "dark" else "light"}")
            compose.runOnIdle { share.value = true }
            compose.onNodeWithText("Save as new note").assertExists()
            write(compose.onNode(isDialog()).captureToImage().asAndroidBitmap(), "share-to-notes-dialog-$screen-${if (dark) "dark" else "light"}")
            val config = Configuration(app.resources.configuration).apply {
                uiMode = Configuration.UI_MODE_TYPE_NORMAL or if (dark) Configuration.UI_MODE_NIGHT_YES else Configuration.UI_MODE_NIGHT_NO
            }
            val themed = ContextThemeWrapper(app.createConfigurationContext(config), R.style.Theme_Chirp)
            for (width in listOf(80, 240)) {
                val widget = ChirpWidgetProvider.views(themed, width).apply(themed, FrameLayout(themed))
                widget.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(112, View.MeasureSpec.EXACTLY))
                widget.layout(0, 0, width, 112)
                write(Bitmap.createBitmap(width, 112, Bitmap.Config.ARGB_8888).also { widget.draw(Canvas(it)) },
                    "quick-dictate-widget-${if (width < 150) "1x1" else "2x1"}-$screen-${if (dark) "dark" else "light"}")
            }
        }
    }
    @Test fun `cover light and dark entry surfaces`() = render("cover")
    @Test @Config(qualifiers = "w720dp-h840dp-mdpi") fun `inner light and dark entry surfaces`() = render("inner")
    @Test fun `canceling auto close removes the countdown from the retained raw action`() {
        android.provider.Settings.Global.putFloat(app.contentResolver, android.provider.Settings.Global.ANIMATOR_DURATION_SCALE, 0f)
        val rig = QuickRig(app)
        compose.setContent { ChirpTheme { QuickDictateScreen(rig.model) } }
        compose.runOnIdle { rig.model.start(); rig.finish() }
        compose.onNodeWithContentDescription("Use raw, available for 4 seconds").assertExists()
        compose.runOnIdle { rig.model.closeAt = null }
        compose.onNodeWithContentDescription("Use raw").assertExists()
        compose.onAllNodesWithText("Use raw (4s)").assertCountEquals(0)
    }

}
