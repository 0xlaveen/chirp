package dev.chirp.android.shell

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.PersistableBundle
import androidx.annotation.DrawableRes
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import dev.chirp.android.DictationHistory
import dev.chirp.android.HistoryEntry
import dev.chirp.android.HistorySettings
import dev.chirp.android.R
import dev.chirp.android.historyAge
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

internal enum class HistoryDay(val label: String) { Today("Today"), Yesterday("Yesterday"), Earlier("Earlier") }

/** Calendar day in [zone], not a 24-hour window: a dictation from 23:50 is Yesterday at 00:10. */
internal fun historyDay(now: Long, time: Long, zone: ZoneId = ZoneId.systemDefault()): HistoryDay {
    val today = Instant.ofEpochMilli(now).atZone(zone).toLocalDate()
    val day = Instant.ofEpochMilli(time).atZone(zone).toLocalDate()
    return when { !day.isBefore(today) -> HistoryDay.Today; day == today.minusDays(1) -> HistoryDay.Yesterday; else -> HistoryDay.Earlier }
}

internal fun historyMatches(entry: HistoryEntry, query: String): Boolean =
    query.isBlank() || listOfNotNull(entry.text, entry.raw, entry.app).any { it.contains(query.trim(), ignoreCase = true) }

/** "Gmail · 2 min ago · cleaned": app, age and whether clean-up changed it. Never any of the text. */
internal fun historyMeta(entry: HistoryEntry, now: Long): String =
    listOfNotNull(entry.app, historyAge(now, entry.time).first, if (entry.partial) "partial" else if (entry.raw != null) "cleaned" else null).joinToString(" · ")

/** Dictated text on the clipboard, kept out of clipboard previews and overlays where the system supports it. */
internal fun copyPrivately(context: Context, label: String, text: String) {
    val clip = ClipData.newPlainText(label, text)
    clip.description.extras = PersistableBundle().apply {
        putBoolean(if (Build.VERSION.SDK_INT >= 33) ClipDescription.EXTRA_IS_SENSITIVE else "android.content.extra.IS_SENSITIVE", true)
    }
    context.getSystemService(ClipboardManager::class.java)?.setPrimaryClip(clip)
}

private val LIST_DETAIL = 600.dp

