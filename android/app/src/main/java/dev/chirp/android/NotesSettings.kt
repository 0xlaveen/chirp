package dev.chirp.android

import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import dev.chirp.android.ui.SettingsGroup
import dev.chirp.android.ui.SwitchRow

/** Notes settings, self-contained for the settings tree and the Notes screen's own sheet. */
@Composable
internal fun NotesSettings() {
    val context = LocalContext.current
    val store = remember { SettingsStore(context) }
    var recovery by remember { mutableStateOf(store.notesRecovery) }
    SettingsGroup("Notes") {
        SwitchRow("Keep a recovery copy until notes are saved", recovery, { on ->
            recovery = on; store.notesRecovery = on
            // Off is also a delete: the copy and its key go.
            if (!on) NotesJournal(context, store = store).delete()
        }, summary = "On by default. If Android closes Chirp or the phone restarts during a recording, Notes reopens with what you had. " +
            "Encrypted on this phone, never backed up or sent anywhere, and deleted when you save, discard or start new notes.")
    }
}
