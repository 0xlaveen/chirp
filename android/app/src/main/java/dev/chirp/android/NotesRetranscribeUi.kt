package dev.chirp.android

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun RetranscribeSheet(model: NotesModel) {
    if (model.retranscribeSheet) ModalBottomSheet(onDismissRequest = { model.retranscribeSheet = false },
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        val clips = model.retranscribeClips
        val health = model.retranscribeHealth
        val seconds = clips.sumOf { it.duration }.toInt()
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text("Re-transcribe “${model.displayTitle}”?", Modifier.semantics { heading() }, style = MaterialTheme.typography.titleLarge)
            Text(if (model.retranscribeSegment != null)
                "Send this ${seconds / 60}:${(seconds % 60).toString().padStart(2, '0')} clip to your Chirp server on ${model.retranscribeDestination} to transcribe it again?"
                else "Chirp sends this note’s kept audio (${seconds / 60} min ${seconds % 60} s, ${clips.size} ${if (clips.size == 1) "clip" else "clips"}) to your Chirp server on ${model.retranscribeDestination}.")
            Text("It is transcribed in memory there and not kept. Nothing else receives the audio.")
            Text("Speech model: ${health?.speechModel ?: health?.engine ?: "unknown"}. This note was transcribed with: ${model.document.transcriptEngine}.")
            if (model.document.segments.isNotEmpty() && model.document.segments.all { it.engine != null && it.engine == health?.engine })
                Text("Same model as before. Results change only if clean-up or context changed.")
            Text("Clean-up: ${if (model.retranscribeCleanup) "On" else "Off"}. Change the model in Chirp on your computer.")
            if (model.retranscribeCleanup && health?.correctionLeavesMachine == true && health.correctionHost != null)
                Text("Clean-up sends text to ${health.correctionHost}. Audio stays on your computer.")
            if (health?.debugRetention == true)
                Text("Your server is keeping debug recordings. This audio will be saved there for up to 3 days.", color = MaterialTheme.colorScheme.error)
            val missing = model.document.segments.count { segment -> model.document.audio.none { it.segment == segment.id } }
            if (missing > 0 && model.retranscribeSegment == null) Text("$missing of ${model.document.segments.size} segments have no kept audio and keep their current text.")
            val rebuild = health?.correctionAvailable == true && health.notesStructure
            Row {
                Checkbox(model.rebuildChoice, { model.rebuildChoice = it }, enabled = rebuild)
                Column(Modifier.weight(1f)) {
                    Text("Also rebuild the notes from the new transcript.")
                    Text("This replaces the notes text, including your edits. You can undo it.", style = MaterialTheme.typography.bodySmall)
                    if (!rebuild) Text("Needs clean-up on your server", style = MaterialTheme.typography.bodySmall)
                }
            }
            if (health?.notesRetranscribe != true) Text("Update Chirp on your computer to re-transcribe")
            else Button(model::startRetranscribe, Modifier.fillMaxWidth()) { Text(if (health.debugRetention) "Re-transcribe anyway" else "Re-transcribe") }
            TextButton({ model.retranscribeSheet = false }, Modifier.fillMaxWidth()) { Text("Cancel") }
        }
    }
    if (model.rebuildReview != null) AlertDialog(onDismissRequest = { model.rebuildReview = null },
        title = { Text("Replace your edits?") }, text = { Column(Modifier.verticalScroll(rememberScrollState())) {
            Text("You edited the notes during re-transcription. Replace them with these rebuilt notes? You can undo it.")
            Text(requireNotNull(model.rebuildReview))
        } }, confirmButton = { TextButton(model::acceptRebuild) { Text("Replace") } },
        dismissButton = { TextButton({ model.rebuildReview = null }) { Text("Keep my edits") } })
}

@Composable
internal fun RetranscribeBanner(model: NotesModel) {
    model.retranscribeProgress?.let { progress ->
        Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp).semantics { liveRegion = LiveRegionMode.Polite }) {
            Text(progress.label)
            LinearProgressIndicator(progress = { if (progress.total == 0) 0f else progress.done.toFloat() / progress.total }, modifier = Modifier.fillMaxWidth())
            TextButton({ RetranscribeGate.owner?.cancelRetranscribe() }) { Text("Cancel") }
        }
    }
    model.retranscribeFailure?.let { failure ->
        Column(Modifier.padding(horizontal = 20.dp)) {
            Text(failure, color = MaterialTheme.colorScheme.error)
            if (model.canApplyRetranscribed) TextButton({ model.applyRetranscribed() }) { Text("Apply what’s done") }
            TextButton(model::cancelRetranscribe) { Text("Cancel") }
        }
    }
    model.retranscribeNotice?.let { notice ->
        Column(Modifier.padding(horizontal = 20.dp)) {
            Text(notice, Modifier.semantics { liveRegion = LiveRegionMode.Polite })
            if (notice == "Notes rebuilt" && model.canUndo) TextButton(model::undo) { Text("Undo") }
            else if (notice.contains("updated") && model.document.previousTranscript != null) TextButton(model::restoreTranscript) { Text("Undo") }
            TextButton({ model.retranscribeNotice = null }) { Text("Dismiss") }
        }
    }
}
