package dev.chirp.android

import android.content.Intent
import android.content.res.ColorStateList
import android.text.InputType
import android.view.View
import android.widget.EditText
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.*
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import kotlinx.coroutines.launch
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import dev.chirp.android.ui.ActionRow
import dev.chirp.android.ui.AppColoursSettings
import dev.chirp.android.ui.NavRow
import dev.chirp.android.ui.SettingsGroup
import dev.chirp.android.ui.SettingsItem
import dev.chirp.android.ui.StatusBanner
import dev.chirp.android.ui.StatusKind
import dev.chirp.android.ui.SwitchRow

/** Moved to [dev.chirp.android.ui.ChirpTheme]; this name stays so existing callers compile unchanged. */
@Composable
internal fun ChirpTheme(dark: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) =
    dev.chirp.android.ui.ChirpTheme(dark, content = content)

@Composable
internal fun SetupWizard(
    state: SetupState,
    grantMic: () -> Unit = {}, keyboardSettings: () -> Unit = {}, accessibilitySettings: () -> Unit = {},
    appSettings: () -> Unit = {}, picker: () -> Unit = {}, scan: () -> Unit = {}, check: () -> Unit = {},
    forget: () -> Unit = {}, preferences: () -> Unit = {},
    correctionChanged: (Boolean) -> Unit = {},
    grantNetwork: () -> Unit = {}, keyboardPreferences: () -> Unit = {}, diagnostics: () -> Unit = {}, copyDiagnostics: () -> Unit = {},
    clearTimings: () -> Unit = {},
) {
    var showDiagnostics by remember { mutableStateOf(false) }
    var paste by remember { mutableStateOf(false) }
    val pageScroll = rememberScrollState()
    LaunchedEffect(state.step) { pageScroll.scrollTo(0) }
    if (showDiagnostics) AlertDialog(onDismissRequest = { showDiagnostics = false },
        title = { Text("Diagnostics") },
        text = { Column(Modifier.heightIn(max = 420.dp).verticalScroll(rememberScrollState())) {
            Text("Timings of the last 50 sessions (numbers only) and the last 5 local crashes (exception class, stack frames, app version and time). No messages, text, audio, hosts or tokens.")
            SelectionContainer { Text(state.diagnostics, style = MaterialTheme.typography.bodySmall) }
            TextButton(clearTimings) { Text("Clear timings") }
        } },
        confirmButton = { TextButton(copyDiagnostics) { Text("Copy diagnostics") } },
        dismissButton = { TextButton({ showDiagnostics = false }) { Text("Close") } })
    Surface(Modifier.fillMaxSize()) {
        Box(Modifier.fillMaxSize().safeDrawingPadding(), contentAlignment = Alignment.TopCenter) {
            Column(Modifier.widthIn(max = 600.dp).fillMaxWidth().verticalScroll(pageScroll).padding(24.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Text(if (state.step == 3) "CHIRP  /  SETTINGS" else "CHIRP  /  SETUP", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
                Text(if (state.step == 3) "Ready to dictate" else "Your voice. Your keyboard.", style = MaterialTheme.typography.headlineMedium)
                Text("Speak on your phone. Your Mac transcribes over Tailscale.", style = MaterialTheme.typography.bodyLarge)
                LinearProgressIndicator(progress = { (state.step + 1) / 4f }, modifier = Modifier.fillMaxWidth().semantics { contentDescription = "Setup progress" })
                Text("Step ${state.step + 1} of 4 · ${listOf("Chirp Keyboard", "Microphone", "Pair Mac", "Try it")[state.step]}", style = MaterialTheme.typography.labelLarge)
                if (state.health?.debugRetention == true) StatusBanner(StatusKind.Error, "DEBUG RETENTION IS ON — the Mac may retain audio and text")
                StatusBanner(StatusKind.Info, state.status, live = true)
                when (state.step) {
                    0 -> {
                        Text("Enable Chirp Keyboard", style = MaterialTheme.typography.titleLarge)
                        Text("A full keyboard with Chirp’s microphone built in. Type normally, or tap the mic above the keys to dictate.")
                        Text("English autocorrect, next-word and emoji suggestions are ready to use. Personalised suggestions learn typed words on this device; turn them off in Keyboard layouts & settings → Text correction. Dictation finals bypass keyboard learning.")
                        Text(swipeTypingSummary(androidx.compose.ui.platform.LocalContext.current))
                        Text("Samsung: Settings → General management → Keyboard list and default.")
                        Button(keyboardSettings, Modifier.fillMaxWidth()) { Text(if (state.inputEnabled) "Chirp Keyboard enabled ✓" else "Enable Chirp Keyboard") }
                        OutlinedButton(picker, Modifier.fillMaxWidth()) { Text(if (state.inputSelected) "Chirp Keyboard selected ✓" else "Select it as default") }
                        SettingsGroup { NavRow("Keyboard layouts & settings", keyboardPreferences) }
                    }
                    1 -> {
                        Text("Allow the microphone", style = MaterialTheme.typography.titleLarge)
                        Text("The mic opens only when you start dictation and is released as soon as you stop. No recordings are saved on this phone; transcripts are kept only if you turn on dictation history.")
                        Button(grantMic, Modifier.fillMaxWidth()) { Text(if (state.mic) "Microphone allowed ✓" else "Allow microphone") }
                        SettingsGroup { NavRow("Open app permissions", appSettings) }
                    }
                    2 -> {
                        Text("Connect your Mac", style = MaterialTheme.typography.titleLarge)
                        if (state.wifiPermissionNeeded && !state.localNetwork) {
                            Text("Needed only for servers on your Wi-Fi. Tailscale works without local network permission.")
                            OutlinedButton(grantNetwork, Modifier.fillMaxWidth()) { Text("Allow Wi-Fi server access") }
                        }
                        Text("Turn on Tailscale on both devices. On the Mac, open Chirp’s pairing QR code. Scan it or paste the pairing link below.")
                        Button(scan, Modifier.fillMaxWidth(), enabled = !state.scanning) { Text(if (state.scanning) "Scanning…" else "Scan pairing QR") }
                        TextButton({ paste = !paste }) { Text(if (paste) "Hide pairing link" else "Paste pairing link instead") }
                        if (paste || state.link.isNotEmpty()) OutlinedTextField(state.link, { state.link = it }, Modifier.fillMaxWidth().semantics { contentDescription = "Private Chirp pairing link" },
                            label = { Text("Pairing link") }, singleLine = true,
                            visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
                        Text("QR scanning uses Google Play services. Paste works without the scanner. Pairing tokens are encrypted with Android Keystore.", style = MaterialTheme.typography.bodySmall)
                        Button(check, Modifier.fillMaxWidth(), enabled = !state.checking) { Text("Test connection & save pairing") }
                    }
                    3 -> {
                        if (state.paired) {
                            Text("Paired with ${state.host}", style = MaterialTheme.typography.titleMedium)
                            Text("Engine: ${state.health?.engine ?: "Not reported by Mac"}")
                            if (state.health.cleanupAvailable()) SettingsGroup {
                                SwitchRow("Clean-up · ${correctionLabel(state.health)}", state.correction, {
                                    state.correction = it; correctionChanged(it)
                                }, summary = cleanupDescription(state.health))
                                CleanupStyleSettings(state.health)
                            } else Text("Mac has clean-up off", style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        SettingsGroup { NavRow(if (state.paired) "Change pairing" else "Pair Mac", { state.step = 2 }) }
                        Text("Try a sentence", style = MaterialTheme.typography.titleLarge)
                        Text("Tap the field below. Type on Chirp Keyboard, then tap its mic to start and ✓ to finish (or pause, if you chose When I pause). Long press the mic for quick options. ✕ cancels. The keyboard stays selected after every final.")
                        StopDictationSettings()
                        // Deliberately a real native editor: exercises the same InputConnection/accessibility path as other apps.
                        val editorInk = MaterialTheme.colorScheme.onSurface.toArgb()
                        val editorHint = MaterialTheme.colorScheme.onSurfaceVariant.toArgb()
                        val editorAccent = MaterialTheme.colorScheme.primary.toArgb()
                        val bringEditor = remember { BringIntoViewRequester() }
                        val editorScope = rememberCoroutineScope()
                        AndroidView(factory = { context -> EditText(context).apply {
                            hint = "Test dictation here"; minLines = 3
                            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_AUTO_CORRECT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
                            onFocusChangeListener = View.OnFocusChangeListener { _, focused ->
                                if (focused) postDelayed({ editorScope.launch { bringEditor.bringIntoView() } }, 350)
                            }
                            isSaveEnabled = false; importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS
                        } }, update = { editor ->
                            editor.setTextColor(editorInk); editor.setHintTextColor(editorHint)
                            editor.backgroundTintList = ColorStateList.valueOf(editorAccent)
                        }, modifier = Modifier.fillMaxWidth().bringIntoViewRequester(bringEditor))
                        Text("Typing suggestions learn on this device.", style = MaterialTheme.typography.bodySmall)
                        AppColoursSettings()
                        KeyboardLookChooser()
                        SwipeTypingSettings()
                        val context = LocalContext.current
                        SettingsGroup {
                            NavRow("Choose keyboard", picker)
                            NavRow("Open Scratchpad", { context.startActivity(Intent(context, ScratchpadActivity::class.java)) })
                            NavRow("Open Notes", { context.startActivity(Intent(context, NotesActivity::class.java)) })
                        }
                        OutlinedButton(check, Modifier.fillMaxWidth(), enabled = !state.checking) { Text("Check Mac connection") }
                        if (state.status.startsWith("Mac unreachable") || state.status.startsWith("Check Tailscale")) {
                            Text("Check Tailscale is connected on both devices. Wake the Mac and start Chirp, then check the connection again.")
                        }
                        SettingsGroup {
                            SwitchRow("Haptic cues", state.haptics, { state.haptics = it; preferences() })
                            SwitchRow("Debug overlay (timings only)", state.debug, { state.debug = it; preferences() })
                        }
                        HistorySettings()
                        UpdateSettings()
                        SettingsGroup {
                            NavRow("Keyboard layouts & settings", keyboardPreferences)
                            BuildSetupOptions()
                        }
                        SettingsGroup("Optional floating microphone") {
                            SettingsItem { Text("Off by default. Enable only if you want a floating mic with another keyboard. Chirp reads the focused field locally to insert safely. Keyboard dictation works without Accessibility.") }
                            NavRow(if (state.bubbleEnabled) "Floating mic enabled ✓" else "Enable optional floating mic", accessibilitySettings,
                                summary = "Settings → Accessibility → Installed apps. If sideloading blocks this optional feature: Apps → Chirp Keyboard → ⋮ → Allow restricted settings.")
                        }
                        SettingsGroup { ActionRow("Forget pairing", forget, destructive = true) }
                    }
                }
                TextButton({ diagnostics(); showDiagnostics = true }) { Text("Diagnostics") }
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    TextButton({ state.step-- }, enabled = state.step > 0) { Text("Back") }
                    if (state.step < 3) Button({ state.step++ }, enabled = when (state.step) {
                        0 -> state.inputEnabled && state.inputSelected
                        1 -> state.mic
                        else -> true
                    }) { Text(if (state.step == 2) "Try keyboard" else "Next") }
                    else Text("Ready when you are", Modifier.padding(12.dp), style = MaterialTheme.typography.labelLarge)
                }
            }
        }
    }
}
