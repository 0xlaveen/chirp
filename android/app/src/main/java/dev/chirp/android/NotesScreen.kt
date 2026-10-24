package dev.chirp.android

import android.os.SystemClock
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.chirp.android.ui.StatusBanner
import dev.chirp.android.ui.StatusKind
import kotlinx.coroutines.delay

/** The transcript beside the notes from this width (an unfolded Fold, a tablet); a Notes · Transcript switch below it (the cover screen). */
private val SIDE_BY_SIDE = 700.dp

/** Where to put the page when switching between reading and editing: a source offset and its distance from the top, px. */
private data class Anchor(val offset: Int, val y: Int)

/**
 * Live Notes as a notes app: the rendered page is the screen. A compact top bar (title, status, Edit, ⋮), one record
 * control at the bottom, and every other action in the overflow menu. Tap the words (or Edit) to edit the Markdown in
 * place, with a small formatting bar above the keyboard; Done or Back returns to the page at the same place.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalComposeUiApi::class)
@Composable
internal fun NotesScreen(model: NotesModel, record: () -> Unit, copy: () -> Unit, share: () -> Unit, act: (DictationAction) -> Unit,
                         leave: (Boolean) -> Unit, save: () -> Unit = {}, handleBack: Boolean = true) {
    // Discard asked from Back leaves the screen; from New it only empties it.
    var confirm by remember { mutableStateOf<Boolean?>(null) }
    var renaming by remember { mutableStateOf(false) }
    var settings by remember { mutableStateOf(false) }
    var recent by remember { mutableStateOf(false) }
    var pendingOpen by remember { mutableStateOf<NotesIndexEntry?>(null) }
    var editing by rememberSaveable { mutableStateOf(false) }
    var anchor by remember { mutableStateOf<Anchor?>(null) }
    val focus = LocalFocusManager.current
    val list = rememberLazyListState()
    val scroll = rememberScrollState()
    var layout by remember { mutableStateOf<TextLayoutResult?>(null) }
    val blocks = remember(model.field.text) { NotesBlocks.parse(model.field.text) }
    /** Back on the page where the editor was: the block at the top of the editor, at the same height. */
    fun read() {
        layout?.let { l ->
            val offset = l.getOffsetForPosition(Offset(0f, scroll.value.toFloat()))
            blocks.getOrNull(NotesBlocks.at(blocks, offset))?.let { b -> anchor = Anchor(b.start, l.getLineTop(l.getLineForOffset(b.start)).toInt() - scroll.value) }
        }
        focus.clearFocus(); editing = false
    }
    // In the app shell, Back goes to Home and the notes stay in the session; only this screen's own activity asks to discard.
    BackHandler(enabled = handleBack) { if (!model.state.active && model.dirty && !model.keeps) confirm = true else leave(false) }
    BackHandler(enabled = editing) { read() }
    confirm?.let { leaving ->
        AlertDialog({ confirm = null }, title = { Text("Discard these notes?") },
            text = { Text("They aren’t saved. Save, Copy or Share them first to keep them.") },
            confirmButton = { TextButton({ confirm = null; if (leaving) leave(true) else { model.clear(); editing = false } }) { Text("Discard") } },
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
    if (recent) ModalBottomSheet({ recent = false }, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        RecentNotes(model, open = { entry ->
            recent = false
            if (model.dirty && !model.keeps) pendingOpen = entry else { model.open(entry); editing = false }
        })
    }
    pendingOpen?.let { entry ->
        AlertDialog({ pendingOpen = null }, title = { Text("Open other notes?") },
            text = { Text("The notes on screen aren’t saved and will be discarded.") },
            confirmButton = { TextButton({ pendingOpen = null; model.open(entry); editing = false }) { Text("Discard and open") } },
            dismissButton = { TextButton({ pendingOpen = null }) { Text("Keep") } })
    }
    val menu = NotesMenuActions(copy = copy, share = share, save = save, rename = { renaming = true }, settings = { settings = true },
        recent = { model.loadRecent(); recent = true },
        new = { if (model.dirty && !model.keeps) confirm = false else { model.keepSession(); model.clear(); editing = false } })
    val action = DictationAction.forStatus(model.status)
    /** Into the editor at the block tapped (or the first one on screen), at the height it had on the page. */
    fun startEditing(block: NotesBlock?) {
        val keys = NotesBlocks.keys(model.field.text, blocks)
        anchor = list.layoutInfo.visibleItemsInfo.firstNotNullOfOrNull { item ->
            val index = keys.indexOf(item.key).takeIf { it >= 0 && (block == null || blocks[it] == block) } ?: return@firstNotNullOfOrNull null
            Anchor(blocks[index].start, item.offset)
        }
        // A tap puts the caret at the end of the words tapped; Edit keeps the caret where it was.
        if (block != null) model.edit(model.field.copy(selection = TextRange(block.end.coerceAtMost(model.field.text.length))))
        editing = true
    }
    // Test tags as resource ids: the emulator harness reads the rendered page by its blocks' tags, never by their words.
    Surface(Modifier.fillMaxSize().semantics { testTagsAsResourceId = true }) {
        BoxWithConstraints(Modifier.fillMaxSize().safeDrawingPadding()) {
            val wide = maxWidth >= SIDE_BY_SIDE
            val gutter = if (wide) 28.dp else 20.dp
            var tab by rememberSaveable { mutableIntStateOf(0) }
            Column(Modifier.fillMaxSize()) {
                NotesTopBar(model, editing, gutter, edit = { if (editing) read() else startEditing(null) }, menu, rename = { renaming = true })
                Column(Modifier.padding(horizontal = gutter), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (model.retained) StatusBanner(StatusKind.Error, stringResource(R.string.debug_retention))
                    model.recovered?.let { StatusBanner(StatusKind.Info, it, body = "Save, Copy or Share to keep them.", action = "Discard", onAction = { confirm = false }) }
                    if (action != null) StatusBanner(StatusKind.Warning, model.status, action = action.label, onAction = { act(action) })
                }
                if (!wide && !editing) SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(horizontal = gutter, vertical = 8.dp)) {
                    listOf("Notes", "Transcript").forEachIndexed { index, label ->
                        SegmentedButton(tab == index, { tab = index }, SegmentedButtonDefaults.itemShape(index, 2), icon = {}) { Text(label) }
                    }
                }
                Row(Modifier.fillMaxWidth().weight(1f)) {
                    Box(Modifier.weight(1.5f).fillMaxHeight()) {
                        when {
                            editing -> NotesEditor(model, scroll, anchor, { layout = it }, { anchor = null }, gutter, done = ::read)
                            wide || tab == 0 -> NotesPage(model, blocks, list, anchor, { anchor = null }, gutter, edit = ::startEditing)
                            else -> TranscriptPane(model, Modifier.fillMaxSize().padding(horizontal = gutter), titled = false)
                        }
                        if (!editing) NotesDock(model, record, Modifier.align(Alignment.BottomCenter).padding(horizontal = 16.dp, vertical = 16.dp))
                    }
                    if (wide) Surface(Modifier.weight(1f).fillMaxHeight().padding(end = 16.dp, bottom = 16.dp), shape = MaterialTheme.shapes.extraLarge,
                        color = MaterialTheme.colorScheme.surfaceContainerLow) {
                        TranscriptPane(model, Modifier.fillMaxSize().padding(horizontal = 20.dp, vertical = 12.dp))
                    }
                }
            }
        }
    }
}

