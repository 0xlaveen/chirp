package dev.chirp.android

import android.graphics.Bitmap
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.text.input.TextFieldValue
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
@Config(sdk = [37], qualifiers = "w411dp-h891dp-mdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class ScratchpadRenderTest {
    @get:Rule val compose = createComposeRule()

    @Test fun `render scratchpad idle listening and edited text in light and dark`() {
        val output = File(System.getProperty("chirp.screenshots")).apply { mkdirs() }
        val rig = Rig(RuntimeEnvironment.getApplication())
        val dark = mutableStateOf(false)
        compose.setContent { ChirpTheme(dark.value) { ScratchpadScreen(rig.model, rig.model::toggle, {}, {}, {}) } }
        fun shot(name: String) {
            compose.waitForIdle()
            val bitmap = compose.onRoot().captureToImage().asAndroidBitmap()
            File(output, "scratchpad-$name-${if (dark.value) "dark" else "light"}.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        }
        for (night in listOf(false, true)) {
            compose.runOnIdle { dark.value = night }
            shot("idle")
            compose.runOnIdle { rig.model.toggle(); rig.wire.ready(); rig.wire.partial(1, "Synthetic example for visual review") }
            shot("listening")
            compose.runOnIdle { rig.model.cancel(); rig.model.field = TextFieldValue("Synthetic example for visual review.") }
            shot("text")
            compose.runOnIdle { rig.model.clear() }
        }
        assertEquals("", rig.model.field.text)
    }
}
