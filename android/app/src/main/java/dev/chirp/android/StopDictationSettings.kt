package dev.chirp.android

import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import dev.chirp.android.ui.ChoiceChips
import dev.chirp.android.ui.SettingsGroup
import dev.chirp.android.ui.SettingsItem

/** "When I tap" (default) or "When I pause" with the pause length the Mac offers. Read by the keyboard at each start. */
@Composable
internal fun StopDictationSettings() {
    val context = LocalContext.current
    val store = remember { SettingsStore(context) }
    var onPause by remember { mutableStateOf(store.stopOnPause) }
    var pause by remember { mutableDoubleStateOf(store.pauseSeconds) }
    SettingsGroup("Stop dictation") {
        SettingsItem {
            ChoiceChips(listOf(false, true), onPause, { if (it) "When I pause" else "When I tap" }) { onPause = it; store.stopOnPause = it }
            if (onPause) {
                Text("Pause length", style = MaterialTheme.typography.bodyMedium)
                ChoiceChips(AutoStopDetector.CHOICES, pause, AutoStopDetector::label) { pause = it; store.pauseSeconds = it }
            }
            Text(if (onPause) "Chirp stops after you pause, judged against the room's background noise. It never stops before you speak, and gives up after 10 seconds of silence."
                else "Tap the stop button to finish. Either way, a countdown starts at 15 seconds left and dictation ends at 119 seconds.",
                style = MaterialTheme.typography.bodySmall)
        }
    }
}