private class NotesMenuActions(val copy: () -> Unit, val share: () -> Unit, val save: () -> Unit, val rename: () -> Unit, val settings: () -> Unit,
                               val recent: () -> Unit, val new: () -> Unit)

/** Title (tap to rename) over a one-line status, then Edit and the overflow menu. */
@Composable
private fun NotesTopBar(model: NotesModel, editing: Boolean, gutter: androidx.compose.ui.unit.Dp, edit: () -> Unit, menu: NotesMenuActions, rename: () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    Row(Modifier.fillMaxWidth().padding(start = gutter - 4.dp, end = 4.dp, top = 8.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            val title = model.displayTitle
            Text(title, Modifier.clip(MaterialTheme.shapes.small).clickable(onClickLabel = "Rename", onClick = rename).padding(horizontal = 4.dp)
                .semantics { contentDescription = "Rename notes: $title"; heading() },
                style = MaterialTheme.typography.titleLarge.copy(fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold, fontFamily = androidx.compose.ui.text.font.FontFamily.Serif), maxLines = 1, overflow = TextOverflow.Ellipsis)
            Row(Modifier.padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                if (model.state.active) LiveDot(model.recording)
                Text(model.status, Modifier.weight(1f, fill = false).semantics { liveRegion = LiveRegionMode.Polite }, style = MaterialTheme.typography.labelLarge,
                    color = scheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (editing && (model.state.active || model.elapsed > 0)) Text("· " + model.elapsedText, style = dev.chirp.android.ui.ChirpTokens.timerSmall,
                    color = scheme.onSurfaceVariant)
            }
        }
        IconButton(edit) { Icon(painterResource(if (editing) R.drawable.ic_check else R.drawable.ic_edit), if (editing) "Done editing" else "Edit notes") }
        NotesMenu(model, menu)
    }
}

@Composable
private fun LiveDot(on: Boolean) {
    val color = if (on) dev.chirp.android.ui.LocalChirpRoles.current.record else MaterialTheme.colorScheme.outline
    val alpha = if (on) rememberInfiniteTransition(label = "live").animateFloat(1f, .3f, infiniteRepeatable(tween(1000), RepeatMode.Reverse), label = "dot").value else 1f
    Box(Modifier.size(8.dp).alpha(alpha).clip(CircleShape).background(color).clearAndSetSemantics { })
}

@Composable
private fun NotesMenu(model: NotesModel, actions: NotesMenuActions) {
    var open by remember { mutableStateOf(false) }
    Box {
        IconButton({ open = true }) { Icon(painterResource(R.drawable.ic_more_vert), "More options") }
        DropdownMenu(open, { open = false }) {
            @Composable fun item(label: String, icon: Int, enabled: Boolean = true, summary: String? = null, run: () -> Unit) =
                DropdownMenuItem({ Column { Text(label); summary?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) } } },
                    { open = false; run() }, leadingIcon = { Icon(painterResource(icon), null) }, enabled = enabled)
            @Composable fun toggle(label: String, on: Boolean, summary: String? = null, set: (Boolean) -> Unit) =
                DropdownMenuItem({ Column { Text(label); summary?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) } } },
                    { set(!on) }, Modifier.semantics { role = Role.Switch; stateDescription = if (on) "On" else "Off" },
                    trailingIcon = { Switch(on, null, Modifier.clearAndSetSemantics { }) })
            if (model.reorganizing !is Reorganizing.Unavailable) {
                item("Organize", R.drawable.ic_sparkle, model.canOrganize) { model.organize() }
                if (model.canUndo) item("Undo organize", R.drawable.ic_undo) { model.undo() }
            }
            if (model.structureAvailable) toggle("Structure notes", model.structureEnabled, model.structureHost?.let { "Sends text to $it" }) { model.setStructure(it) }
            if (model.reorganizing !is Reorganizing.Unavailable) toggle("Auto-organize", model.auto) { model.setAuto(it) }
            if (model.reorganizing !is Reorganizing.Unavailable || model.structureAvailable) HorizontalDivider()
            item("Copy", R.drawable.ic_copy, model.hasContent, run = actions.copy)
            item("Share", R.drawable.ic_share, model.hasContent, run = actions.share)
            item("Save as Markdown", R.drawable.ic_download, model.hasContent, run = actions.save)
            HorizontalDivider()
            item("Rename", R.drawable.ic_edit, run = actions.rename)
            if (model.keeps) item("Recent notes", R.drawable.ic_history, !model.state.active, run = actions.recent)
            item("New notes", R.drawable.ic_add, !model.state.active && (model.hasContent || model.document.segments.isNotEmpty()), run = actions.new)
            item("Notes settings", R.drawable.ic_settings, run = actions.settings)
        }
    }
}

