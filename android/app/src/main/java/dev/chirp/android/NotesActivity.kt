package dev.chirp.android

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.foundation.clickable
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import dev.chirp.android.ui.StatusBanner
import dev.chirp.android.ui.StatusKind

/**
 * Live Notes on the phone: record a meeting or a long think-aloud, and the Mac turns it into Markdown notes while the
 * transcript fills in beside them. Kept until Save, Copy or Share, with a sealed recovery copy meanwhile ([NotesJournal]).
 * The screen itself is [NotesScreen], which the app shell also hosts as its Notes tab; both share one session ([NotesSessionHolder]).
 */
open class NotesActivity : ComponentActivity() {
    internal open fun createModel(): NotesModel = NotesModel(applicationContext)
    internal open val tailscale: TailscaleControl by lazy { AndroidTailscale(this) }
    internal val model: NotesModel by lazy { NotesSessionHolder.model(this, ::createModel) }
    private val host = NotesHost(this, { tailscale }, { model })
    private var recordOnResume = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Keep the notes out of the Recents thumbnail.
        if (Build.VERSION.SDK_INT >= 33) setRecentsScreenshotEnabled(false)
        handle(intent)
        setContent {
            ChirpTheme {
                NotesScreen(model, record = ::record, copy = ::copy, share = ::share, act = ::act, leave = ::leave, save = ::save)
            }
        }
    }
    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); handle(intent) }
    override fun onStart() { super.onStart(); NotesSessionHolder.visible(model, this, true); model.refresh() }
    // Screen off or another app in front: the battery saver skips screen work until this is visible again.
    override fun onStop() { NotesSessionHolder.visible(model, this, false); super.onStop() }
    // The microphone service may only start from a visible screen: the tile's Record waits until this one is.
    override fun onResume() { super.onResume(); if (recordOnResume) { recordOnResume = false; if (!model.state.active) record() } }

    private fun handle(intent: Intent?) {
        when (intent?.action) {
            NotesService.ACTION_STOP -> if (model.state.live) model.stop()
            NotesService.ACTION_RECORD -> recordOnResume = true
            else -> return
        }
        setIntent(Intent(intent).setAction(null))
    }

    internal fun record() = host.record()

    /** Back while recording keeps it going in the background; with notes, it asks first (nothing is saved). */
    internal fun leave(discard: Boolean) {
        when {
            model.state.active -> moveTaskToBack(true)
            discard || !model.dirty || model.keepSession() -> { model.clear(); finish() }
        }
    }

    internal fun copy() = host.copy()
    internal fun share() = host.share()
    internal fun save() = host.save()
    internal fun write(uri: Uri) = host.write(uri)
    internal fun act(action: DictationAction) = host.act(action)

    companion object {
        /** Opens Notes from outside (the recording notification), reusing the running screen. */
        fun intent(context: Context) = Intent(context, NotesActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
    }
}

