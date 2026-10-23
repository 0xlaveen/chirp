package dev.chirp.android

import android.content.Intent
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp

@Composable
internal fun ChirpSettingsSection() {
    val context = LocalContext.current
    val store = remember { SettingsStore(context) }
    var cleanup by remember { mutableStateOf(store.correction) }
    var haptics by remember { mutableStateOf(store.haptics) }
    var commands by remember { mutableStateOf(store.spokenCommands) }
    var diagnostics by remember { mutableStateOf(false) }
    fun open(section: String) { context.startActivity(Intent(context, SetupActivity::class.java).putExtra("section", section)) }
    Column(Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Chirp", style = MaterialTheme.typography.titleLarge)
        Text(store.pairing()?.let { "Paired with ${it.base.host} · ${store.health?.engine ?: "Engine not reported"}" } ?: "Pair your Mac to dictate",
            style = MaterialTheme.typography.bodyMedium)
        if (store.health.cleanupAvailable()) {
            Text("Clean-up & styles", style = MaterialTheme.typography.titleSmall)
            Row(Modifier.fillMaxWidth()) {
                Text("Clean-up · ${correctionLabel(store.health)}", Modifier.weight(1f))
                Switch(cleanup, { cleanup = it; store.correction = it }, modifier = Modifier.semantics { contentDescription = "Clean-up · ${correctionLabel(store.health)}" })
            }
            Text(cleanupDescription(store.health), style = MaterialTheme.typography.bodySmall)
            CleanupStyleSettings(store.health)
            CleanupStyleSettings(store.health, appsOnly = true)
        } else if (store.pairing() != null) Text("Mac has clean-up off", style = MaterialTheme.typography.bodySmall)
        Text("Pairing", style = MaterialTheme.typography.titleSmall)
        TextButton({ open("pair") }) { Text("Pairing & connection") }
        TextButton({ open("settings") }) { Text("Test dictation") }
        Text("Sounds & haptics", style = MaterialTheme.typography.titleSmall)
        Row(Modifier.fillMaxWidth()) {
            Text("Haptic cues", Modifier.weight(1f))
            Switch(haptics, { haptics = it; store.haptics = it }, modifier = Modifier.semantics { contentDescription = "Haptic cues" })
        }
        Text("Voice cues use haptics. Keyboard sound controls are below.", style = MaterialTheme.typography.bodySmall)
        Text("Spoken commands", style = MaterialTheme.typography.titleSmall)
        Row(Modifier.fillMaxWidth()) {
            Text("Say \"new line\" or \"new paragraph\"", Modifier.weight(1f))
            Switch(commands, { commands = it; store.spokenCommands = it }, modifier = Modifier.semantics { contentDescription = "Spoken commands" })
        }
        Text("Off by default. Ending a dictation with \"new line\" or \"new paragraph\" types a line break instead of the words.", style = MaterialTheme.typography.bodySmall)
        KeyboardLookChooser()
        SwipeTypingSettings()
        HistorySettings()
        Text("Diagnostics", style = MaterialTheme.typography.titleSmall)
        TextButton({ diagnostics = true }) { Text("Chirp diagnostics") }
        HorizontalDivider()
    }
    if (diagnostics) AlertDialog(onDismissRequest = { diagnostics = false }, title = { Text("Chirp diagnostics") },
        text = { Text(CrashLog(context).text(), Modifier.heightIn(max = 420.dp).verticalScroll(rememberScrollState()), style = MaterialTheme.typography.bodySmall) },
        confirmButton = { TextButton({ diagnostics = false }) { Text("Close") } })
}
