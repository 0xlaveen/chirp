package dev.chirp.android.shell

import androidx.annotation.DrawableRes
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import dev.chirp.android.DictationHistory
import dev.chirp.android.HistoryEntry
import dev.chirp.android.R
import dev.chirp.android.SettingsStore
import dev.chirp.android.SetupState
import dev.chirp.android.TryItCard
import dev.chirp.android.ui.StatusBanner
import dev.chirp.android.ui.StatusKind
import java.time.Instant
import java.time.ZoneId
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

internal class HomeActions(
    val fix: (HomeFix) -> Unit = {}, val dictate: () -> Unit = {}, val notes: () -> Unit = {},
    /** Opens the History tab, on one entry when given. */ val history: (String?) -> Unit = {}, val historySettings: () -> Unit = {},
)

private const val RECENT = 3
private val TWO_COLUMNS = 600.dp

internal fun greeting(now: Long, zone: ZoneId = ZoneId.systemDefault()) = when (Instant.ofEpochMilli(now).atZone(zone).hour) {
    in 5..11 -> "Good morning"
    in 12..17 -> "Good afternoon"
    else -> "Good evening"
}

/**
 * Home: the Mac connection with its one fix, the Dictate (Scratchpad) and Notes tiles, recent dictations when history is on (an opt-in
 * line when it isn't) and, until dismissed, the first-run "Try it" card. Two columns from 600 dp, with Recent on the right.
 */
@Composable
internal fun HomeScreen(state: SetupState, actions: HomeActions = HomeActions(), history: DictationHistory? = null, notesLive: Boolean = false,
                        now: () -> Long = System::currentTimeMillis, zone: ZoneId = ZoneId.systemDefault()) {
    val context = LocalContext.current
    val store = remember { SettingsStore(context) }
    val dictations = history ?: remember { DictationHistory(context) }
    var enabled by remember { mutableStateOf(dictations.enabled) }
    var recent by remember { mutableStateOf<List<HistoryEntry>?>(null) }
    var reload by remember { mutableIntStateOf(0) }
    LaunchedEffect(reload, enabled) { recent = withContext(Dispatchers.IO) { dictations.entries().take(RECENT) } }
    LifecycleResumeEffect(dictations) { enabled = dictations.enabled; reload++; onPauseOrDispose { } }
    val status = homeStatus(state.paired, state.host, state.mic, state.tailscaleOff, state.checking, state.reachable, state.failure, state.health)
    Surface(Modifier.fillMaxSize()) {
        BoxWithConstraints(Modifier.fillMaxSize().safeDrawingPadding(), contentAlignment = Alignment.TopCenter) {
            val main: @Composable ColumnScope.() -> Unit = {
                Text(greeting(now(), zone), Modifier.semantics { heading() }, style = MaterialTheme.typography.headlineMedium)
                StatusBanner(status.kind, status.title, body = status.body, action = status.fix?.label, onAction = { status.fix?.let(actions.fix) }, live = true)
                Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    EntryTile("Dictate", "Scratchpad", R.drawable.ic_mic, MaterialTheme.colorScheme.primaryContainer, MaterialTheme.colorScheme.onPrimaryContainer,
                        actions.dictate, Modifier.weight(1f))
                    EntryTile("Notes", if (notesLive) "Recording" else "Live Notes", if (notesLive) R.drawable.ic_record else R.drawable.ic_notes_tab,
                        MaterialTheme.colorScheme.secondaryContainer, MaterialTheme.colorScheme.onSecondaryContainer, actions.notes, Modifier.weight(1f))
                }
                if (state.tryIt) TryItCard(store) { state.tryIt = false }
            }
            val side: @Composable ColumnScope.() -> Unit = { Recent(enabled, recent, now(), actions) }
            if (maxWidth >= TWO_COLUMNS) Row(Modifier.fillMaxSize().padding(horizontal = 24.dp), horizontalArrangement = Arrangement.spacedBy(24.dp)) {
                Column(Modifier.weight(1f).fillMaxHeight().verticalScroll(rememberScrollState()).padding(vertical = 24.dp),
                    verticalArrangement = Arrangement.spacedBy(16.dp), content = main)
                Column(Modifier.weight(.8f).fillMaxHeight().verticalScroll(rememberScrollState()).padding(vertical = 24.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp), content = side)
            } else Column(Modifier.widthIn(max = 600.dp).fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp)) {
                main()
                Column(verticalArrangement = Arrangement.spacedBy(8.dp), content = side)
            }
        }
    }
}

/** A big entry point. Clickable surfaces merge their children, so TalkBack reads one label: "Dictate, Scratchpad". */
@Composable
private fun EntryTile(title: String, subtitle: String, @DrawableRes icon: Int, container: Color, content: Color, onClick: () -> Unit, modifier: Modifier) {
    Surface(onClick, modifier.fillMaxHeight().heightIn(min = 128.dp), shape = MaterialTheme.shapes.extraLarge, color = container, contentColor = content) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Icon(painterResource(icon), null, Modifier.size(32.dp))
            Spacer(Modifier.weight(1f).heightIn(min = 16.dp))
            Text(title, style = MaterialTheme.typography.titleLarge)
            Text(subtitle, style = MaterialTheme.typography.bodyMedium)
        }
    }
}

@Composable
private fun ColumnScope.Recent(enabled: Boolean, recent: List<HistoryEntry>?, now: Long, actions: HomeActions) {
    val context = LocalContext.current
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text("Recent", Modifier.weight(1f).semantics { heading() }, style = MaterialTheme.typography.titleMedium)
        if (enabled && !recent.isNullOrEmpty()) TextButton({ actions.history(null) }) {
            Text("All"); Icon(painterResource(R.drawable.ic_chevron_right), null, Modifier.size(18.dp))
        }
    }
    when {
        !enabled -> Surface(Modifier.fillMaxWidth(), shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.surfaceContainer) {
            Row(Modifier.padding(start = 16.dp, end = 8.dp, top = 8.dp, bottom = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("Keep recent dictations here, encrypted on this phone", Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                TextButton(actions.historySettings) { Text("Turn on") }
            }
        }
        recent == null -> Unit
        recent.isEmpty() -> Text("No dictations yet. They show up here after you dictate.", style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        else -> Column(Modifier.fillMaxWidth().clip(MaterialTheme.shapes.large), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            recent.forEach { entry ->
                ListItem(headlineContent = { Text(entry.text, maxLines = 2, overflow = TextOverflow.Ellipsis) },
                    supportingContent = { Text(historyMeta(entry, now)) },
                    trailingContent = { IconButton({ copyPrivately(context, "Chirp dictation", entry.text) }) { Icon(painterResource(R.drawable.ic_copy), "Copy") } },
                    modifier = Modifier.clickable(onClickLabel = "Open") { actions.history(entry.id) },
                    colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.surfaceContainer))
            }
        }
    }
}
