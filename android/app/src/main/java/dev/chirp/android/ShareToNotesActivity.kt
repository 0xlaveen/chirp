package dev.chirp.android

import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Receives only the requested share; it never forwards text to another Activity or the speech server. */
open class ShareToNotesActivity : ComponentActivity() {
    internal open fun library() = NotesSessions(applicationContext)
    private var shared: String? = null
    private var subject: String? = null
    private var message by mutableStateOf<String?>(null)
    private var saving by mutableStateOf(false)
    // Keep the selected session identity: if it ends, never append into its replacement.
    private var target: NotesControls.Session? = null
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= 33) setRecentsScreenshotEnabled(false)
        shared = if (intent.action == Intent.ACTION_SEND && intent.type == "text/plain")
            intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString() else null
        subject = intent.getStringExtra(Intent.EXTRA_SUBJECT)?.take(200)
        message = when {
            shared == null -> "Only text can be shared to Notes."
            shared!!.length > MAX_TEXT -> "This text is too long. Share up to 100,000 characters."
            shared!!.isBlank() -> "There’s no text to save."
            else -> null
        }
        if (message != null) shared = null
        target = NotesControls.session?.takeIf { canAppend(it) }
        setContent {
            ChirpTheme {
                ShareToNotesDialog(target?.takeIf { canAppend(it) }?.shareTitle, message, shared != null && !saving,
                    save = { save(false) }, append = { save(true) }, cancel = ::finish)
            }
        }
    }
    internal fun save(append: Boolean) {
        val text = shared ?: return
        if (saving) return
        if (append) {
            val current = target
            if (current != null && NotesControls.session === current && canAppend(current) && current.appendShared(text)) finish()
            else { target = null; message = "That note has stopped. Save as a new note instead." }
            return
        }
        saving = true
        lifecycleScope.launch {
            val error = withContext(Dispatchers.IO) {
                try {
                    val notes = library()
                    if (!notes.enabled) "Notes are off. Turn on Keep notes on this phone in Settings → Notes."
                    else {
                        val note = NotesDocument().apply {
                            userEdit(0, 0, text)
                            name = subject?.trim()?.takeIf(String::isNotBlank) ?: text.lineSequence().firstOrNull { it.isNotBlank() }?.trim()?.take(200)
                        }
                        if (notes.put(note.uid, note.toJson())) null else "Couldn’t save the note. Try again."
                    }
                } catch (_: Exception) { "Couldn’t save the note. Try again." }
            }
            saving = false
            if (error == null) finish() else message = error
        }
    }
    override fun onDestroy() { shared = null; subject = null; target = null; super.onDestroy() }
    companion object {
        const val MAX_TEXT = 100_000
        internal fun canAppend(session: NotesControls.Session) = session.state == NotesRecorder.State.RECORDING || session.state == NotesRecorder.State.PAUSED
    }
}

@Composable
internal fun ShareToNotesDialog(recordingTitle: String?, message: String?, enabled: Boolean,
                               save: () -> Unit, append: () -> Unit, cancel: () -> Unit) {
    AlertDialog(onDismissRequest = cancel,
        title = { Text("Save to Notes") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(message ?: "Keep this text on this phone. It stays local unless you choose Organize later.")
                if (recordingTitle != null) OutlinedButton(append, Modifier.fillMaxWidth(), enabled = enabled) {
                    Text("Add to “$recordingTitle”")
                }
            }
        },
        confirmButton = { TextButton(save, enabled = enabled) { Text("Save as new note") } },
        dismissButton = { TextButton(cancel) { Text("Cancel") } })
}
