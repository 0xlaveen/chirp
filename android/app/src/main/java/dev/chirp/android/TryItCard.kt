package dev.chirp.android

import android.content.Intent
import android.content.res.ColorStateList
import android.text.InputType
import android.view.View
import android.widget.EditText
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import dev.chirp.android.ui.NavRow
import dev.chirp.android.ui.SettingsGroup
import kotlinx.coroutines.launch

/** First-run card above Chirp settings: a real field to type and dictate into, plus the Scratchpad and Notes. Stays until dismissed. */
@Composable
internal fun TryItCard(store: SettingsStore, onDismiss: () -> Unit) {
    val context = LocalContext.current
    Surface(Modifier.fillMaxWidth(), shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.surfaceContainer) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("Try it", Modifier.semantics { heading() }, style = MaterialTheme.typography.titleLarge)
            Text("Tap the field, type on Chirp Keyboard, then tap its mic to dictate. Tap ✓ to finish (or pause, if you chose When I pause); long press the mic for quick options.",
                style = MaterialTheme.typography.bodyMedium)
            // Deliberately a real native editor: exercises the same InputConnection/accessibility path as other apps.
            val editorInk = MaterialTheme.colorScheme.onSurface.toArgb()
            val editorHint = MaterialTheme.colorScheme.onSurfaceVariant.toArgb()
            val editorAccent = MaterialTheme.colorScheme.primary.toArgb()
            val bringEditor = remember { BringIntoViewRequester() }
            val editorScope = rememberCoroutineScope()
            AndroidView(factory = { editorContext -> EditText(editorContext).apply {
                hint = "Test dictation here"; minLines = 3
                inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_AUTO_CORRECT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
                onFocusChangeListener = View.OnFocusChangeListener { _, focused ->
                    if (focused) postDelayed({ editorScope.launch { bringEditor.bringIntoView() } }, 350)
                }
                isSaveEnabled = false; importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS
            } }, update = { editor ->
                editor.setTextColor(editorInk); editor.setHintTextColor(editorHint)
                editor.backgroundTintList = ColorStateList.valueOf(editorAccent)
            }, modifier = Modifier.fillMaxWidth().bringIntoViewRequester(bringEditor))
            SettingsGroup {
                NavRow("Open Scratchpad", { context.startActivity(Intent(context, ScratchpadActivity::class.java)) })
                NavRow("Choose keyboard", { context.getSystemService(android.view.inputmethod.InputMethodManager::class.java).showInputMethodPicker() })
                NavRow("Open Notes", { context.startActivity(Intent(context, NotesActivity::class.java)) })
            }
            TextButton({ store.tryItDismissed = true; onDismiss() }, Modifier.align(Alignment.End)) { Text("Dismiss") }
        }
    }
}
