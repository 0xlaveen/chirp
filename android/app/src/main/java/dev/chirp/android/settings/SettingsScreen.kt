package dev.chirp.android.settings

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import dev.chirp.android.DictationHistory
import dev.chirp.android.R
import dev.chirp.android.SetupState
import dev.chirp.android.UpdateController

internal enum class SettingsPage(val title: String) {
    Connection("Mac connection"), Look("Look"), SwipeTyping("Swipe typing"), History("Dictation history"),
    FloatingMic("Floating mic"), Updates("Updates"), Diagnostics("Diagnostics"),
}

internal class SettingsActions(
    val checkConnection: () -> Unit = {}, val changePairing: () -> Unit = {}, val forgetPairing: () -> Unit = {},
    val allowWifi: () -> Unit = {}, val floatingMicSettings: () -> Unit = {}, val keyboardPreferences: () -> Unit = {},
)

private val TWO_PANE = 600.dp

/**
 * The one Chirp settings destination: a list of groups with a detail page behind each row. From 600 dp wide the list stays on the left and
 * the detail shows on the right; narrower, rows push a page and back returns to the list. [onExit] runs on back from the list (null: let the system leave).
 */
@Composable
internal fun SettingsScreen(state: SetupState, actions: SettingsActions = SettingsActions(), initialPage: SettingsPage? = null,
                            history: DictationHistory? = null, updates: UpdateController? = null, onExit: (() -> Unit)? = null) {
    var page by rememberSaveable { mutableStateOf(initialPage) }
    Surface(Modifier.fillMaxSize()) {
        BoxWithConstraints(Modifier.fillMaxSize().safeDrawingPadding(), contentAlignment = Alignment.TopCenter) {
            val twoPane = maxWidth >= TWO_PANE
            BackHandler(enabled = onExit != null || (page != null && !twoPane)) { if (page != null && !twoPane) page = null else onExit?.invoke() }
            if (twoPane) Row(Modifier.fillMaxSize()) {
                Column(Modifier.weight(.4f).widthIn(max = 420.dp).fillMaxHeight().verticalScroll(rememberScrollState()).padding(24.dp)) {
                    SettingsHome(state, actions, history, { page = it })
                }
                Column(Modifier.weight(.6f).fillMaxHeight().verticalScroll(rememberScrollState()).padding(24.dp),
                    verticalArrangement = Arrangement.spacedBy(16.dp)) {
                    val shown = page ?: SettingsPage.Connection
                    PageTitle(shown.title, null)
                    SettingsDetail(shown, state, actions, history, updates)
                }
            } else {
                val shown = page
                Column(Modifier.widthIn(max = 600.dp).fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),
                    verticalArrangement = Arrangement.spacedBy(16.dp)) {
                    if (shown == null) SettingsHome(state, actions, history, { page = it })
                    else { PageTitle(shown.title) { page = null }; SettingsDetail(shown, state, actions, history, updates) }
                }
            }
        }
    }
}

@Composable
private fun PageTitle(title: String, back: (() -> Unit)?) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        if (back != null) IconButton(back) { Icon(painterResource(R.drawable.ic_arrow_back), "Back") }
        Text(title, Modifier.semantics { heading() }, style = MaterialTheme.typography.headlineMedium)
    }
}
