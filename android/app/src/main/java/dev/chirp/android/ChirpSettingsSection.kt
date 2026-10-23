package dev.chirp.android

import android.content.Intent
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import dev.chirp.android.ui.NavRow
import dev.chirp.android.ui.SettingsGroup
import dev.chirp.android.ui.SwitchRow

@Composable
internal fun ChirpSettingsSection() {
    val context = LocalContext.current
    val store = remember { SettingsStore(context) }
    var cleanup by remember { mutableStateOf(store.correction) }
    var haptics by remember { mutableStateOf(store.haptics) }
    var commands by remember { mutableStateOf(store.spokenCommands) }
    var soundCues by remember { mutableStateOf(store.soundCues) }
    var shortcut by remember { mutableStateOf(store.hardwareShortcut) }
    var largerMic by remember { mutableStateOf(store.largerMic) }
    var diagnostics by remember { mutableStateOf(false) }
    fun open(section: String) { context.startActivity(Intent(context, SetupActivity::class.java).putExtra("section", section)) }
    Column(Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text("Chirp", style = MaterialTheme.typography.titleLarge)
        Text(store.pairing()?.let { "Paired with ${it.base.host} · ${store.health?.engine ?: "Engine not reported"}" } ?: "Pair your Mac to dictate",
            style = MaterialTheme.typography.bodyMedium)
        if (store.health.cleanupAvailable()) SettingsGroup("Clean-up & styles") {
            SwitchRow("Clean-up · ${correctionLabel(store.health)}", cleanup, { cleanup = it; store.correction = it },
                summary = cleanupDescription(store.health))
            CleanupStyleSettings(store.health)
            CleanupStyleSettings(store.health, appsOnly = true)
        } else if (store.pairing() != null) Text("Mac has clean-up off", style = MaterialTheme.typography.bodySmall)
        SettingsGroup("Pairing") {
            NavRow("Pairing & connection", { open("pair") })
            NavRow("Test dictation", { open("settings") })
        }
        StopDictationSettings()
        PhoneFallbackSettings()
        AutoEnterSettings()
        SettingsGroup("Sounds & haptics") {
            SwitchRow("Haptic cues", haptics, { haptics = it; store.haptics = it })
            SwitchRow("Sound cues", soundCues, { soundCues = it; store.soundCues = it },
                summary = "Short tones for start, stop, inserted and error. Silent when the phone is on vibrate or mute. Keyboard key sounds are below.")
        }
        SettingsGroup("Keyboard access") {
            SwitchRow("Hardware keyboard shortcut", shortcut, { shortcut = it; store.hardwareShortcut = it },
                summary = "Ctrl+Alt+Space starts and stops dictation; Esc cancels while listening.")
            SwitchRow("Larger mic on the inner screen", largerMic, { largerMic = it; store.largerMic = it })
        }
        SettingsGroup("Spoken commands") {
            SwitchRow("Say \"new line\" or \"new paragraph\"", commands, { commands = it; store.spokenCommands = it },
                summary = "Off by default. Ending a dictation with \"new line\" or \"new paragraph\" types a line break instead of the words.")
        }
        KeyboardLookChooser()
        SwipeTypingSettings()
        HistorySettings()
        SettingsGroup("Diagnostics") { NavRow("Chirp diagnostics", { diagnostics = true }) }
        HorizontalDivider()
    }
    if (diagnostics) {
        var report by remember { mutableStateOf(DiagnosticsReport.text(context)) }
        AlertDialog(onDismissRequest = { diagnostics = false }, title = { Text("Chirp diagnostics") },
            text = { Column(Modifier.heightIn(max = 420.dp).verticalScroll(rememberScrollState())) {
                Text(report, style = MaterialTheme.typography.bodySmall)
                TextButton({ DiagnosticsReport.clearTimings(context); report = DiagnosticsReport.text(context) }) { Text("Clear timings") }
            } },
            confirmButton = { TextButton({
                context.getSystemService(android.content.ClipboardManager::class.java).setPrimaryClip(
                    android.content.ClipData.newPlainText("Chirp diagnostics", report))
            }) { Text("Copy") } },
            dismissButton = { TextButton({ diagnostics = false }) { Text("Close") } })
    }
}