/**
 * The History tab: search, entries grouped by day, a detail sheet (a side pane from 600 dp) with Copy, Copy raw, Share and Delete,
 * and swipe-to-delete with Undo. Opt-in, retention and clear sit behind ⋮. [selected]/[select] hoist the open entry (null: kept here).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun HistoryScreen(store: DictationHistory? = null, now: () -> Long = System::currentTimeMillis, zone: ZoneId = ZoneId.systemDefault(),
                           selected: String? = null, select: ((String?) -> Unit)? = null) {
    val context = LocalContext.current
    val history = store ?: remember { DictationHistory(context) }
    val scope = rememberCoroutineScope()
    val snackbar = remember { SnackbarHostState() }
    var enabled by remember { mutableStateOf(history.enabled) }
    var entries by remember { mutableStateOf<List<HistoryEntry>?>(null) }
    var reload by remember { mutableIntStateOf(0) }
    /** Bumped by Undo: a restored row must not come back with its saved "swiped away" state. */
    var restores by rememberSaveable { mutableIntStateOf(0) }
    var query by rememberSaveable { mutableStateOf("") }
    var settings by rememberSaveable { mutableStateOf(false) }
    var menu by remember { mutableStateOf(false) }
    var own by rememberSaveable { mutableStateOf<String?>(null) }
    val open = if (select == null) own else selected
    val choose: (String?) -> Unit = select ?: { own = it }
    LaunchedEffect(reload, enabled) { entries = withContext(Dispatchers.IO) { history.entries() } }
    // New dictations arrive from the keyboard while this screen is in the background.
    LifecycleResumeEffect(history) { enabled = history.enabled; reload++; onPauseOrDispose { } }
    val shown = entries.orEmpty().filter { historyMatches(it, query) }
    val current = open?.let { id -> entries?.firstOrNull { it.id == id } }
    fun delete(entry: HistoryEntry) {
        if (open == entry.id) choose(null)
        entries = entries?.filter { it.id != entry.id }
        scope.launch {
            withContext(Dispatchers.IO) { history.delete(entry.id) }
            snackbar.currentSnackbarData?.dismiss()
            if (snackbar.showSnackbar("Dictation deleted", actionLabel = "Undo", duration = SnackbarDuration.Long) == SnackbarResult.ActionPerformed) {
                withContext(Dispatchers.IO) { history.restore(entry) }; restores++; reload++
            }
        }
    }
    val actions = DetailActions(copy = { label, text -> copyPrivately(context, label, text) },
        share = { text -> context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text), null)) },
        delete = ::delete)
    Surface(Modifier.fillMaxSize()) {
        BoxWithConstraints(Modifier.fillMaxSize().safeDrawingPadding(), contentAlignment = Alignment.TopCenter) {
            // Off or empty there is nothing to show beside the list: one centred column instead.
            val wide = maxWidth >= LIST_DETAIL
            val twoPane = wide && enabled && !entries.isNullOrEmpty()
            Row(if (twoPane) Modifier.fillMaxSize() else Modifier.widthIn(max = 600.dp).fillMaxSize()) {
                Column(if (twoPane) Modifier.weight(.45f).widthIn(max = 480.dp).fillMaxHeight() else Modifier.fillMaxSize()) {
                    Row(Modifier.fillMaxWidth().padding(start = 24.dp, end = 12.dp, top = 24.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text("History", Modifier.weight(1f).semantics { heading() }, style = MaterialTheme.typography.headlineMedium)
                        Box {
                            IconButton({ menu = true }) { Icon(painterResource(R.drawable.ic_more_vert), "More options") }
                            DropdownMenu(menu, { menu = false }) {
                                DropdownMenuItem({ Text("History settings") }, { menu = false; settings = true })
                            }
                        }
                    }
                    if (enabled) DockedSearchBar(inputField = {
                        SearchBarDefaults.InputField(query, { query = it }, { }, expanded = false, onExpandedChange = { },
                            placeholder = { Text("Search history") }, leadingIcon = { Icon(painterResource(R.drawable.ic_search), null) },
                            trailingIcon = if (query.isEmpty()) null else ({ IconButton({ query = "" }) { Icon(painterResource(R.drawable.ic_close), "Clear search") } }))
                    }, expanded = false, onExpandedChange = { }, modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) { }
                    when {
                        !enabled -> EmptyHistory(R.drawable.ic_history, "Dictation history is off",
                            "Turn it on to keep recent dictations here, encrypted on this phone only.", "Turn on") { settings = true }
                        entries == null -> Unit
                        shown.isEmpty() && query.isNotBlank() -> EmptyHistory(R.drawable.ic_search, "No matches", "Nothing in your history matches. Try other words.")
                        shown.isEmpty() -> EmptyHistory(R.drawable.ic_history, "No dictations yet", "New dictations stay here for ${history.retention.label}.")
                        else -> LazyColumn(Modifier.fillMaxWidth().weight(1f), contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 88.dp),
                            verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            shown.groupBy { historyDay(now(), it.time, zone) }.forEach { (day, group) ->
                                item(key = day.name) {
                                    Text(day.label, Modifier.padding(start = 8.dp, top = 16.dp, bottom = 8.dp).semantics { heading() },
                                        style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
                                }
                                items(group, key = { "${it.id}/$restores" }) { entry ->
                                    HistoryRow(entry, historyMeta(entry, now()), twoPane && entry.id == open, { choose(entry.id) }, { delete(entry) })
                                }
                            }
                        }
                    }
                }
                if (twoPane) Box(Modifier.weight(.55f).fillMaxHeight().padding(16.dp).clip(MaterialTheme.shapes.extraLarge)
                    .background(MaterialTheme.colorScheme.surfaceContainer)) {
                    if (current != null) Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp)) {
                        HistoryDetail(current, now(), zone, actions)
                    } else Text(if (enabled && shown.isNotEmpty()) "Select a dictation to see it in full." else "", Modifier.align(Alignment.Center).padding(24.dp),
                        style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            SnackbarHost(snackbar, Modifier.align(Alignment.BottomCenter))
            if (!wide && current != null) ModalBottomSheet({ choose(null) }) {
                Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(start = 24.dp, end = 24.dp, bottom = 24.dp)) {
                    HistoryDetail(current, now(), zone, actions)
                }
            }
        }
    }
    if (settings) ModalBottomSheet({ settings = false }) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(start = 16.dp, end = 16.dp, bottom = 24.dp)) {
            HistorySettings(showOpen = false, store = history) { enabled = history.enabled; reload++ }
        }
    }
}

