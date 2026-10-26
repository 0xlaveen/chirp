package dev.chirp.android

import android.graphics.Bitmap
import android.text.InputType
import android.view.inputmethod.EditorInfo
import androidx.compose.runtime.*
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import dev.chirp.android.shell.HistoryScreen
import dev.chirp.android.ui.ChirpTheme
import java.io.File
import java.time.ZoneOffset
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** The destination and create-new choice must stay visible, including wrapped titles and large text. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class HistoryActionsRenderTest {
    @get:Rule val compose = createComposeRule()

    private fun render(width: String, fontScale: Float = 1f) {
        RuntimeEnvironment.setFontScale(fontScale)
        val context = RuntimeEnvironment.getApplication()
        val now = 1_800_000_000_000L
        val history = DictationHistory(context, SoftwareHistoryKeys()) { now }
        history.enable()
        history.record("Send the revised draft on Friday", null, "Messages", EditorInfo().apply { inputType = InputType.TYPE_CLASS_TEXT })
        val notes = NotesSessions(context, SoftwareHistoryKeys())
        val title = "Design review and next steps for the autumn release"
        val note = NotesDocument().apply { userEdit(0, 0, "Meeting notes"); name = title }
        check(notes.put(note.uid, note.toJson()))
        val dark = mutableStateOf(false)
        compose.setContent {
            ChirpTheme(dark.value, colour = AppColour.POND) { HistoryScreen(history, { now }, ZoneOffset.UTC, notes = notes) }
        }
        compose.waitUntil(5000) { compose.onAllNodesWithText("Send the revised draft on Friday").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("Send the revised draft on Friday").performTouchInput { longClick() }
        val output = File(System.getProperty("chirp.screenshots")).apply { mkdirs() }
        for (night in listOf(false, true)) {
            compose.runOnIdle { dark.value = night }
            compose.onNodeWithText("Add to latest note (“$title”)").assertIsDisplayed()
            compose.onNodeWithText("Save as new note").assertIsDisplayed()
            val bitmap = compose.onNode(isPopup()).captureToImage().asAndroidBitmap()
            File(output, "history-note-actions-$width-${if (night) "dark" else "light"}.png").outputStream().use {
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
            }
        }
    }

    @Test @Config(qualifiers = "w411dp-h891dp-mdpi") fun `note destinations on the cover screen`() = render("cover")
    @Test @Config(qualifiers = "w840dp-h900dp-mdpi") fun `note destinations on the inner screen`() = render("inner")
    @Test @Config(qualifiers = "w411dp-h891dp-mdpi") fun `note destinations at twice the font size`() = render("large", fontScale = 2f)
}
