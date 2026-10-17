package dev.chirp.android

import android.text.InputType
import android.view.inputmethod.EditorInfo
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.io.File

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37])
class HistoryScreenTest {
    @get:Rule val compose = createComposeRule()
    private val context = RuntimeEnvironment.getApplication()
    private val now = 1_800_000_000_000L
    private val store = DictationHistory(context, SoftwareHistoryKeys()) { now }
    private val text = EditorInfo().apply { inputType = InputType.TYPE_CLASS_TEXT }

    @Test fun `search filters entries and turning history off confirms then deletes`() {
        store.enable()
        store.record("Meet at the pier at noon", null, "Messages", text)
        store.record("Draft the quarterly summary", "draft the uh quarterly summary", "Gmail", text)
        compose.setContent { ChirpTheme { HistoryScreen(store) { now } } }
        // The list is lazy: scroll entries into composition before asserting on them.
        fun reveal(text: String) = compose.waitUntil(5000) {
            try { compose.onNode(hasScrollAction()).performScrollToNode(hasText(text)); true } catch (_: AssertionError) { false }
        }
        reveal("Before clean-up: draft the uh quarterly summary")
        reveal("Search history")
        compose.onNodeWithText("Search history").performTextInput("pier")
        reveal("Meet at the pier at noon")
        compose.onNodeWithText("Draft the quarterly summary").assertDoesNotExist()
        compose.onNode(hasScrollAction()).performScrollToNode(hasContentDescription("Dictation history"))
        compose.onNodeWithContentDescription("Dictation history").performClick()
        compose.onNodeWithText("Turn off dictation history?").assertExists()
        compose.onNodeWithText("Turn off and delete").performClick()
        compose.waitUntil(5000) { !store.enabled && !File(context.filesDir, DictationHistory.FILE_NAME).exists() }
        compose.waitUntil(5000) { compose.onAllNodesWithText("Meet at the pier at noon").fetchSemanticsNodes().isEmpty() }
    }

    @Test fun `settings switch is off by default and turning on offers retention`() {
        store.disable()
        compose.setContent { ChirpTheme { androidx.compose.foundation.layout.Column { HistorySettings(store = store) } } }
        compose.onNodeWithContentDescription("Dictation history").assertIsOff().performClick()
        assertTrue(store.enabled)
        compose.onNodeWithText("7 days").assertIsSelected()
        compose.onNodeWithText("24 hours").performClick()
        compose.waitUntil(5000) { store.retention == HistoryRetention.DAY }
        compose.onNodeWithText("Clear history").assertExists()
    }
}