private class DetailActions(val copy: (String, String) -> Unit, val share: (String) -> Unit, val delete: (HistoryEntry) -> Unit)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun HistoryRow(entry: HistoryEntry, meta: String, selected: Boolean, open: () -> Unit, delete: () -> Unit) {
    val dismiss = rememberSwipeToDismissBoxState()
    SwipeToDismissBox(dismiss, backgroundContent = {
        Box(Modifier.fillMaxSize().clip(MaterialTheme.shapes.extraSmall).background(MaterialTheme.colorScheme.errorContainer).padding(horizontal = 24.dp),
            contentAlignment = if (dismiss.dismissDirection == SwipeToDismissBoxValue.StartToEnd) Alignment.CenterStart else Alignment.CenterEnd) {
            Icon(painterResource(R.drawable.ic_delete), null, tint = MaterialTheme.colorScheme.onErrorContainer)
        }
    }, onDismiss = { delete() }) {
        ListItem(headlineContent = { Text(entry.text, maxLines = 2, overflow = TextOverflow.Ellipsis) }, supportingContent = { Text(meta) },
            modifier = Modifier.clip(MaterialTheme.shapes.extraSmall).clickable(onClickLabel = "Open", onClick = open)
                .semantics { customActions = listOf(CustomAccessibilityAction("Delete") { delete(); true }) },
            colors = ListItemDefaults.colors(containerColor = if (selected) MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.surfaceContainer))
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun HistoryDetail(entry: HistoryEntry, now: Long, zone: ZoneId, actions: DetailActions) {
    val time = remember(entry.time, zone) { DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT).withZone(zone).format(Instant.ofEpochMilli(entry.time)) }
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(listOfNotNull(entry.app, time, if (entry.partial) "partial" else null).joinToString(" · "), style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        SelectionContainer { Text(entry.text, style = MaterialTheme.typography.bodyLarge) }
        entry.raw?.let { raw ->
            Text("Before clean-up", Modifier.semantics { heading() }, style = MaterialTheme.typography.titleSmall)
            SelectionContainer { Text(raw, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        }
        Text(historyAge(now, entry.time).second, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            FilledTonalButton({ actions.copy("Chirp dictation", entry.text) }) { ButtonIcon(R.drawable.ic_copy); Text("Copy") }
            entry.raw?.let { raw -> OutlinedButton({ actions.copy("Chirp dictation (raw)", raw) }) { Text("Copy raw") } }
            OutlinedButton({ actions.share(entry.text) }) { ButtonIcon(R.drawable.ic_share); Text("Share") }
            TextButton({ actions.delete(entry) }, colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)) {
                ButtonIcon(R.drawable.ic_delete); Text("Delete")
            }
        }
    }
}

@Composable
private fun ButtonIcon(@DrawableRes icon: Int) {
    Icon(painterResource(icon), null, Modifier.size(18.dp)); Spacer(Modifier.width(8.dp))
}

@Composable
private fun ColumnScope.EmptyHistory(@DrawableRes icon: Int, title: String, body: String, action: String? = null, onAction: () -> Unit = {}) {
    Column(Modifier.fillMaxWidth().weight(1f).padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically)) {
        Icon(painterResource(icon), null, Modifier.size(56.dp), tint = MaterialTheme.colorScheme.primary)
        Column(Modifier.semantics(mergeDescendants = true) { }, horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium)
            Text(body, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = androidx.compose.ui.text.style.TextAlign.Center)
        }
        if (action != null) FilledTonalButton(onAction) { Text(action) }
    }
}
