package dev.chirp.android

import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import dev.chirp.android.ui.ChoiceChips
import dev.chirp.android.ui.LearnMore
import dev.chirp.android.ui.SettingsItem

/** One row for a Dictation group: "When I tap" (default) or "When I pause" with the pause length the Mac offers. Read by the keyboard at each start. */
@Composable
internal fun StopDictationSettings() {
    val context = LocalContext.current
    val store = remember { SettingsStore(context) }
    var onPause by remember { mutableStateOf(store.stopOnPause) }
    var pause by remember { mutableDoubleStateOf(store.pauseSeconds) }
    SettingsItem {
        Text("Stop dictation", style = MaterialTheme.typography.bodyLarge)
        ChoiceChips(listOf(false, true), onPause, { if (it) "When I pause" else "When I tap" }) { onPause = it; store.stopOnPause = it }
        if (onPause) {
            Text("Pause length", style = MaterialTheme.typography.bodyMedium)
            ChoiceChips(AutoStopDetector.CHOICES, pause, AutoStopDetector::label) { pause = it; store.pauseSeconds = it }
        }
        LearnMore("Stop dictation", if (onPause) "Chirp stops after you pause, judged against the room's background noise. It never stops before you speak, and gives up after 10 seconds of silence. " +
            "Either way, dictation ends at 10 minutes."
            else "Tap the stop button to finish. Either way, a countdown starts 15 seconds before the limit and dictation ends at 10 minutes.")
    }
}
