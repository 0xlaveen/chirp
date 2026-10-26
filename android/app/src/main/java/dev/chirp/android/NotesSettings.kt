package dev.chirp.android

import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import dev.chirp.android.ui.ActionRow
import dev.chirp.android.ui.ChoiceChips
import dev.chirp.android.ui.SettingsGroup
import dev.chirp.android.ui.SettingsItem
import dev.chirp.android.ui.SwitchRow

/** Notes settings (library on by default, retention, kept audio, speaker labels), self-contained for the settings tree's Notes page and the Notes screen's own sheet ([title] there). */
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
    var keepAudio by remember { mutableStateOf(kept.keepAudio) }
    var audioBytes by remember { mutableStateOf(0L) }
    var confirmDeleteAudio by remember { mutableStateOf(false) }
    var confirmDeleteAll by remember { mutableStateOf(false) }
    var labelSpeakers by remember { mutableStateOf(store.notesLabelSpeakers) }
    var health by remember { mutableStateOf(store.health) }
    // The cached health is only as fresh as the last Notes visit: look again while the speaker model is on its way.
    LaunchedEffect(labelSpeakers) {
        while (true) {
            val latest = withContext(Dispatchers.IO) { refreshSpeakerHealth(context, store, labelSpeakers) } ?: break
            health = latest
            if (!labelSpeakers || latest.speakersModel != "downloading") break
            delay(3000)
        }
    }
    LaunchedEffect(keepAudio, keep) {
        // A size that cannot be read is shown as none, never as a crash of the settings page.
        audioBytes = try { withContext(Dispatchers.IO) { kept.totalAudioBytes() } } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (_: Exception) { 0L }
    }
    val rows: @Composable ColumnScope.() -> Unit = {
        SwitchRow("Save battery while the screen is off", saver, { saver = it; store.notesBatterySaver = it },
            summary = "On by default",
            infoTitle = "Save battery while the screen is off", infoBody = "With the screen off the phone stops drawing live text and the level meter; recording, the transcript " +
                "and the Mac's notes keep going, so everything is up to date the moment you look.")
        SwitchRow("Keep a recovery copy until notes are saved", recovery, { on ->
            recovery = on; store.notesRecovery = on
            // Off is also a delete: the copy and its key go.
            if (!on) NotesJournal(context, store = store).delete()
        }, summary = "On by default", infoTitle = "Keep a recovery copy until notes are saved",
            infoBody = "If Android closes Chirp or the phone restarts during a recording, Notes reopens with what you had. " +
                "Encrypted on this phone, never backed up or sent anywhere, and deleted when you save, discard or start new notes.")
        if (kept.optedOut && !keep) ActionRow("Enable notes library", { kept.enable(); keep = true })
        else SwitchRow("Keep notes on this phone", keep, { on ->
            // Off stops keeping new notes; it never deletes the ones already kept.
            if (on) kept.enable() else kept.disable()
            keep = on
        }, summary = "On by default · encrypted on this phone only", infoTitle = "Keep notes on this phone",
            infoBody = "Every note keeps itself, encrypted on this phone only. Never sent to your Mac, backed up or logged. " +
                "Turning this off keeps the notes you already have; \"Delete all notes\" removes them.")
        SettingsItem {
            Text("Delete notes older than", style = MaterialTheme.typography.bodyMedium)
            ChoiceChips(NotesRetention.entries, retention, { it.label }) { option ->
                retention = option
                scope.launch { withContext(Dispatchers.IO) { kept.retention = option } }
            }
            Text("Never by default. Deleted notes stay in Recently Deleted for ${NotesSessions.TRASH_DAYS} days.", style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        SwitchRow("Keep audio with notes", keepAudio, { on -> keepAudio = on; kept.keepAudio = on },
            summary = "Off by default", infoTitle = "Keep audio with notes",
            infoBody = "Keeps each spoken segment next to its transcript, compressed and encrypted on this phone only, so you can replay it. " +
                "Audio goes nowhere else.")
        SwitchRow("Label speakers", labelSpeakers, { on ->
            labelSpeakers = on; store.notesLabelSpeakers = on
            // On starts the Mac's one-time model download when it has none.
            if (on) scope.launch { withContext(Dispatchers.IO) { refreshSpeakerHealth(context, store, true, retry = true) }?.let { health = it } }
        }, summary = speakerSummary(health, labelSpeakers),
            enabled = health?.notesSpeakers != false || labelSpeakers, infoTitle = "Label speakers",
            infoBody = "Shows who said what in the transcript (Person 1, Person 2…; tap a name to rename it) and lets the notes say who " +
                "owns a to-do. On by default. Your Mac tells the voices apart in its memory only: nothing about a voice is saved, on the Mac or on this phone. " +
                "The first time, your Mac downloads a small speaker model (27 MB, once, from Hugging Face); notes never wait for it. Turn it off here at any time.")
        if (audioBytes > 0) ActionRow("Delete kept audio (${megabytes(audioBytes)})", { confirmDeleteAudio = true }, destructive = true)
        ActionRow("Delete all notes", { confirmDeleteAll = true }, destructive = true)
    }
    if (title != null) SettingsGroup(title, content = rows) else SettingsGroup(content = rows)
    if (confirmDeleteAudio) AlertDialog(onDismissRequest = { confirmDeleteAudio = false },
        title = { Text("Delete kept audio?") },
        text = { Text("This deletes the audio of every note. The text and transcripts stay.") },
        confirmButton = { TextButton({
            confirmDeleteAudio = false; audioBytes = 0
            scope.launch { withContext(Dispatchers.IO) { kept.deleteAllAudio() } }
        }) { Text("Delete audio") } },
        dismissButton = { TextButton({ confirmDeleteAudio = false }) { Text("Cancel") } })
    if (confirmDeleteAll) AlertDialog(onDismissRequest = { confirmDeleteAll = false },
        title = { Text("Delete all notes?") },
        text = { Text("This deletes every note on this phone, including Recently Deleted and kept audio. Notes you saved as files stay where you saved them.") },
        confirmButton = { TextButton({
            confirmDeleteAll = false; audioBytes = 0
            scope.launch { withContext(Dispatchers.IO) { kept.deleteAll() } }
        }) { Text("Delete everything") } },
        dismissButton = { TextButton({ confirmDeleteAll = false }) { Text("Cancel") } })
}

/** The Settings row's line: "On · who said what" plus where the Mac's speaker model stands. */
internal fun speakerSummary(health: Health?, on: Boolean): String = when {
    health != null && !health.notesSpeakers -> "Update Chirp on your Mac to label speakers"
    !on -> "Off · who said what"
    else -> "On · who said what" + when (health?.speakersModel) {
        "ready" -> " · speaker model on your Mac: ready"
        "downloading" -> " · speaker model on your Mac: downloading"
        "not_downloaded" -> " · speaker model on your Mac: getting ready"
        "failed" -> " · couldn’t download the speaker model"
        else -> ""
    }
}

/**
 * The Mac's health, fresh and cached for the next screen; null when unreachable. When [on] and the Mac has no speaker model
 * (or [retry] and its last download failed) it is asked to download one first: once, pinned and verified.
 */
internal fun refreshSpeakerHealth(context: android.content.Context, store: SettingsStore, on: Boolean, retry: Boolean = false): Health? {
    val paired = store.pairing() ?: return null
    val client = ChirpNetwork.client(context)
    return try {
        var health = ChirpNetwork.health(client, paired)
        if (on && health.notesSpeakers && (health.speakersModel == "not_downloaded" || retry && health.speakersModel == "failed")) {
            ChirpNetwork.speakerModel(client, paired, "download")
            health = ChirpNetwork.health(client, paired)
        }
        health.also { store.health = it }
    } catch (_: Exception) { null } finally { ChirpNetwork.dispose(client) }
}

private fun megabytes(bytes: Long) = if (bytes < 100_000) "<0.1 MB" else "%.1f MB".format(java.util.Locale.US, bytes / 1_000_000.0)

/** The settings list's one line for Notes, e.g. "Battery saver · recovery copy · keeps 7 days". */
internal fun notesSummary(context: android.content.Context): String {
    val store = SettingsStore(context); val kept = NotesSessions(context)
    return listOfNotNull("battery saver".takeIf { store.notesBatterySaver }, "recovery copy".takeIf { store.notesRecovery },
        kept.takeIf { it.enabled }?.let { if (it.retention == NotesRetention.NEVER) "keeps notes" else "deletes after ${it.retention.label}" }).joinToString(" · ").replaceFirstChar { it.uppercase() }.ifEmpty { "Off" }
}