/** Notes beside the transcript at this width (an unfolded Fold, a tablet); tabs below it (the cover screen). */
private val SIDE_BY_SIDE = 700.dp

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun NotesScreen(model: NotesModel, record: () -> Unit, copy: () -> Unit, share: () -> Unit, act: (DictationAction) -> Unit,
                         leave: (Boolean) -> Unit, save: () -> Unit = {}, handleBack: Boolean = true) {
    // Discard asked from Back leaves the screen; from New it only empties it.
    var confirm by remember { mutableStateOf<Boolean?>(null) }
    var renaming by remember { mutableStateOf(false) }
    var settings by remember { mutableStateOf(false) }
    var recent by remember { mutableStateOf(false) }
    var pendingOpen by remember { mutableStateOf<NotesSessionEntry?>(null) }
    // In the app shell, Back goes to Home and the notes stay in the session; only this screen's own activity asks to discard.
    BackHandler(enabled = handleBack) { if (!model.state.active && model.dirty && !model.keeps) confirm = true else leave(false) }
    confirm?.let { leaving ->
        AlertDialog({ confirm = null }, title = { Text("Discard these notes?") },
            text = { Text("They aren’t saved. Save, Copy or Share them first to keep them.") },
            confirmButton = { TextButton({ confirm = null; if (leaving) leave(true) else model.clear() }) { Text("Discard") } },
            dismissButton = { TextButton({ confirm = null }) { Text("Keep") } })
    }
    if (renaming) {
        var name by remember { mutableStateOf(model.document.name ?: "") }
        AlertDialog({ renaming = false }, title = { Text("Rename notes") },
            text = { OutlinedTextField(name, { name = it.take(NotesModel.MAX_NAME) }, singleLine = true, label = { Text("Name") },
                placeholder = { Text(NotesDocument().title().removePrefix("# ")) }) },
            confirmButton = { TextButton({ renaming = false; model.rename(name) }) { Text("Rename") } },
            dismissButton = { TextButton({ renaming = false }) { Text("Cancel") } })
    }
    if (settings) ModalBottomSheet({ settings = false }) {
        Column(Modifier.padding(start = 16.dp, end = 16.dp, bottom = 24.dp)) { NotesSettings(title = "Notes settings") }
    }
    if (recent) ModalBottomSheet({ recent = false }) {
        RecentNotes(model, open = { entry ->
            recent = false
            if (model.dirty && !model.keeps) pendingOpen = entry else model.open(entry)
        })
    }
    pendingOpen?.let { entry ->
        AlertDialog({ pendingOpen = null }, title = { Text("Open other notes?") },
            text = { Text("The notes on screen aren’t saved and will be discarded.") },
            confirmButton = { TextButton({ pendingOpen = null; model.open(entry) }) { Text("Discard and open") } },
            dismissButton = { TextButton({ pendingOpen = null }) { Text("Keep") } })
    }
    val action = DictationAction.forStatus(model.status)
    Surface(Modifier.fillMaxSize()) {
        BoxWithConstraints(Modifier.fillMaxSize().safeDrawingPadding()) {
            val wide = maxWidth >= SIDE_BY_SIDE
            Column(Modifier.fillMaxSize().padding(horizontal = if (wide) 24.dp else 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("CHIRP  /  NOTES", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
                        TextButton({ renaming = true }, contentPadding = PaddingValues(0.dp),
                            modifier = Modifier.semantics { contentDescription = "Rename notes: ${model.title}" }) {
                            Text(model.title, style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurface, maxLines = 1)
                        }
                    }
                    if (model.keeps) IconButton({ model.loadRecent(); recent = true }, enabled = !model.state.active) {
                        Icon(painterResource(R.drawable.ic_history), "Recent notes")
                    }
                    IconButton({ settings = true }) { Icon(painterResource(R.drawable.ic_settings), "Notes settings") }
                }
                if (model.retained) StatusBanner(StatusKind.Error, stringResource(R.string.debug_retention))
                model.recovered?.let { StatusBanner(StatusKind.Info, it, body = "Save, Copy or Share to keep them.", action = "Discard", onAction = { confirm = false }) }
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    RecordButton(model, record)
                    if (model.state == NotesRecorder.State.RECORDING || model.paused) PauseButton(model)
                    Column(Modifier.weight(1f)) {
                        if (model.state.active || model.elapsed > 0) Text(model.elapsedText, style = MaterialTheme.typography.titleMedium.copy(fontFeatureSettings = "tnum"))
                        Text(model.status, Modifier.semantics { liveRegion = LiveRegionMode.Polite }, style = MaterialTheme.typography.bodyMedium)
                        // Sound is arriving: a small input meter while the microphone is open.
                        if (model.recording) LinearProgressIndicator({ kotlin.math.sqrt(model.level * 8).toFloat().coerceIn(0f, 1f) },
                            Modifier.padding(top = 4.dp).width(96.dp).clearAndSetSemantics { }, drawStopIndicator = {})
                    }
                    if (action != null) TextButton({ act(action) }) { Text(action.label) }
                }
                model.explanation?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                if (model.structureAvailable) Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterChip(model.structureEnabled, { model.setStructure(!model.structureEnabled) },
                        label = { Text(model.structureHost?.let { "Structure notes (sends text to $it)" } ?: "Structure notes") })
                    if (model.reorganizing !is Reorganizing.Unavailable) FilterChip(model.auto, { model.setAuto(!model.auto) }, label = { Text("Auto-organize") })
                }
                if (wide) Row(Modifier.fillMaxWidth().weight(1f), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                    NotesPane(model, Modifier.weight(1.4f))
                    TranscriptPane(model, Modifier.weight(1f))
                } else {
                    var tab by rememberSaveable { mutableIntStateOf(0) }
                    PrimaryTabRow(tab) {
                        Tab(tab == 0, { tab = 0 }, text = { Text("Notes") })
                        Tab(tab == 1, { tab = 1 }, text = { Text("Transcript") })
                    }
                    if (tab == 0) NotesPane(model, Modifier.fillMaxWidth().weight(1f)) else TranscriptPane(model, Modifier.fillMaxWidth().weight(1f))
                }
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(copy, Modifier.weight(1f), enabled = model.hasContent) { Text("Copy") }
                    OutlinedButton(share, Modifier.weight(1f), enabled = model.hasContent) { Text("Share") }
                    OutlinedButton(save, Modifier.weight(1f), enabled = model.hasContent) { Text("Save") }
                    TextButton({ if (model.dirty && !model.keeps) confirm = false else { model.keepSession(); model.clear() } }, enabled = !model.state.active && (model.hasContent || model.document.segments.isNotEmpty())) { Text("New") }
                }
                Text(when {
                    model.keeps -> "Kept encrypted on this phone in Recent notes when you stop or leave. Save, Copy or Share to take them elsewhere."
                    model.hasContent && !model.dirty -> "Saved. Changes from here on are not, until you Save again."
                    model.recoveryOn -> "Not saved until you Save, Copy or Share. Until then a recovery copy stays encrypted on this phone."
                    else -> "Not saved: these notes live only on this screen until you Save, Copy or Share them."
                }, style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}

@Composable
private fun RecordButton(model: NotesModel, onClick: () -> Unit) {
    val recording = model.state.active
    Button(onClick, Modifier.heightIn(min = 56.dp).semantics { contentDescription = if (recording) "Stop recording notes" else "Record notes" },
        enabled = !model.busy, colors = if (recording) ButtonDefaults.buttonColors(MaterialTheme.colorScheme.error) else ButtonDefaults.buttonColors()) {
        Icon(painterResource(if (recording) R.drawable.ic_stop else R.drawable.ic_record), null, Modifier.size(20.dp))
        Spacer(Modifier.width(8.dp))
        Text(if (recording) "Stop" else "Record")
    }
}

@Composable
private fun RecentNotes(model: NotesModel, open: (NotesSessionEntry) -> Unit) {
    val now = System.currentTimeMillis()
    Column(Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Recent notes", Modifier.semantics { heading() }, style = MaterialTheme.typography.titleLarge)
        if (model.recent.isEmpty()) Text("Notes you stop or leave are kept here, encrypted on this phone.", style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        LazyColumn(Modifier.fillMaxWidth().heightIn(max = 480.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            items(model.recent, key = { it.id }) { entry ->
                val (age, spoken) = historyAge(now, entry.time)
                ListItem(headlineContent = { Text(entry.title, maxLines = 1) }, supportingContent = { Text("$age · ${entry.chars} characters") },
                    modifier = Modifier.clickable(onClickLabel = "Open") { open(entry) }.semantics { stateDescription = spoken },
                    trailingContent = { IconButton({ model.deleteKept(entry) }) { Icon(painterResource(R.drawable.ic_delete), "Delete ${entry.title}") } },
                    colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.surfaceContainer))
            }
        }
    }
}

@Composable
private fun PauseButton(model: NotesModel) {
    FilledTonalButton(model::togglePause, Modifier.heightIn(min = 56.dp).semantics { contentDescription = if (model.paused) "Resume recording notes" else "Pause recording notes" }) {
        Icon(painterResource(if (model.paused) R.drawable.ic_record else R.drawable.ic_pause), null, Modifier.size(20.dp))
        Spacer(Modifier.width(8.dp))
        Text(if (model.paused) "Resume" else "Pause")
    }
}

@Composable
private fun NotesPane(model: NotesModel, modifier: Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedTextField(model.field, model::edit, Modifier.fillMaxWidth().weight(1f).heightIn(min = 160.dp)
            .onFocusChanged { model.focused = it.isFocused },
            label = { Text("Notes (Markdown)") }, placeholder = { Text("Record, or type your own notes") },
            textStyle = MaterialTheme.typography.bodyMedium,
            // No autocorrect or suggestions rewriting what was said.
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences, autoCorrectEnabled = false))
        if (model.hearing.isNotBlank()) Text("Hearing: " + model.hearing, Modifier.fillMaxWidth(), color = MaterialTheme.colorScheme.onSurfaceVariant,
            style = MaterialTheme.typography.bodySmall, fontStyle = FontStyle.Italic, maxLines = 3)
        if (model.reorganizing !is Reorganizing.Unavailable) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            FilledTonalButton(model::organize, enabled = model.canOrganize) { Text("Organize") }
            if (model.canUndo) TextButton(model::undo) { Text("Undo organize") }
            model.organizeNote?.let { Text(it, Modifier.weight(1f), style = MaterialTheme.typography.bodySmall) }
        } else model.organizeNote?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
    }
}

@Composable
private fun TranscriptPane(model: NotesModel, modifier: Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Transcript", Modifier.weight(1f), style = MaterialTheme.typography.titleSmall)
            FilterChip(model.raw, { model.raw = !model.raw }, label = { Text("Show raw") })
        }
        val document = model.document
        // A copy: the document's list is the same object as it grows, which the lazy list would not see change.
        val rows = document.segments.toList()
        LazyColumn(Modifier.fillMaxWidth().weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            items(rows, key = { it.id }) { segment ->
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(NotesDocument.timestamp(segment.offset), style = MaterialTheme.typography.labelSmall, fontFamily = FontFamily.Monospace,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                    val failure = segment.failure
                    if (failure != null) Text("⚠︎ audio not transcribed ($failure)", color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
                    else Text((if (model.raw) segment.raw else segment.text) + if (segment.keptOriginal && !model.raw) " (kept original)" else "",
                        style = MaterialTheme.typography.bodySmall)
                }
            }
            if (document.livePartial.isNotBlank()) item {
                Text(document.livePartial, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall, fontStyle = FontStyle.Italic)
            }
            if (rows.isEmpty() && document.livePartial.isBlank()) item {
                Text("What is said appears here, a line per segment.", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}