/**
 * The rendered notes. New blocks fade in at the end; the list keys blocks by content, so text arriving below never moves
 * what is being read, and it follows the end only while the reader is already there.
 */
@Composable
private fun NotesPage(model: NotesModel, blocks: List<NotesBlock>, list: LazyListState, anchor: Anchor?, settled: () -> Unit,
                      gutter: androidx.compose.ui.unit.Dp, edit: (NotesBlock?) -> Unit) {
    val text = model.field.text
    val keys = remember(text, blocks) { NotesBlocks.keys(text, blocks) }
    val hearing = model.hearing
    val explanation = model.explanation
    val lead = if (explanation != null) 1 else 0
    var follow by remember { mutableStateOf(true) }
    LaunchedEffect(list) {
        snapshotFlow { list.isScrollInProgress }.collect { scrolling -> if (!scrolling) follow = !list.canScrollForward }
    }
    LaunchedEffect(keys.lastOrNull(), hearing.length / 40) {
        if (follow && model.state.active && list.layoutInfo.totalItemsCount > 0) list.scrollToItem(list.layoutInfo.totalItemsCount - 1, 100_000)
    }
    LaunchedEffect(anchor) {
        val at = anchor ?: return@LaunchedEffect
        val index = NotesBlocks.at(blocks, at.offset).takeIf { blocks.isNotEmpty() } ?: return@LaunchedEffect settled()
        list.scrollToItem(index + lead); list.scrollBy(-at.y.toFloat()); settled()
    }
    val readable = Modifier.widthIn(max = NOTES_READING_WIDTH).fillMaxWidth().padding(horizontal = gutter)
    LazyColumn(Modifier.fillMaxSize().testTag("notes-page"), list, contentPadding = PaddingValues(top = 4.dp, bottom = 128.dp),
        horizontalAlignment = Alignment.CenterHorizontally) {
        if (explanation != null) item(key = "explanation") {
            Text(explanation, readable.padding(bottom = 8.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        itemsIndexed(blocks, key = { i, _ -> keys[i] }) { _, block ->
            NotesBlockView(block, edit, toggle = { task ->
                model.edit(model.field.copy(text = NotesBlocks.toggle(model.field.text, task)))
            }, readable.animateItem(fadeInSpec = tween(450), placementSpec = null, fadeOutSpec = null))
        }
        if (blocks.isEmpty() && hearing.isBlank()) item(key = "empty") { NotesEmpty(model.state.active, { edit(null) }, readable) }
        if (hearing.isNotBlank()) item(key = "hearing") { HearingLine(hearing, model.recording, readable.animateItem(fadeInSpec = tween(300), placementSpec = null)) }
        if (model.hasContent) item(key = "saved") {
            Text(savedLine(model), readable.padding(top = 24.dp), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.outline)
        }
    }
}

private fun savedLine(model: NotesModel) = when {
    model.keeps -> "Kept encrypted on this phone in Recent notes when you stop or leave. Save, Copy or Share to take them elsewhere."
    !model.dirty -> "Saved. Changes from here on are not, until you Save again."
    model.recoveryOn -> "Not saved until you Save, Copy or Share. Until then a recovery copy stays encrypted on this phone."
    else -> "Not saved: these notes live only on this screen until you Save, Copy or Share them."
}

/**
 * The Markdown itself, borderless on the page, with the syntax lightly styled. The formatting bar (heading, bullet,
 * checklist, undo, Done) sits above the keyboard only while editing.
 */
@Composable
private fun NotesEditor(model: NotesModel, scroll: androidx.compose.foundation.ScrollState, anchor: Anchor?, laidOut: (TextLayoutResult) -> Unit,
                        settled: () -> Unit, gutter: androidx.compose.ui.unit.Dp, done: () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    val undo = remember { NotesTextUndo() }
    val focus = remember { FocusRequester() }
    var layout by remember { mutableStateOf<TextLayoutResult?>(null) }
    val syntax = remember(scheme) { NotesSyntax(scheme.outline, scheme.primary) }
    fun change(value: TextFieldValue) { undo.record(model.field, value.text); model.edit(value) }
    LaunchedEffect(Unit) { focus.requestFocus() }
    LaunchedEffect(layout != null, anchor) {
        val l = layout ?: return@LaunchedEffect; val at = anchor ?: return@LaunchedEffect
        scroll.scrollTo((l.getLineTop(l.getLineForOffset(at.offset.coerceIn(0, l.layoutInput.text.length))) - at.y).toInt().coerceAtLeast(0)); settled()
    }
    Column(Modifier.fillMaxSize()) {
        Box(Modifier.weight(1f).fillMaxWidth().verticalScroll(scroll), contentAlignment = Alignment.TopCenter) {
            BasicTextField(model.field, ::change, Modifier.widthIn(max = NOTES_READING_WIDTH).fillMaxWidth().padding(horizontal = gutter, vertical = 8.dp)
                .focusRequester(focus).onFocusChanged { model.focused = it.isFocused }.semantics { contentDescription = "Notes (Markdown)" },
                textStyle = NotesType.body.copy(color = scheme.onSurface), cursorBrush = SolidColor(scheme.primary), visualTransformation = syntax,
                // No autocorrect or suggestions rewriting what was said.
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences, autoCorrectEnabled = false),
                onTextLayout = { layout = it; laidOut(it) },
                decorationBox = { inner ->
                    Box {
                        if (model.field.text.isEmpty()) Text("Type your notes. # for a heading, - for a list, - [ ] for a to-do",
                            style = NotesType.body, color = scheme.onSurfaceVariant)
                        inner()
                    }
                })
        }
        Surface(color = scheme.surfaceContainer) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                listOf(Triple(NotesLineKind.HEADING, R.drawable.ic_format_heading, "Heading"), Triple(NotesLineKind.BULLET, R.drawable.ic_format_bullets, "Bulleted list"),
                    Triple(NotesLineKind.TASK, R.drawable.ic_checklist, "Checklist")).forEach { (kind, icon, label) ->
                    IconButton({ change(NotesFormat.toggle(model.field, kind)) }) { Icon(painterResource(icon), label) }
                }
                VerticalDivider(Modifier.height(24.dp).padding(horizontal = 4.dp))
                IconButton({ undo.undo(model.field.text)?.let(model::edit) }, enabled = undo.canUndo(model.field.text)) { Icon(painterResource(R.drawable.ic_undo), "Undo") }
                Spacer(Modifier.weight(1f))
                TextButton(done) { Text("Done") }
            }
        }
    }
}

