package dev.chirp.android.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import dev.chirp.android.*
import dev.chirp.android.R
import dev.chirp.android.ui.*

/**
 * The top level (spec §D): about seven category rows, each with an icon and a live one-line summary of what sits
 * behind it. The details live in the category's page; paragraph help is behind the ⓘ on the rows there.
 */
@Composable
internal fun SettingsList(state: SetupState, actions: SettingsActions, history: DictationHistory?, open: (SettingsPage) -> Unit) {
    val context = LocalContext.current
    val prefs = remember { keyboardPrefs(context) }
    var revision by remember { mutableIntStateOf(0) }
    DisposableEffect(context, prefs) {
        val sources = listOf(prefs, context.getSharedPreferences(SettingsStore.FILE, 0),
            context.getSharedPreferences("chirp_notes_sessions", 0), context.getSharedPreferences("chirp_history", 0))
        val listener = android.content.SharedPreferences.OnSharedPreferenceChangeListener { _, _ -> revision++ }
        sources.forEach { it.registerOnSharedPreferenceChangeListener(listener) }
        onDispose { sources.forEach { it.unregisterOnSharedPreferenceChangeListener(listener) } }
    }
    val dictationHistory = history ?: remember { DictationHistory(context) }
    val connection = connectionSummary(state.paired, state.host, state.reachable, state.checking, state.health)
    Column(verticalArrangement = Arrangement.spacedBy(24.dp)) {
        if (state.health?.debugRetention == true) StatusBanner(StatusKind.Error, "DEBUG RETENTION IS ON — the Mac may retain audio and text")
        // One grouped card, System-Settings style: seven rows with an icon and a live one-line summary each.
        // The list stays composed beside its detail page on a Fold: preference changes must refresh its summaries.
        key(revision) { SettingsGroup {
            NavRow(SettingsPage.Connection.title, { open(SettingsPage.Connection) },
                summary = connection.summary ?: "Pair your Mac to dictate", icon = R.drawable.ic_devices)
            NavRow(SettingsPage.Dictation.title, { open(SettingsPage.Dictation) }, summary = dictationSummary(context, state), icon = R.drawable.ic_tune)
            NavRow(SettingsPage.Keyboard.title, { open(SettingsPage.Keyboard) }, summary = keyboardSummary(context, prefs), icon = R.drawable.ic_keyboard)
            NavRow(SettingsPage.Feedback.title, { open(SettingsPage.Feedback) }, summary = feedbackSummary(context), icon = R.drawable.ic_palette)
            NavRow(SettingsPage.Notes.title, { open(SettingsPage.Notes) }, summary = notesSummary(context), icon = R.drawable.ic_note)
            NavRow(SettingsPage.History.title, { open(SettingsPage.History) },
                summary = if (dictationHistory.enabled) "History on · keeps ${dictationHistory.retention.label}" else "Dictation history off", icon = R.drawable.ic_shield)
            NavRow(SettingsPage.About.title, { open(SettingsPage.About) }, summary = "Chirp ${BuildConfig.VERSION_NAME}", icon = R.drawable.ic_info)
        } }
    }
}

/** "Clean-up on · stops on pause": the two things the Dictation page decides, on one line. */
@Composable
internal fun dictationSummary(context: android.content.Context, state: SetupState): String {
    val store = remember(context) { SettingsStore(context) }
    val cleanup = state.health.cleanupAvailable()
    val stop = if (store.stopOnPause) "stops on pause" else "stops on tap"
    return when {
        !state.paired -> stop
        cleanup && store.correction -> "Clean-up on · $stop"
        cleanup -> "Clean-up off · $stop"
        else -> "No clean-up from this Mac · $stop"
    }
}

/** "Gboard look · swipe on": the keyboard's look and gesture library, on one line. */
@Composable
internal fun keyboardSummary(context: android.content.Context, prefs: android.content.SharedPreferences): String {
    val swipe = remember(context) { GestureLibrary.status(context) == GestureLibrary.Status.ACTIVE }
    val look = currentKeyboardLook(prefs)?.label ?: "Custom"
    return "$look · swipe ${if (swipe) "on" else "off"}"
}

/** "Pond · haptic cues on": the app's colours and its feedback cues. */
@Composable
internal fun feedbackSummary(context: android.content.Context): String {
    val store = remember(context) { SettingsStore(context) }
    val colour = if (store.appColour == AppColour.DYNAMIC) "Match wallpaper" else "Pond"
    return "$colour · haptic cues ${if (store.haptics) "on" else "off"}"
}
