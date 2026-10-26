package dev.chirp.android

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import dev.chirp.android.ui.ActionRow
import dev.chirp.android.ui.ChoiceChips
import dev.chirp.android.ui.NavRow
import dev.chirp.android.ui.SettingsGroup
import dev.chirp.android.ui.SettingsItem
import dev.chirp.android.ui.SwitchRow

/** History switch, retention and clear. Turning history off deletes it after confirmation. */
@Composable
internal fun HistorySettings(showOpen: Boolean = true, store: DictationHistory? = null, title: String? = "Dictation history", changed: () -> Unit = {}) {
    val context = LocalContext.current
    val history = store ?: remember { DictationHistory(context) }
    val scope = rememberCoroutineScope()
    var enabled by remember { mutableStateOf(history.enabled) }
    var retention by remember { mutableStateOf(history.retention) }
    var confirmOff by remember { mutableStateOf(false) }
    var confirmClear by remember { mutableStateOf(false) }
    SettingsGroup(title = title) {
        SwitchRow("Keep dictation history on this phone", enabled, { on ->
            if (on) { history.enable(); enabled = true; changed() } else confirmOff = true
        }, summary = "On by default · encrypted on this phone only",
            infoTitle = "Keep dictation history on this phone",
            infoBody = "Saves recent dictations encrypted on this phone only, so you can reinsert them from the keyboard's clock button. " +
                "Never sent to your Mac, backed up or logged. Password and incognito fields are never saved.")
        if (enabled) {
            SettingsItem {
                Text("Keep for", style = MaterialTheme.typography.bodyMedium)
                ChoiceChips(HistoryRetention.entries, retention, { it.label }) { option ->
                    retention = option
                    scope.launch { withContext(Dispatchers.IO) { history.retention = option }; changed() }
                }
            }
            if (showOpen) NavRow("Open history", { context.startActivity(Intent(context, HistoryActivity::class.java)) })
            ActionRow("Clear history", { confirmClear = true }, destructive = true)
        }
    }
    if (confirmOff) AlertDialog(onDismissRequest = { confirmOff = false },
        title = { Text("Turn off dictation history?") },
        text = { Text("This deletes every saved dictation from this phone. New dictations won't be saved.") },
        confirmButton = { TextButton({
            confirmOff = false
            scope.launch { withContext(Dispatchers.IO) { history.disable() }; enabled = false; changed() }
        }) { Text("Turn off and delete") } },
        dismissButton = { TextButton({ confirmOff = false }) { Text("Keep history") } })
    if (confirmClear) AlertDialog(onDismissRequest = { confirmClear = false },
        title = { Text("Clear dictation history?") },
        text = { Text("This deletes every saved dictation from this phone. History stays on for new dictations.") },
        confirmButton = { TextButton({
            confirmClear = false
            scope.launch { withContext(Dispatchers.IO) { history.clear() }; changed() }
        }) { Text("Clear") } },
        dismissButton = { TextButton({ confirmClear = false }) { Text("Cancel") } })
}

/** The keyboard's "open history" link and older shortcuts: a thin deep link into the app shell's History tab. */
class HistoryActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        startActivity(Intent(this, SetupActivity::class.java).putExtra("section", "history")
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP))
        finish()
    }
}