/**
 * The one prominent control: Record when stopped; while recording a floating pill with Pause, the level meter and the
 * running time, and Stop. Edit by voice sits beside it when the Mac offers it. Notes about the last action float above.
 */
@Composable
private fun NotesDock(model: NotesModel, record: () -> Unit, modifier: Modifier) {
    Column(modifier, horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Notices(model)
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
            if (model.voiceEditAvailable && (model.state.active || model.hasContent)) CommandButton(model, Modifier.weight(1f, fill = false))
            if (model.state.active) RecordingPill(model, record) else RecordButton(model, record)
        }
    }
}

@Composable
private fun Notices(model: NotesModel) {
    if (model.listeningForCommand) TextButton(model::cancelCommand) { Text("Cancel") }
    else if (model.showEditedChip) EditedChip(model)
    model.voiceEditNote?.let { note ->
        Notice(note)
        LaunchedEffect(model.voiceEditDone) { delay(NotesVoiceEdit.NOTE_MS); model.dismissVoiceEdit() }
    }
    // Organize's outcome shows for a few seconds, then the page is quiet again.
    val organized = model.organizeNote
    var shown by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(organized) { shown = organized; if (organized != null) { delay(NOTICE_MS); shown = null } }
    AnimatedVisibility(shown != null && model.voiceEditNote == null, enter = fadeIn(), exit = fadeOut()) { Notice(shown ?: "") }
}

