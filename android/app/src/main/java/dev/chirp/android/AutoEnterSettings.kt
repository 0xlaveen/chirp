package dev.chirp.android

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.unit.dp
import androidx.compose.ui.platform.LocalContext

/** "Press Send after dictating": Off, Always, or in chat apps only (the apps set to the Chat style). Read at each dictation. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun AutoEnterSettings() {
    val store = SettingsStore(LocalContext.current)
    var mode by remember { mutableStateOf(store.autoEnter) }
    Text("Press Send after dictating", style = MaterialTheme.typography.titleSmall)
    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        AutoEnterMode.entries.forEach { choice ->
            FilterChip(mode == choice, { mode = choice; store.autoEnter = choice }, label = { Text(choice.label) })
        }
    }
    Text("After the last words land, presses the field's Send, Go or Done (or Enter in a chat box). Never in password fields, and not after a failed or partial dictation. Chat apps are the ones set to the Chat style.",
        style = MaterialTheme.typography.bodySmall)
}
