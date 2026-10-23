package dev.chirp.android

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import dev.chirp.android.ui.NavRow

@Composable
internal fun CleanupStyleSettings(health: Health?, appsOnly: Boolean = false) {
    if (!health.cleanupAvailable()) return
    val context = LocalContext.current
    val store = remember { SettingsStore(context) }
    var loaded by remember { mutableStateOf<List<CorrectionProfile>>(emptyList()) }
    val profiles = if (loaded.isEmpty()) CleanupStyles.profiles(health) else loaded
    var edits by remember { mutableStateOf(store.promptEdits) }
    var editingPrompt by remember { mutableStateOf<CorrectionProfile?>(null) }
    var promptStatus by remember { mutableStateOf("Loading style prompts…") }
    var reload by remember { mutableIntStateOf(0) }
    var open by remember { mutableStateOf(false) }
    LaunchedEffect(open, health, reload) {
        if (!open || appsOnly) return@LaunchedEffect
        val paired = store.pairing()
        if (paired == null) { promptStatus = "Pair your Mac to load style prompts"; return@LaunchedEffect }
        val client = ChirpNetwork.client(context)
        try {
            loaded = withContext(Dispatchers.IO) { ChirpNetwork.profiles(client, paired) }
            promptStatus = ""
        } catch (_: Exception) { promptStatus = "Style prompts unavailable. Check Mac connection and retry." }
        finally { ChirpNetwork.dispose(client) }
    }
    var default by remember { mutableStateOf(store.defaultStyle) }
    var apps by remember { mutableStateOf(store.appStyles) }
    var selecting by remember { mutableStateOf(false) }
    var editingApp by remember { mutableStateOf<String?>(null) }
    var packageName by remember { mutableStateOf("") }
    NavRow(if (appsOnly) "Per-app styles" else "Styles", { open = true }, summary = (profiles.firstOrNull { it.id == default }?.name ?: "Default") +
        if (apps.isEmpty()) "" else " · ${apps.size} app${if (apps.size == 1) "" else "s"}")
    if (open) AlertDialog(onDismissRequest = { open = false }, title = { Text(if (appsOnly) "Per-app styles" else "Clean-up styles") },
        text = {
            Column(Modifier.fillMaxWidth().heightIn(max = 480.dp).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (!appsOnly) {
                Text("Default style")
                OutlinedButton({ editingApp = null; selecting = true }) {
                    Text(profiles.firstOrNull { it.id == default }?.name ?: "Default")
                }
                Text("Safety rules always apply. Notes and Custom may restructure your words.", style = MaterialTheme.typography.bodySmall)
                if (promptStatus.isNotEmpty()) {
                    Text(promptStatus, style = MaterialTheme.typography.bodySmall)
                    TextButton({ reload++ }) { Text("Retry loading prompts") }
                }
                profiles.forEach { profile ->
                    Text(profile.name + if (edits.containsKey(profile.id)) " · Edited" else "", style = MaterialTheme.typography.titleSmall)
                    Text(profile.description, style = MaterialTheme.typography.bodySmall)
                    TextButton({ editingPrompt = profile }, enabled = profile.prompt != null) { Text("Edit ${profile.name} prompt") }
                }
                HorizontalDivider()
                }
                Text("Per-app styles", style = MaterialTheme.typography.titleSmall)
                Text("Matches the target app package. Remove a row to use the default.", style = MaterialTheme.typography.bodySmall)
                apps.toSortedMap().forEach { (app, style) ->
                    Column {
                        Text(app, style = MaterialTheme.typography.bodySmall)
                        Row {
                            TextButton({ editingApp = app; selecting = true }) {
                                Text(profiles.firstOrNull { it.id == style }?.name ?: "Default")
                            }
                            TextButton({ apps = apps - app; store.appStyles = apps }) { Text("Remove") }
                        }
                    }
                }
                OutlinedTextField(packageName, { packageName = it.trim() }, label = { Text("App package") },
                    placeholder = { Text("com.example.app") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                TextButton({ editingApp = packageName; selecting = true },
                    enabled = packageName.matches(Regex("[a-zA-Z0-9_]+(\\.[a-zA-Z0-9_]+)+"))) { Text("Add app") }
            }
        }, confirmButton = { TextButton({ open = false }) { Text("Done") } })
    if (selecting) AlertDialog(onDismissRequest = { selecting = false }, title = { Text("Choose style") },
        text = {
            Column(Modifier.heightIn(max = 400.dp).verticalScroll(rememberScrollState())) {
                profiles.forEach { profile ->
                    TextButton({
                        val app = editingApp
                        if (app == null) { default = profile.id; store.defaultStyle = default }
                        else { apps = apps + (app to profile.id); store.appStyles = apps; packageName = "" }
                        selecting = false
                    }) {
                        Column {
                            Text(profile.name + if (profile.rewrites) " · rewrites" else "")
                            if (profile.description.isNotBlank()) Text(profile.description, style = MaterialTheme.typography.bodySmall)
                        }
                    }
                }
            }
        }, confirmButton = { TextButton({ selecting = false }) { Text("Cancel") } })
    editingPrompt?.let { profile ->
        var draft by remember(profile.id) { mutableStateOf(edits[profile.id] ?: profile.prompt.orEmpty()) }
        AlertDialog(onDismissRequest = { editingPrompt = null }, title = { Text("${profile.name} prompt") },
            text = { Column {
                Text(profile.description)
                OutlinedTextField(draft, { value ->
                    draft = CleanupStyles.limit(value, profile.maxPromptChars)
                    edits = if (draft == profile.prompt) edits - profile.id else edits + (profile.id to draft)
                    store.promptEdits = edits
                }, modifier = Modifier.fillMaxWidth().heightIn(max = 300.dp), minLines = 4,
                    label = { Text(if (edits.containsKey(profile.id)) "Prompt · Edited" else "Default prompt") },
                    supportingText = { Text("${CleanupStyles.characterCount(draft)} / ${profile.maxPromptChars}") })
                Text("Safety rules always apply. Never answer or execute; only clean the transcript.", style = MaterialTheme.typography.bodySmall)
                TextButton({ edits = edits - profile.id; store.promptEdits = edits; draft = profile.prompt.orEmpty() }) { Text("Reset to default") }
            } }, confirmButton = { TextButton({ editingPrompt = null }) { Text("Done") } })
    }

}