private const val NOTICE_MS = 6000L

@Composable
private fun Notice(text: String) {
    Surface(shape = MaterialTheme.shapes.medium, color = MaterialTheme.colorScheme.inverseSurface, contentColor = MaterialTheme.colorScheme.inverseOnSurface,
        shadowElevation = 2.dp) {
        Text(text, Modifier.padding(horizontal = 16.dp, vertical = 10.dp).semantics { liveRegion = LiveRegionMode.Polite }, style = MaterialTheme.typography.bodyMedium)
    }
}

@Composable
private fun RecordButton(model: NotesModel, onClick: () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    Surface(onClick, Modifier.heightIn(min = 64.dp).semantics { contentDescription = "Record notes" }, enabled = !model.busy, shape = CircleShape,
        color = scheme.primaryContainer, contentColor = scheme.onPrimaryContainer, shadowElevation = 6.dp) {
        Row(Modifier.padding(start = 22.dp, end = 26.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Icon(painterResource(R.drawable.ic_record), null, Modifier.size(22.dp), tint = dev.chirp.android.ui.LocalChirpRoles.current.record)
            Text("Record", style = MaterialTheme.typography.titleMedium)
        }
    }
}

@Composable
private fun RecordingPill(model: NotesModel, stop: () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    Surface(shape = CircleShape, color = scheme.surfaceContainerHighest, shadowElevation = 6.dp) {
        Row(Modifier.heightIn(min = 64.dp).padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            val canPause = model.state == NotesRecorder.State.RECORDING || model.paused
            FilledTonalIconButton(model::togglePause, Modifier.size(48.dp).semantics { contentDescription = if (model.paused) "Resume recording notes" else "Pause recording notes" },
                enabled = canPause) {
                Icon(painterResource(if (model.paused) R.drawable.ic_mic else R.drawable.ic_pause), null)
            }
            Column(Modifier.padding(horizontal = 14.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                if (model.busy) CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp) else Meter(model.level, model.recording)
                Text(model.elapsedText, style = dev.chirp.android.ui.ChirpTokens.timer)
            }
            FilledIconButton(stop, Modifier.size(48.dp).semantics { contentDescription = "Stop recording notes" }, enabled = !model.busy,
                colors = IconButtonDefaults.filledIconButtonColors(containerColor = dev.chirp.android.ui.LocalChirpRoles.current.record, contentColor = scheme.onError)) {
                Icon(painterResource(R.drawable.ic_stop), null)
            }
        }
    }
}

/** Sound is arriving: five bars that follow the input level while the microphone is open, flat while paused. */
@Composable
private fun Meter(level: Double, open: Boolean) {
    val loud by animateFloatAsState(if (open) kotlin.math.sqrt(level * 8).toFloat().coerceIn(0f, 1f) else 0f, tween(180), label = "level")
    val color = if (open) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline
    Row(Modifier.height(16.dp).clearAndSetSemantics { }, horizontalArrangement = Arrangement.spacedBy(3.dp), verticalAlignment = Alignment.CenterVertically) {
        listOf(.45f, .8f, 1f, .7f, .5f).forEach { weight ->
            Box(Modifier.width(3.dp).fillMaxHeight(.3f + .7f * loud * weight).clip(CircleShape).background(color))
        }
    }
}

/**
 * Edit by voice: hold it and say what to change, let go to send. A quick tap latches it and the next tap sends, which is
 * also what TalkBack's double tap does. What is said goes to the edit and never into the transcript.
 */
@Composable
private fun CommandButton(model: NotesModel, modifier: Modifier) {
    val listening = model.listeningForCommand
    val enabled = model.canCommand
    var pressed by remember { mutableStateOf(false) }
    val colors = MaterialTheme.colorScheme
    val (container, content) = if (listening) colors.errorContainer to colors.onErrorContainer else colors.secondaryContainer to colors.onSecondaryContainer
    Surface(modifier.heightIn(min = 56.dp).alpha(if (enabled) 1f else 0.38f)
        .pointerInput(enabled) {
            if (enabled) awaitEachGesture {
                val down = awaitFirstDown()
                pressed = true; model.commandPress()
                val up = waitForUpOrCancellation()
                pressed = false
                model.commandRelease((up?.uptimeMillis ?: SystemClock.uptimeMillis()) - down.uptimeMillis)
            }
        }
        .semantics(mergeDescendants = true) {
            role = Role.Button
            contentDescription = if (listening) "Send the spoken edit" else "Edit notes by voice. Hold, say the change, let go."
            onClick(if (listening) "Send" else "Start") { model.command(); true }
            if (!enabled) disabled()
        }, shape = CircleShape, color = container, contentColor = content, shadowElevation = 3.dp) {
        Row(Modifier.padding(horizontal = 18.dp), Arrangement.Center, Alignment.CenterVertically) {
            Icon(painterResource(if (listening) R.drawable.ic_mic else R.drawable.ic_sparkle), null, Modifier.size(20.dp))
            Spacer(Modifier.width(8.dp))
            Text(when { !listening -> "Hold to edit"; pressed -> "Release to send"; else -> "Tap to send" }, style = MaterialTheme.typography.labelLarge,
                maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

/** "Edited · Undo", for 20 s after a voice edit (or until the next edit or a click). */
@Composable
private fun EditedChip(model: NotesModel) {
    Surface(shape = CircleShape, color = MaterialTheme.colorScheme.tertiaryContainer, contentColor = MaterialTheme.colorScheme.onTertiaryContainer, shadowElevation = 2.dp) {
        Row(Modifier.padding(start = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(NotesVoiceEditText.EDITED, style = MaterialTheme.typography.labelLarge)
            TextButton(model::undoVoiceEdit, Modifier.semantics { contentDescription = "Undo the spoken edit" }) { Text("Undo") }
        }
    }
    LaunchedEffect(model.voiceEditDone) { delay(NotesVoiceEdit.CHIP_MS); model.dismissVoiceEdit() }
}

/** One quiet line per segment: the time as metadata, then what was said. */
@Composable
private fun TranscriptPane(model: NotesModel, modifier: Modifier, titled: Boolean = true) {
    val scheme = MaterialTheme.colorScheme
    Column(modifier) {
        Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            if (titled) Text("Transcript", Modifier.semantics { heading() }, style = MaterialTheme.typography.titleSmall, color = scheme.onSurfaceVariant)
            Spacer(Modifier.weight(1f))
            FilterChip(model.raw, { model.raw = !model.raw }, label = { Text("Show raw") })
        }
        val document = model.document
        // A copy: the document's list is the same object as it grows, which the lazy list would not see change.
        val rows = document.segments.toList()
        val list = rememberLazyListState()
        LaunchedEffect(rows.size) { if (rows.isNotEmpty() && !list.canScrollForward) list.animateScrollToItem(rows.size) }
        LazyColumn(Modifier.fillMaxWidth().weight(1f), list, contentPadding = PaddingValues(top = 4.dp, bottom = 128.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            items(rows, key = { it.id }) { segment ->
                Row(Modifier.animateItem(fadeInSpec = tween(300), placementSpec = null), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(NotesDocument.timestamp(segment.offset), Modifier.padding(top = 2.dp), style = MaterialTheme.typography.labelSmall, fontFamily = FontFamily.Monospace,
                        color = scheme.outline)
                    val failure = segment.failure
                    if (failure != null) Text("⚠︎ audio not transcribed ($failure)", color = scheme.error, style = MaterialTheme.typography.bodyMedium)
                    else Text((if (model.raw) segment.raw else segment.text) + if (segment.keptOriginal && !model.raw) " (kept original)" else "",
                        style = MaterialTheme.typography.bodyMedium)
                }
            }
            if (document.livePartial.isNotBlank()) item(key = "partial") {
                Text(document.livePartial, Modifier.padding(start = 76.dp), color = scheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium, fontStyle = FontStyle.Italic)
            }
            if (rows.isEmpty() && document.livePartial.isBlank()) item(key = "empty") {
                Text("What is said appears here, a line per segment.", color = scheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium)
            }
        }
    }
}

/** Kept notes as a notes list: title, when, a preview of the words, and search. */
@Composable
private fun RecentNotes(model: NotesModel, open: (NotesIndexEntry) -> Unit) {
    val now = System.currentTimeMillis()
    var query by rememberSaveable { mutableStateOf("") }
    val shown = model.recent.filter { entry -> query.isBlank() || entry.title.contains(query.trim(), true) || entry.snippet.contains(query.trim(), true) }
    Column(Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Recent notes", Modifier.padding(horizontal = 8.dp).semantics { heading() }, style = MaterialTheme.typography.titleLarge)
        if (model.recent.isEmpty()) Text("Notes you stop or leave are kept here, encrypted on this phone.", Modifier.padding(horizontal = 8.dp),
            style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        else OutlinedTextField(query, { query = it }, Modifier.fillMaxWidth(), placeholder = { Text("Search notes") }, singleLine = true,
            leadingIcon = { Icon(painterResource(R.drawable.ic_search), null) }, shape = CircleShape,
            trailingIcon = if (query.isEmpty()) null else ({ IconButton({ query = "" }) { Icon(painterResource(R.drawable.ic_close), "Clear search") } }))
        if (model.recent.isNotEmpty() && shown.isEmpty()) Text("No notes match.", Modifier.padding(horizontal = 8.dp), style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        LazyColumn(Modifier.fillMaxWidth().heightIn(max = 520.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            items(shown, key = { it.id }) { entry ->
                val (age, spoken) = historyAge(now, entry.updatedAt)
                ListItem(headlineContent = { Text(entry.title, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.titleMedium) },
                    overlineContent = { Text(age) },
                    supportingContent = entry.snippet.takeIf { it.isNotBlank() }?.let { { Text(it, maxLines = 2, overflow = TextOverflow.Ellipsis) } },
                    modifier = Modifier.clip(MaterialTheme.shapes.large).clickable(onClickLabel = "Open") { open(entry) }.semantics { stateDescription = spoken },
                    trailingContent = { IconButton({ model.deleteKept(entry) }) { Icon(painterResource(R.drawable.ic_delete), "Delete ${entry.title}") } },
                    colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.surfaceContainer))
            }
        }
    }
}
