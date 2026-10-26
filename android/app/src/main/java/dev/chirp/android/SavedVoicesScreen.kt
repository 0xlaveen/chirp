package dev.chirp.android

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import dev.chirp.android.ui.ActionRow
import dev.chirp.android.ui.SettingsGroup
import dev.chirp.android.ui.SettingsItem
import dev.chirp.android.ui.SwitchRow

/** A screen of its own, shared by the settings tree and the note's settings sheet. */
@Composable
internal fun SavedVoicesScreen(model: SavedVoicesModel, dismiss: () -> Unit) {
    Dialog(onDismissRequest = dismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize()) {
            BackHandler(onBack = dismiss)
            Column(Modifier.safeDrawingPadding()) {
                Row(Modifier.fillMaxWidth().padding(12.dp)) {
                    TextButton(dismiss) { Text("Back") }
                    Text("Saved voices", Modifier.padding(12.dp), style = MaterialTheme.typography.titleLarge)
                }
                Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 16.dp)) {
                    SavedVoicesContent(model)
                }
            }
        }
    }
}

@Composable
internal fun SavedVoicesContent(model: SavedVoicesModel) {
    var disable by remember { mutableStateOf(false) }
    var forgetAll by remember { mutableStateOf(false) }
    var forgetting by remember { mutableStateOf<SavedVoice?>(null) }
    var renaming by remember { mutableStateOf<SavedVoice?>(null) }
    var name by remember { mutableStateOf("") }
    val library = model.library
    SettingsGroup {
        SwitchRow("Remember voices of people I name", library?.enabled == true, { on ->
            if (on) model.action(VoiceAction.Enable) else disable = true
        }, enabled = library != null && !model.busy, summary = "Shared by all devices paired to this Mac")
        SettingsItem {
            Text("Chirp recognises these people in new notes on all your devices. They’re kept on your paired Mac, never uploaded.",
                style = MaterialTheme.typography.bodyMedium)
        }
        model.error?.let { message ->
            SettingsItem { Text(message, color = MaterialTheme.colorScheme.error) }
        }
        if (model.busy) SettingsItem { Text("Updating saved voices…") }
        if (library?.voices?.isEmpty() == true) SettingsItem {
            Text("Name a speaker in a note and Chirp will recognise them next time.", style = MaterialTheme.typography.bodyMedium)
        }
        library?.voices.orEmpty().forEach { voice ->
            SettingsItem {
                Row(Modifier.fillMaxWidth()) {
                    Column(Modifier.weight(1f).padding(vertical = 8.dp)) {
                        Text(voice.name, style = MaterialTheme.typography.titleMedium)
                        Text(voiceDetail(voice), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        if (!voice.compatible) Text("Name them again to keep recognising this voice", style = MaterialTheme.typography.bodySmall)
                    }
                    var menu by remember(voice.id) { mutableStateOf(false) }
                    Box {
                        TextButton({ menu = true }, enabled = !model.busy) { Text("⋯") }
                        DropdownMenu(menu, { menu = false }) {
                            DropdownMenuItem({ Text("Rename…") }, { menu = false; renaming = voice; name = voice.name })
                            DropdownMenuItem({ Text("Forget…") }, { menu = false; forgetting = voice })
                        }
                    }
                }
            }
        }
        ActionRow("Refresh saved voices", { model.refresh() })
        if (library?.voices?.isNotEmpty() == true) ActionRow("Forget all voices…", { forgetAll = true }, destructive = true)
    }
    if (disable) AlertDialog(onDismissRequest = { disable = false }, title = { Text("Stop remembering voices?") },
        text = { Text("Stops saving and recognising on every device. Also forget ${library?.voices?.size ?: 0} saved voices?") },
        confirmButton = { TextButton({ disable = false; model.action(VoiceAction.Disable(true)) }) { Text("Turn off and forget") } },
        dismissButton = { Row {
            TextButton({ disable = false; model.action(VoiceAction.Disable(false)) }) { Text("Keep voices") }
            TextButton({ disable = false }) { Text("Cancel") }
        } })
    if (forgetAll || forgetting != null) AlertDialog(onDismissRequest = { forgetAll = false; forgetting = null },
        title = { Text(if (forgetAll) "Forget all voices?" else "Forget ${forgetting?.name}?") },
        text = { Text("Removes saved voices from your Mac for every device. Names in existing notes stay.") },
        confirmButton = { TextButton({
            val action = forgetting?.let { VoiceAction.Forget(it.id) } ?: VoiceAction.ForgetAll
            forgetAll = false; forgetting = null; model.action(action)
        }) { Text("Forget") } }, dismissButton = { TextButton({ forgetAll = false; forgetting = null }) { Text("Cancel") } })
    renaming?.let { voice ->
        AlertDialog(onDismissRequest = { renaming = null }, title = { Text("Rename saved voice") },
            text = { Column {
                OutlinedTextField(name, { name = it.take(60) }, label = { Text("Name") }, singleLine = true)
                Text("Names in existing notes stay.", style = MaterialTheme.typography.bodySmall)
            } }, confirmButton = { TextButton({
                renaming = null; model.action(VoiceAction.Rename(voice.id, cleanVoiceName(name)))
            }, enabled = validVoiceName(cleanVoiceName(name))) { Text("Rename") } },
            dismissButton = { TextButton({ renaming = null }) { Text("Cancel") } })
    }
}

private fun voiceDetail(voice: SavedVoice): String {
    fun date(value: String): String = try {
        java.time.Instant.parse(value).atZone(java.time.ZoneId.systemDefault()).toLocalDate()
            .format(java.time.format.DateTimeFormatter.ofPattern("d MMM"))
    } catch (_: Exception) { "earlier" }
    return "Saved ${date(voice.created)}" + (if (voice.updated != voice.created) " · updated ${date(voice.updated)}" else "") + " · ${voice.seconds.toInt()} s"
}
