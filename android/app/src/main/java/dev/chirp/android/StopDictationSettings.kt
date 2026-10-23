package dev.chirp.android

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp

/** "When I tap" (default) or "When I pause" with the pause length the Mac offers. Read by the keyboard at each start. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun StopDictationSettings() {
    val context = LocalContext.current
    val store = remember { SettingsStore(context) }
    var onPause by remember { mutableStateOf(store.stopOnPause) }
    var pause by remember { mutableDoubleStateOf(store.pauseSeconds) }
    Text("Stop dictation", style = MaterialTheme.typography.titleSmall)
    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        FilterChip(!onPause, { onPause = false; store.stopOnPause = false }, label = { Text("When I tap") })
        FilterChip(onPause, { onPause = true; store.stopOnPause = true }, label = { Text("When I pause") })
    }
    if (onPause) {
        Text("Pause length", style = MaterialTheme.typography.bodyMedium)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            AutoStopDetector.CHOICES.forEach { choice ->
                FilterChip(pause == choice, { pause = choice; store.pauseSeconds = choice }, label = { Text(AutoStopDetector.label(choice)) })
            }
        }
    }
    Text(if (onPause) "Chirp stops after you pause, judged against the room's background noise. It never stops before you speak, and gives up after 10 seconds of silence."
        else "Tap the stop button to finish. Either way, a countdown starts at 15 seconds left and dictation ends at 119 seconds.",
        style = MaterialTheme.typography.bodySmall)
}
