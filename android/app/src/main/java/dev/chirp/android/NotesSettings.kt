package dev.chirp.android

import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import dev.chirp.android.ui.ChoiceChips
import dev.chirp.android.ui.SettingsGroup
import dev.chirp.android.ui.SettingsItem
import dev.chirp.android.ui.SwitchRow

/** Notes settings, self-contained for the settings tree's Notes page and the Notes screen's own sheet ([title] there). */
@Composable
internal fun NotesSettings(sessions: NotesSessions? = null, title: String? = null) {
    val context = LocalContext.current
    val store = remember { SettingsStore(context) }
    val kept = sessions ?: remember { NotesSessions(context) }
    val scope = rememberCoroutineScope()
    var recovery by remember { mutableStateOf(store.notesRecovery) }
    var saver by remember { mutableStateOf(store.notesBatterySaver) }
    var keep by remember { mutableStateOf(kept.enabled) }
    var retention by remember { mutableStateOf(kept.retention) }
    var confirmOff by remember { mutableStateOf(false) }
    val rows: @Composable ColumnScope.() -> Unit = {
        SwitchRow("Save battery while the screen is off", saver, { saver = it; store.notesBatterySaver = it },
            summary = "On by default. With the screen off the phone stops drawing live text and the level meter; recording, the transcript " +
                "and the Mac's notes keep going, so everything is up to date the moment you look.")
        SwitchRow("Keep a recovery copy until notes are saved", recovery, { on ->
            recovery = on; store.notesRecovery = on
            // Off is also a delete: the copy and its key go.
            if (!on) NotesJournal(context, store = store).delete()
        }, summary = "On by default. If Android closes Chirp or the phone restarts during a recording, Notes reopens with what you had. " +
            "Encrypted on this phone, never backed up or sent anywhere, and deleted when you save, discard or start new notes.")
        SwitchRow("Keep notes on this phone", keep, { on ->
            if (on) { kept.enable(); keep = true } else confirmOff = true
        }, summary = "Off by default. Notes you stop or leave are kept in Recent notes (the clock button on the Notes screen), encrypted on this " +
            "phone only. Never sent to your Mac, backed up or logged.")
        if (keep) SettingsItem {
            Text("Keep for", style = MaterialTheme.typography.bodyMedium)
            ChoiceChips(HistoryRetention.entries, retention, { it.label }) { option ->
                retention = option
                scope.launch { withContext(Dispatchers.IO) { kept.retention = option } }
            }
        }
    }
    if (title != null) SettingsGroup(title, content = rows) else SettingsGroup(content = rows)
    if (confirmOff) AlertDialog(onDismissRequest = { confirmOff = false },
        title = { Text("Stop keeping notes?") },
        text = { Text("This deletes every kept note from this phone. Notes you saved as files stay where you saved them.") },
        confirmButton = { TextButton({
            confirmOff = false; keep = false
            scope.launch { withContext(Dispatchers.IO) { kept.disable() } }
        }) { Text("Delete and turn off") } },
        dismissButton = { TextButton({ confirmOff = false }) { Text("Cancel") } })
}

/** The settings list's one line for Notes, e.g. "Battery saver · recovery copy · keeps 7 days". */
internal fun notesSummary(context: android.content.Context): String {
    val store = SettingsStore(context); val kept = NotesSessions(context)
    return listOfNotNull("battery saver".takeIf { store.notesBatterySaver }, "recovery copy".takeIf { store.notesRecovery },
        kept.takeIf { it.enabled }?.let { "keeps ${it.retention.label}" }).joinToString(" · ").replaceFirstChar { it.uppercase() }.ifEmpty { "Off" }
}
