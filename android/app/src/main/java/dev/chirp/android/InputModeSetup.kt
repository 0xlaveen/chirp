package dev.chirp.android

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.provider.Settings
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp
import dev.chirp.android.ui.*

internal fun accessibilitySettingsIntent(context: Context): Intent {
    // AOSP exposes the action as a system constant, so use its stable intent string.
    val details = Intent("android.settings.ACCESSIBILITY_DETAILS_SETTINGS")
        .putExtra(Intent.EXTRA_COMPONENT_NAME, ComponentName(context, ChirpAccessibilityService::class.java))
    return if (details.resolveActivity(context.packageManager) != null) details else Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
}

internal fun openAccessibilitySettings(context: Context) {
    try {
        context.startActivity(accessibilitySettingsIntent(context))
    } catch (_: SecurityException) {
        // Some system images resolve the service-details action but restrict its caller.
        context.startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
    } catch (_: android.content.ActivityNotFoundException) {
        context.startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
    }
}

/** A single selectable radio node per card, including its explanation and selected state. */
@Composable
internal fun InputModeCards(state: SetupState, choose: (InputMode) -> Unit) {
    Column(Modifier.selectableGroup(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        ModeCard("Use Chirp Keyboard", "Replaces your keyboard. Type as usual and tap the mic above the keys — your words appear as you speak.",
            "Works in almost every app", state.inputMode == InputMode.KEYBOARD) { choose(InputMode.KEYBOARD) }
        ModeCard(state.keyboardLabel?.let { "Keep $it" } ?: "Keep my keyboard",
            "Keep typing on your keyboard. A small Chirp mic appears beside text fields when you need it.",
            "Needs an Accessibility permission", state.inputMode == InputMode.OWN_KEYBOARD) { choose(InputMode.OWN_KEYBOARD) }
        Text("Notes and Scratchpad work either way. You can change this later in Settings.",
            style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun ModeCard(title: String, body: String, meta: String, selected: Boolean, choose: () -> Unit) {
    Surface(Modifier.fillMaxWidth().selectable(selected, role = Role.RadioButton, onClick = choose).clearAndSetSemantics {
        role = Role.RadioButton
        this.selected = selected
        this[SemanticsProperties.Text] = listOf(AnnotatedString(title), AnnotatedString(body), AnnotatedString(meta))
        onClick { choose(); true }
    },
        shape = MaterialTheme.shapes.large,
        color = if (selected) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surfaceContainer) {
        Row(Modifier.padding(16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            RadioButton(selected, onClick = null)
            Column(verticalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.weight(1f)) {
                Text(title, style = MaterialTheme.typography.titleMedium)
                Text(body, style = MaterialTheme.typography.bodyMedium)
                Text(meta, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Composable
internal fun FloatingMicGuide(state: SetupState, accessibility: () -> Unit, appInfo: () -> Unit, useKeyboard: () -> Unit) {
    if (state.advancedProtection) {
        StatusBanner(StatusKind.Warning, "Advanced Protection is on",
            body = "Android only allows verified accessibility tools, so the floating mic can’t be turned on.")
        OutlinedButton(useKeyboard, Modifier.fillMaxWidth().heightIn(min = 56.dp)) { Text("Use Chirp Keyboard instead") }
        return
    }
    Text("Android calls this an Accessibility permission. Chirp uses it only to show a mic next to the field you’re typing in and to put your words there.",
        style = MaterialTheme.typography.bodyLarge)
    SettingsGroup("What Chirp can see") {
        SettingsItem { Text("The text field you’re typing in — on this phone only") }
        SettingsItem { Text("Never passwords, the rest of the screen or other apps’ content") }
        SettingsItem { Text("Only your voice is sent, to your own computer") }
    }
    Text("No battery use while idle — the mic, network and timers start only when you tap it.",
        style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    SettingsGroup { CheckRow("Floating mic on", state.bubbleEnabled) }
    if (!state.bubbleEnabled) {
        Text("Turn on Chirp floating mic, then tap Allow.", style = MaterialTheme.typography.bodyMedium)
        if (state.accessibilityReturns > 0) RestrictedSettingsHelp(state.accessibilityReturns, appInfo, accessibility)
    }
}

@Composable
private fun RestrictedSettingsHelp(returns: Int, appInfo: () -> Unit, accessibility: () -> Unit) {
    var expanded by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(returns) { if (returns >= 2) expanded = true }
    SettingsGroup {
        ActionRow("Did Android say “Restricted setting”?", { expanded = !expanded }, summary = if (expanded) "Hide help" else "Show help")
        if (expanded) {
            SettingsItem { Text("1. Open Chirp app info.\n2. Tap ⋮ (top right), then Allow restricted settings, and confirm with your screen lock.\n3. Come back and open Accessibility settings again.") }
            ActionRow("Open Chirp app info", appInfo)
            ActionRow("Open Accessibility settings again", accessibility)
            SettingsItem {
                Text("The ⋮ option appears only after Android has blocked the setting once. Menus differ between phones.", style = MaterialTheme.typography.bodySmall)
                Text("If your organisation manages this phone, it may block this.", style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}

@Composable
internal fun HowYouDictate(state: SetupState, choose: (InputMode) -> Unit, accessibility: () -> Unit, appInfo: () -> Unit,
                           picker: () -> Unit, keyboardSettings: () -> Unit) {
    InputModeCards(state, choose)
    when (state.inputMode) {
        InputMode.KEYBOARD -> SettingsGroup("Chirp Keyboard") {
            CheckRow("Enabled", state.inputEnabled)
            CheckRow("Selected", state.inputSelected)
            if (!state.inputEnabled) ActionRow("Enable Chirp Keyboard", keyboardSettings)
            ActionRow("Choose keyboard", picker)
        }
        InputMode.OWN_KEYBOARD -> {
            if (state.inputSelected) SettingsGroup { ActionRow("Switch back to your keyboard", picker) }
            FloatingMicGuide(state, accessibility, appInfo, useKeyboard = { choose(InputMode.KEYBOARD) })
            if (state.advancedProtection && !state.bubbleEnabled) Text("Turned off by Advanced Protection", style = MaterialTheme.typography.bodyMedium)
            if (!state.advancedProtection && !state.bubbleEnabled) Button(accessibility, Modifier.fillMaxWidth().heightIn(min = 56.dp)) { Text("Open Accessibility settings") }
            // #167: the clipboard is the floating mic's fallback, never automatic.
            if (state.bubbleEnabled) Text("If a field can’t take your words, they wait in the floating mic’s panel until you tap Copy. " +
                "Chirp never copies on its own and marks copies as sensitive, but Samsung’s clipboard history may still keep them.",
                Modifier.padding(horizontal = 16.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        null -> Unit
    }
    SettingsGroup("Other ways to dictate") {
        Text("Notes and Scratchpad work with any keyboard.", Modifier.padding(16.dp), style = MaterialTheme.typography.bodyMedium)
        OtherDictationEntries()
    }
}
