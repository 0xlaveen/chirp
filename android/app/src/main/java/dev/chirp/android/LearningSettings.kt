package dev.chirp.android

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import dev.chirp.android.ui.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun LearningSettings() {
    val context = LocalContext.current
    val store = remember { LearnedStore(context) }
    var enabled by remember { mutableStateOf(store.enabled) }
    var show by remember { mutableStateOf(false) }
    SettingsGroup("Learning") {
        SwitchRow("Learn from my edits", enabled, { enabled = it; store.enabled = it }, summary = "On while dictation history is on",
            infoTitle = "Learn from my edits", infoBody = "After dictating, fix a word in the same field within 60 seconds. " +
                "The same correction seen twice teaches Chirp your vocabulary or that app's style. Password, incognito and private sessions are excluded. " +
                "Learned items are encrypted on this phone. Active items go only to your own server with dictation, including its configured clean-up host.")
        NavRow("Learned", { show = true }, summary = "Review, approve or undo corrections")
    }
    if (show) ModalBottomSheet({ show = false }) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(24.dp)) { LearnedList(store) }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun LearnedList(store: LearnedStore) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var items by remember { mutableStateOf<List<LearnedItem>>(emptyList()) }
    var revision by remember { mutableIntStateOf(0) }
    var failed by remember { mutableStateOf(false) }
    LaunchedEffect(revision) {
        runCatching { withContext(Dispatchers.IO) { store.all() } }.onSuccess { items = it; failed = false }.onFailure { failed = true }
    }
    fun change(work: () -> Unit) { scope.launch {
        failed = runCatching { withContext(Dispatchers.IO) { work() } }.isFailure
        revision++
    } }
    Text("Learned", Modifier.semantics { heading() }, style = MaterialTheme.typography.headlineMedium)
    Text("Your terms work everywhere. Style belongs to the app where you edited.", style = MaterialTheme.typography.bodyMedium)
    Spacer(Modifier.height(16.dp))
    if (failed) Text("Couldn't open learned items. Unlock your phone and try again.")
    else if (items.isEmpty()) Text("Nothing learned yet. Correct the same dictation word twice, or use Teach Chirp in History.")
    items.groupBy { it.app }.forEach { (app, group) ->
        val appTitle = remember(app) { app?.let { pkg -> runCatching {
            context.packageManager.getApplicationLabel(context.packageManager.getApplicationInfo(pkg, 0)).toString()
        }.getOrDefault(pkg) } ?: "All apps" }
        SettingsGroup(appTitle) {
            ActionRow("Reset app", { change { store.reset(app) } }, destructive = true)
            group.sortedByDescending { it.time }.forEach { item -> SettingsItem {
                Text(item.correction.title, style = MaterialTheme.typography.titleMedium)
                Text(if (item.state == LearnedState.LEARNING) "Learning · ${item.count} of 2" else item.state.title,
                    style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary)
                Text("${item.inserted} → ${item.edited}", style = MaterialTheme.typography.bodyMedium)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (item.state != LearnedState.ACTIVE) TextButton({ change { store.set(item.id, LearnedState.ACTIVE) } }) { Text("Approve") }
                    if (item.state != LearnedState.OFF) TextButton({ change { store.set(item.id, LearnedState.OFF) } }) { Text("Undo") }
                    TextButton({ change { store.delete(item.id) } }) { Text("Delete") }
                }
            } }
        }
    }
}

/** Teach a corrected dictation explicitly; a single approved edit activates it. */
@Composable
internal fun TeachChirp(entry: HistoryEntry, close: () -> Unit) {
    val context = LocalContext.current
    val store = remember { LearnedStore(context) }
    val scope = rememberCoroutineScope()
    var wanted by remember(entry.id) { mutableStateOf(entry.text) }
    var message by remember { mutableStateOf<String?>(null) }
    var saving by remember { mutableStateOf(false) }
    AlertDialog(onDismissRequest = close, title = { Text("Teach Chirp") }, text = {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("Correct a name or technical word, or adjust this app's capitalization and final period.")
            OutlinedTextField(wanted, { if (it.length <= 20000) wanted = it }, label = { Text("What you wanted") }, modifier = Modifier.fillMaxWidth())
            message?.let { Text(it) }
        }
    }, confirmButton = { TextButton({
        saving = true
        scope.launch {
            val result = runCatching { withContext(Dispatchers.IO) { store.observe(entry.text, wanted, entry.raw ?: entry.text, entry.packageName, explicit = true) } }
            saving = false
            if (result.getOrNull()?.isNotEmpty() == true) close()
            else message = if (!store.allowed) "Turn on history and learning, and end Private session to teach Chirp."
                else if (result.isFailure) "Couldn't save. Try again." else "No new correction found. An item turned off stays off until you approve it in Learned."
        }
    }, enabled = !saving && wanted != entry.text) { Text("Teach Chirp") } },
        dismissButton = { TextButton(close) { Text("Cancel") } })
}
