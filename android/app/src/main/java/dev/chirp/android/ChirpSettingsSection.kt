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
    var diagnostics by remember { mutableStateOf(false) }
    fun open(section: String) { context.startActivity(Intent(context, SetupActivity::class.java).putExtra("section", section)) }
    Column(Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Chirp", style = MaterialTheme.typography.titleLarge)
        Text(store.pairing()?.let { "Paired with ${it.base.host} · ${store.health?.engine ?: "Engine not reported"}" } ?: "Pair your Mac to dictate",
            style = MaterialTheme.typography.bodyMedium)
        TextButton({ open("pair") }) { Text("Pairing & connection") }
        TextButton({ open("settings") }) { Text("Test dictation") }
        if (store.health.cleanupAvailable()) {
            Row(Modifier.fillMaxWidth()) {
                Text("Clean-up · ${correctionLabel(store.health)}", Modifier.weight(1f))
                Switch(cleanup, { cleanup = it; store.correction = it }, modifier = Modifier.semantics { contentDescription = "Clean-up · ${correctionLabel(store.health)}" })
            }
        }
        TextButton({ diagnostics = true }) { Text("Chirp diagnostics") }
        HorizontalDivider()
    }
    if (diagnostics) AlertDialog(onDismissRequest = { diagnostics = false }, title = { Text("Chirp diagnostics") },
        text = { Text(CrashLog(context).text(), Modifier.heightIn(max = 420.dp).verticalScroll(rememberScrollState()), style = MaterialTheme.typography.bodySmall) },
        confirmButton = { TextButton({ diagnostics = false }) { Text("Close") } })
}
