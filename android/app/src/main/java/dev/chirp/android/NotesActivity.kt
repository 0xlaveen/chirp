package dev.chirp.android

import android.Manifest
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PersistableBundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.background
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory

/**
 * Live Notes on the phone: record a meeting or a long think-aloud, and the Mac turns it into Markdown notes while the
 * transcript fills in beside them. Memory only: the notes leave with the screen (New, or Discard on Back).
 */
open class NotesActivity : ComponentActivity() {
    internal open fun createModel(): NotesModel = NotesModel(applicationContext)
    internal open val tailscale: TailscaleControl by lazy { AndroidTailscale(this) }
    internal val model: NotesModel by viewModels { viewModelFactory { initializer { createModel() } } }
    private val micPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) record() else model.message = "Microphone permission is needed to take notes — open mic settings"
    }
    /** Optional: without it the recording still runs, only its notification (with Stop) stays hidden. */
    private val notificationPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { model.start() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Keep the notes out of the Recents thumbnail.
        if (Build.VERSION.SDK_INT >= 33) setRecentsScreenshotEnabled(false)
        handle(intent)
        setContent {
            ChirpTheme {
                NotesScreen(model, record = ::record, copy = ::copy, share = ::share, act = ::act, leave = ::leave)
            }
        }
    }
    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); handle(intent) }
    override fun onStart() { super.onStart(); model.refresh() }

    private fun handle(intent: Intent?) {
        if (intent?.action == NotesService.ACTION_STOP) { if (model.recording) model.stop(); setIntent(Intent(intent).setAction(null)) }
    }

    internal fun record() {
        if (model.state.active) { model.toggle(); return }
        when {
            checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED -> micPermission.launch(Manifest.permission.RECORD_AUDIO)
            Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED &&
                !asked -> { asked = true; notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS) }
            else -> model.start()
        }
    }
    private var asked = false

    /** Back while recording keeps it going in the background; with notes, it asks first (nothing is saved). */
    internal fun leave(discard: Boolean) {
        when {
            model.state.active -> moveTaskToBack(true)
            discard || !model.hasContent -> { model.clear(); finish() }
        }
    }

    internal fun copy() {
        if (!model.hasContent) return
        val clip = ClipData.newPlainText("Chirp notes", model.export())
        // Keeps the notes out of clipboard previews and overlays where the system supports it.
        clip.description.extras = PersistableBundle().apply {
            putBoolean(if (Build.VERSION.SDK_INT >= 33) ClipDescription.EXTRA_IS_SENSITIVE else "android.content.extra.IS_SENSITIVE", true)
        }
        getSystemService(ClipboardManager::class.java)?.setPrimaryClip(clip)
        model.message = "Copied as Markdown"
    }
    internal fun share() {
        if (!model.hasContent) return
        startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/markdown")
            .putExtra(Intent.EXTRA_SUBJECT, model.document.title().removePrefix("# ")).putExtra(Intent.EXTRA_TEXT, model.export()), null))
    }
    internal fun act(action: DictationAction) {
        fun setup(section: String) = startActivity(Intent(this, SetupActivity::class.java).putExtra("section", section)
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP))
        when (action) {
            DictationAction.PAIR -> setup("pair")
            DictationAction.MICROPHONE -> startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null)))
            DictationAction.NETWORK, DictationAction.TAILSCALE_OPEN -> if (!tailscale.open()) setup("network")
            DictationAction.TAILSCALE_SETUP -> setup("network")
            DictationAction.TAILSCALE_ON -> if (tailscale.connect()) model.message = "Connecting Tailscale…" else if (!tailscale.open()) setup("network")
        }
    }

    companion object {
        /** Opens Notes from outside (the recording notification), reusing the running screen. */
        fun intent(context: Context) = Intent(context, NotesActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
    }
}

/** Notes beside the transcript at this width (an unfolded Fold, a tablet); tabs below it (the cover screen). */
private val SIDE_BY_SIDE = 700.dp

@Composable
internal fun NotesScreen(model: NotesModel, record: () -> Unit, copy: () -> Unit, share: () -> Unit, act: (DictationAction) -> Unit,
                         leave: (Boolean) -> Unit) {
    // Discard asked from Back leaves the screen; from New it only empties it.
    var confirm by remember { mutableStateOf<Boolean?>(null) }
    BackHandler { if (!model.state.active && model.hasContent) confirm = true else leave(false) }
    confirm?.let { leaving ->
        AlertDialog({ confirm = null }, title = { Text("Discard these notes?") },
            text = { Text("Nothing is saved. Copy or Share them first to keep them.") },
            confirmButton = { TextButton({ confirm = null; if (leaving) leave(true) else model.clear() }) { Text("Discard") } },
            dismissButton = { TextButton({ confirm = null }) { Text("Keep") } })
    }
    val action = DictationAction.forStatus(model.status)
    Surface(Modifier.fillMaxSize()) {
        BoxWithConstraints(Modifier.fillMaxSize().safeDrawingPadding()) {
            val wide = maxWidth >= SIDE_BY_SIDE
            Column(Modifier.fillMaxSize().padding(horizontal = if (wide) 24.dp else 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("CHIRP  /  NOTES", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
                if (model.retained) Text(stringResource(R.string.debug_retention), Modifier.fillMaxWidth().background(Color(0xFFA41818)).padding(8.dp),
                    color = Color.White, style = MaterialTheme.typography.labelLarge)
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    RecordButton(model, record)
                    Column(Modifier.weight(1f)) {
                        if (model.state.active || model.elapsed > 0) Text(model.elapsedText, style = MaterialTheme.typography.titleMedium.copy(fontFeatureSettings = "tnum"))
                        Text(model.status, Modifier.semantics { liveRegion = LiveRegionMode.Polite }, style = MaterialTheme.typography.bodyMedium)
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
                    TextButton({ if (model.hasContent) confirm = false else model.clear() }, enabled = !model.state.active && (model.hasContent || model.document.segments.isNotEmpty())) { Text("New") }
                }
                Text("Nothing is saved: these notes live only on this screen. Copy or Share to keep them.", style = MaterialTheme.typography.bodySmall)
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
