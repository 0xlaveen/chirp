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
        SettingsPage.HowYouDictate -> HowYouDictate(state, actions.chooseMode, actions.floatingMicSettings, actions.appSettings, actions.picker, actions.keyboardSettings)
        SettingsPage.Dictation -> DictationPage(state, actions)
        SettingsPage.Keyboard -> KeyboardPage(actions)
        SettingsPage.Feedback -> FeedbackPage()
        SettingsPage.Notes -> NotesSettings()
        SettingsPage.History -> HistoryPage(history)
        SettingsPage.About -> AboutPage(updates)
    }
}

@Composable
private fun ConnectionPage(state: SetupState, actions: SettingsActions) {
    var confirmForget by remember { mutableStateOf(false) }
    val connection = connectionSummary(state.paired, state.host, state.reachable, state.checking, state.health)
    // Unreachable: the hint says to check Tailscale, so the banner opens it when it is installed.
    val tailscale = actions.openTailscale.takeIf { state.paired && state.reachable == false && !state.checking }
    StatusBanner(connection.kind, connection.title, body = connection.hint ?: connection.summary, live = true,
        action = tailscale?.let { "Open Tailscale" }, onAction = { tailscale?.invoke() })
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

/** Clean-up and styles, stop behaviour, spoken commands, auto-enter, and the other ways to dictate. */
@Composable
private fun DictationPage(state: SetupState, actions: SettingsActions) {
    val context = LocalContext.current
    val store = remember { SettingsStore(context) }
    var cleanup by remember { mutableStateOf(store.correction) }
    var commands by remember { mutableStateOf(store.spokenCommands) }
    if (state.health.cleanupAvailable()) {
        SettingsGroup("Clean-up") {
            SwitchRow("Clean-up · ${correctionLabel(state.health)}", cleanup, { cleanup = it; store.correction = it },
                summary = "Polishes punctuation and filler words ${if (state.health?.correctionLeavesMachine == true) "on ${state.health?.correctionHost}" else "on your Mac"}",
                infoTitle = "Clean-up", infoBody = cleanupDescription(state.health))
            CleanupStyleSettings(state.health)
        }
    } else if (state.paired) SettingsGroup("Clean-up") { SettingsItem { Text("Mac has clean-up off", style = MaterialTheme.typography.bodyMedium) } }
    SettingsGroup("Stopping") { StopDictationSettings() }
    SettingsGroup("Spoken commands") {
        SwitchRow("Spoken commands", commands, { commands = it; store.spokenCommands = it }, summary = "Off by default",
            infoTitle = "Spoken commands", infoBody = "Ending a dictation with \"new line\" or \"new paragraph\" types a line break instead of the words.")
    }
    SettingsGroup("Press Send") { SettingsItem { AutoEnterSettings() } }
    LearningSettings()
    HistorySettings()

}

@Composable
private fun KeyboardPage(actions: SettingsActions) {
    val context = LocalContext.current
    val store = remember { SettingsStore(context) }
    val prefs = remember { keyboardPrefs(context) }
    var shortcut by remember { mutableStateOf(store.hardwareShortcut) }
    var largerMic by remember { mutableStateOf(store.largerMic) }
    KeyboardLookChooser()
    SwipeTypingSettings()
    SettingsGroup("Keys and shortcuts") {
        SwitchRow("Hardware keyboard shortcut", shortcut, { shortcut = it; store.hardwareShortcut = it }, summary = "Ctrl+Alt+Space · Works with Chirp Keyboard",
            infoTitle = "Hardware keyboard shortcut", infoBody = "Ctrl+Alt+Space starts and stops dictation; Esc cancels while listening.")
        SwitchRow("Larger mic on the inner screen", largerMic, { largerMic = it; store.largerMic = it })
        NavRow("Layouts, languages & typing", actions.keyboardPreferences, summary = "Opens the keyboard's own settings")
    }
}

@Composable
private fun FeedbackPage() {
    val context = LocalContext.current
    val store = remember { SettingsStore(context) }
    var haptics by remember { mutableStateOf(store.haptics) }
    var soundCues by remember { mutableStateOf(store.soundCues) }
    AppColoursSettings()
    SettingsGroup("Cues") {
        SwitchRow("Haptic cues", haptics, { haptics = it; store.haptics = it })
        SwitchRow("Sound cues", soundCues, { soundCues = it; store.soundCues = it }, summary = "Short tones for start, stop, inserted and error",
            infoTitle = "Sound cues", infoBody = "Short tones for start, stop, inserted and error. Silent when the phone is on vibrate or mute.")
    }
}

/** History retention and clear, separate from Notes retention (spec §D). */
@Composable
private fun HistoryPage(history: DictationHistory?) {
    val context = LocalContext.current
    val store = remember { SettingsStore(context) }
    val privateSession by PrivateSession.state.collectAsState()
    SettingsGroup {
        SwitchRow("Private session", privateSession, { store.privateSession = it }, summary = "Exclude history",
            infoTitle = "Private session", infoBody = PrivateSession.HELP)
    }
    HistorySettings(showOpen = true, store = history, title = null)   // the page already says "Privacy & history"
    SettingsGroup("What Chirp keeps") {
        SettingsItem {
            Text("Dictations, notes and kept audio never leave this phone.", style = MaterialTheme.typography.bodyMedium)
            LearnMore("Local only", "Dictation history is on by default and encrypted on this phone. Turn it off in Privacy & history. Notes are sealed with the phone's keystore and never " +
                "backed up or synced. Kept audio stays next to its note. Diagnostics carry numbers only — no text, audio, hosts or tokens.")
        }
    }
}

@Composable
private fun AboutPage(updates: UpdateController?) {
    val context = LocalContext.current
    val store = remember { SettingsStore(context) }
    var report by remember { mutableStateOf(DiagnosticsReport.text(context)) }
    var debug by remember { mutableStateOf(store.debugOverlay) }
    UpdateSettings(updates)
    SettingsGroup("Diagnostics") {
        SettingsItem { DiagnosticsBody(report) }
        SwitchRow("Debug overlay (timings only)", debug, { debug = it; store.debugOverlay = it })
        BuildSetupOptions()
        ActionRow("Copy diagnostics", { copyDiagnostics(context, report) })
        ActionRow("Clear timings", { DiagnosticsReport.clearTimings(context); report = DiagnosticsReport.text(context) })
    }
}

/** Shared by this page and setup's Diagnostics dialog. */
@Composable
internal fun DiagnosticsBody(report: String) {
    Text("Timings of the last 50 sessions and Notes session counts (numbers only), and the last 5 local crashes (exception class, stack frames, app version and time). No messages, text, audio, hosts or tokens.")
    SelectionContainer { Text(report, style = MaterialTheme.typography.bodySmall) }
}

internal fun copyDiagnostics(context: Context, report: String) {
    context.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("Chirp diagnostics", report))
}
