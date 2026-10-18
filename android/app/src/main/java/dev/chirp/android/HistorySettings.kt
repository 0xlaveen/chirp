package dev.chirp.android

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Opt-in switch, retention and clear. Turning history off deletes it after confirmation. */
@Composable
internal fun HistorySettings(showOpen: Boolean = true, store: DictationHistory? = null, changed: () -> Unit = {}) {
    val context = LocalContext.current
    val history = store ?: remember { DictationHistory(context) }
    val scope = rememberCoroutineScope()
    var enabled by remember { mutableStateOf(history.enabled) }
    var retention by remember { mutableStateOf(history.retention) }
    var confirmOff by remember { mutableStateOf(false) }
    var confirmClear by remember { mutableStateOf(false) }
    Text("Dictation history", style = MaterialTheme.typography.titleSmall)
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text("Keep dictation history on this phone", Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
        Switch(enabled, { on ->
            if (on) { history.enable(); enabled = true; changed() } else confirmOff = true
        }, modifier = Modifier.semantics { contentDescription = "Dictation history" })
    }
    Text("Off by default. Saves recent dictations encrypted on this phone only, so you can reinsert them from the keyboard's clock button. " +
        "Never sent to your Mac, backed up or logged. Password and incognito fields are never saved.", style = MaterialTheme.typography.bodySmall)
    if (enabled) {
        Text("Keep for", style = MaterialTheme.typography.bodyMedium)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            HistoryRetention.entries.forEach { option ->
                FilterChip(retention == option, {
                    retention = option
                    scope.launch { withContext(Dispatchers.IO) { history.retention = option }; changed() }
                }, label = { Text(option.label) })
            }
        }
        Row {
            if (showOpen) TextButton({ context.startActivity(Intent(context, HistoryActivity::class.java)) }) { Text("Open history") }
            TextButton({ confirmClear = true }) { Text("Clear history") }
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

class HistoryActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Keep dictated text out of the Recents thumbnail.
        if (Build.VERSION.SDK_INT >= 33) setRecentsScreenshotEnabled(false)
        setContent { ChirpTheme { HistoryScreen() } }
    }
}

@Composable
internal fun HistoryScreen(store: DictationHistory? = null, now: () -> Long = System::currentTimeMillis) {
    val context = LocalContext.current
    val history = store ?: remember { DictationHistory(context) }
    val scope = rememberCoroutineScope()
    var enabled by remember { mutableStateOf(history.enabled) }
    var entries by remember { mutableStateOf<List<HistoryEntry>?>(null) }
    var reload by remember { mutableIntStateOf(0) }
    var query by remember { mutableStateOf("") }
    LaunchedEffect(reload, enabled) { entries = withContext(Dispatchers.IO) { history.entries() } }
    fun copy(value: String) = context.getSystemService(ClipboardManager::class.java)
        ?.setPrimaryClip(ClipData.newPlainText("Chirp dictation", value))
    val shown = entries.orEmpty().filter { entry ->
        query.isBlank() || listOfNotNull(entry.text, entry.raw, entry.app).any { it.contains(query.trim(), ignoreCase = true) }
    }
    Surface(Modifier.fillMaxSize()) {
        Box(Modifier.fillMaxSize().safeDrawingPadding(), contentAlignment = Alignment.TopCenter) {
            LazyColumn(Modifier.widthIn(max = 600.dp).fillMaxWidth(), contentPadding = PaddingValues(24.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)) {
                item {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text("CHIRP  /  HISTORY", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
                        Text("Dictation history", style = MaterialTheme.typography.headlineMedium)
                        HistorySettings(showOpen = false, store = history) { enabled = history.enabled; reload++ }
                        if (enabled) OutlinedTextField(query, { query = it }, Modifier.fillMaxWidth(),
                            label = { Text("Search history") }, singleLine = true)
                    }
                }
                if (enabled) {
                    if (entries != null && shown.isEmpty()) item {
                        Text(if (query.isBlank()) "No dictations yet. New dictations stay here for ${history.retention.label}." else "No matches",
                            style = MaterialTheme.typography.bodyMedium)
                    }
                    items(shown, key = { it.id }) { entry ->
                        Card(Modifier.fillMaxWidth()) {
                            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                Text(entry.text, style = MaterialTheme.typography.bodyLarge)
                                entry.raw?.let { Text("Before clean-up: $it", style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant) }
                                Text(listOfNotNull(historyAge(now(), entry.time).first, entry.app).joinToString(" · "),
                                    style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                Row {
                                    TextButton({ copy(entry.text) }) { Text("Copy") }
                                    entry.raw?.let { raw -> TextButton({ copy(raw) }) { Text("Copy raw") } }
                                    TextButton({
                                        scope.launch { withContext(Dispatchers.IO) { history.delete(entry.id) }; reload++ }
                                    }) { Text("Delete") }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
