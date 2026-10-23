package dev.chirp.android.settings

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import dev.chirp.android.*
import dev.chirp.android.ui.*

@Composable
internal fun SettingsDetail(page: SettingsPage, state: SetupState, actions: SettingsActions, history: DictationHistory?, updates: UpdateController?) {
    when (page) {
        SettingsPage.Connection -> ConnectionPage(state, actions)
        SettingsPage.Look -> { KeyboardLookChooser(); AppColoursSettings() }
        SettingsPage.SwipeTyping -> SwipeTypingSettings()
        SettingsPage.History -> HistorySettings(store = history)
        SettingsPage.Notes -> NotesSettings()
        SettingsPage.FloatingMic -> FloatingMicPage(state, actions)
        SettingsPage.Updates -> UpdateSettings(updates)
        SettingsPage.Diagnostics -> DiagnosticsPage()
    }
}

@Composable
private fun ConnectionPage(state: SetupState, actions: SettingsActions) {
    var confirmForget by remember { mutableStateOf(false) }
    val connection = connectionSummary(state.paired, state.host, state.reachable, state.checking, state.health)
    StatusBanner(connection.kind, connection.title, body = connection.hint ?: connection.summary, live = true)
    SettingsGroup {
        if (state.paired) ActionRow("Check connection", actions.checkConnection, enabled = !state.checking)
        if (state.wifiPermissionNeeded && !state.localNetwork) ActionRow("Allow Wi-Fi server access", actions.allowWifi,
            summary = "Needed only for servers on your Wi-Fi. Tailscale works without it.")
        NavRow(if (state.paired) "Change pairing" else "Pair Mac", actions.changePairing)
    }
    if (state.paired) SettingsGroup { ActionRow("Forget pairing", { confirmForget = true }, destructive = true) }
    PhoneFallbackSettings()
    if (confirmForget) AlertDialog(onDismissRequest = { confirmForget = false },
        title = { Text("Forget ${state.host}?") },
        text = { Text("You'll need the QR code to pair again.") },
        confirmButton = { TextButton({ confirmForget = false; actions.forgetPairing() },
            colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)) { Text("Forget") } },
        dismissButton = { TextButton({ confirmForget = false }) { Text("Keep pairing") } })
}

@Composable
private fun FloatingMicPage(state: SetupState, actions: SettingsActions) {
    SettingsGroup {
        SettingsItem {
            Text("Off by default. A floating mic you can use with another keyboard. Keyboard dictation works without it.", style = MaterialTheme.typography.bodyMedium)
            LearnMore("Optional floating microphone", "Chirp reads the focused field locally to insert text safely. Nothing is sent anywhere except the audio you dictate.\n\n" +
                "Turn it on in Settings → Accessibility → Installed apps → Chirp Keyboard. If sideloading blocks this optional feature: " +
                "Apps → Chirp Keyboard → ⋮ → Allow restricted settings.")
        }
        NavRow(if (state.bubbleEnabled) "Floating mic is on" else "Turn on floating mic", actions.floatingMicSettings,
            summary = if (state.bubbleEnabled) "Open Accessibility settings to turn it off" else "Opens Accessibility settings")
    }
}

@Composable
private fun DiagnosticsPage() {
    val context = LocalContext.current
    val store = remember { SettingsStore(context) }
    var debug by remember { mutableStateOf(store.debugOverlay) }
    var report by remember { mutableStateOf(DiagnosticsReport.text(context)) }
    SettingsGroup {
        SwitchRow("Debug overlay (timings only)", debug, { debug = it; store.debugOverlay = it })
        BuildSetupOptions()
    }
    SettingsGroup {
        SettingsItem { DiagnosticsBody(report) }
        ActionRow("Copy diagnostics", { copyDiagnostics(context, report) })
        ActionRow("Clear timings", { DiagnosticsReport.clearTimings(context); report = DiagnosticsReport.text(context) })
    }
}

/** Shared by this page and setup's Diagnostics dialog. */
@Composable
internal fun DiagnosticsBody(report: String) {
    Text("Timings of the last 50 sessions (numbers only) and the last 5 local crashes (exception class, stack frames, app version and time). No messages, text, audio, hosts or tokens.")
    SelectionContainer { Text(report, style = MaterialTheme.typography.bodySmall) }
}

internal fun copyDiagnostics(context: Context, report: String) {
    context.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("Chirp diagnostics", report))
}
