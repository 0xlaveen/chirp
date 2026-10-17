package dev.chirp.android

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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView

@Composable
internal fun ChirpTheme(dark: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    val colors = if (dark) darkColorScheme(
        primary = Color(0xFF9FD3B9), onPrimary = Color(0xFF12382A),
        primaryContainer = Color(0xFF284E3E), onPrimaryContainer = Color(0xFFBCEFD3),
        secondary = Color(0xFFB5CCBE), onSecondary = Color(0xFF21352A),
        secondaryContainer = Color(0xFF344A3D), onSecondaryContainer = Color(0xFFD0E8D9),
        surface = Color(0xFF121715), onSurface = Color(0xFFE3EBE5),
        surfaceVariant = Color(0xFF34443B), onSurfaceVariant = Color(0xFFB5C8BC),
        surfaceContainer = Color(0xFF202A25), surfaceContainerHigh = Color(0xFF29382F),
        surfaceContainerHighest = Color(0xFF34443B), background = Color(0xFF121715),
        outline = Color(0xFF8B9F91), outlineVariant = Color(0xFF34443B),
    ) else lightColorScheme(
        primary = Color(0xFF386A58), onPrimary = Color.White,
        primaryContainer = Color(0xFFBCEFD3), onPrimaryContainer = Color(0xFF12382A),
        secondary = Color(0xFF52645B), onSecondary = Color.White,
        secondaryContainer = Color(0xFFD5E8DC), onSecondaryContainer = Color(0xFF21352A),
        surface = Color(0xFFF6FAF6), onSurface = Color(0xFF182D25),
        surfaceVariant = Color(0xFFE0EAE2), onSurfaceVariant = Color(0xFF43564A),
        surfaceContainer = Color(0xFFE6EFE8), surfaceContainerHigh = Color(0xFFDDE9DF),
        surfaceContainerHighest = Color(0xFFD5E3D8), background = Color(0xFFF6FAF6),
        outline = Color(0xFF6D8475), outlineVariant = Color(0xFFBFCFC3),
    )
    MaterialTheme(colorScheme = colors, content = content)
}

@Composable
internal fun SetupWizard(
    state: SetupState,
    grantMic: () -> Unit = {}, keyboardSettings: () -> Unit = {}, accessibilitySettings: () -> Unit = {},
    appSettings: () -> Unit = {}, picker: () -> Unit = {}, scan: () -> Unit = {}, check: () -> Unit = {},
    forget: () -> Unit = {}, preferences: () -> Unit = {},
    grantNetwork: () -> Unit = {}, keyboardPreferences: () -> Unit = {}, diagnostics: () -> Unit = {}, copyDiagnostics: () -> Unit = {},
) {
    var showDiagnostics by remember { mutableStateOf(false) }
    var paste by remember { mutableStateOf(false) }
    val pageScroll = rememberScrollState()
    LaunchedEffect(state.step) { pageScroll.scrollTo(0) }
    if (showDiagnostics) AlertDialog(onDismissRequest = { showDiagnostics = false },
        title = { Text("Diagnostics") },
        text = { Column(Modifier.heightIn(max = 420.dp).verticalScroll(rememberScrollState())) {
            Text("Last 5 local crashes. Exception class, stack frames, app version and time only. No messages, text, audio or tokens.")
            SelectionContainer { Text(state.diagnostics, style = MaterialTheme.typography.bodySmall) }
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
                if (state.health?.debugRetention == true) {
                    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.errorContainer)) {
                        Text("DEBUG RETENTION IS ON — the Mac may retain audio and text", Modifier.padding(16.dp), color = MaterialTheme.colorScheme.onErrorContainer)
                    }
                }
                Card(Modifier.fillMaxWidth()) {
                    Text(state.status, Modifier.padding(16.dp).semantics { liveRegion = LiveRegionMode.Polite })
                }
                when (state.step) {
                    0 -> {
                        Text("Enable Chirp Keyboard", style = MaterialTheme.typography.titleLarge)
                        Text("A full keyboard with Chirp’s microphone built in. Type normally, or tap the mic above the keys to dictate.")
                        Text("English autocorrect, next-word and emoji suggestions are ready to use. Personalised suggestions learn typed words on this device; turn them off in Keyboard layouts & settings → Text correction. Dictation finals bypass keyboard learning.")
                        Text("Swipe typing: not available")
                        Text("Samsung: Settings → General management → Keyboard list and default.")
                        Button(keyboardSettings, Modifier.fillMaxWidth()) { Text(if (state.inputEnabled) "Chirp Keyboard enabled ✓" else "Enable Chirp Keyboard") }
                        OutlinedButton(picker, Modifier.fillMaxWidth()) { Text(if (state.inputSelected) "Chirp Keyboard selected ✓" else "Select it as default") }
                        TextButton(keyboardPreferences) { Text("Keyboard layouts & settings") }
                    }
                    1 -> {
                        Text("Allow the microphone", style = MaterialTheme.typography.titleLarge)
                        Text("The mic opens only when you start dictation and is released as soon as you stop. No recordings or transcripts are saved on this phone.")
                        Button(grantMic, Modifier.fillMaxWidth()) { Text(if (state.mic) "Microphone allowed ✓" else "Allow microphone") }
                        TextButton(appSettings) { Text("Open app permissions") }
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
                        }
                        TextButton({ state.step = 2 }) { Text(if (state.paired) "Change pairing" else "Pair Mac") }
                        Text("Try a sentence", style = MaterialTheme.typography.titleLarge)
                        Text("Tap the field below. Type on Chirp Keyboard, then tap its mic to start and ✓ to finish. Long press the mic for quick options. ✕ cancels. The keyboard stays selected after every final.")
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
                        Text("Typing suggestions learn on this device. Swipe typing: not available", style = MaterialTheme.typography.bodySmall)
                        TextButton(picker) { Text("Choose keyboard") }
                        OutlinedButton(check, Modifier.fillMaxWidth(), enabled = !state.checking) { Text("Check Mac connection") }
                        if (state.status.startsWith("Mac unreachable") || state.status.startsWith("Check Tailscale")) {
                            Text("Check Tailscale is connected on both devices. Wake the Mac and start Chirp, then check the connection again.")
                        }
                        Preference("Haptic cues", state.haptics) { state.haptics = it; preferences() }
                        if (state.health.cleanupAvailable()) Preference("Clean-up · ${correctionLabel(state.health)}", state.correction,
                            state.health?.let { it.correctionAvailable && (!it.correctionLeavesMachine || it.correctionHost != null) } == true) {
                            state.correction = it; preferences()
                        }
                        Preference("Debug overlay (timings only)", state.debug) { state.debug = it; preferences() }
                        TextButton(keyboardPreferences) { Text("Keyboard layouts & settings") }
                        BuildSetupOptions()
                        HorizontalDivider()
                        Text("Optional floating microphone", style = MaterialTheme.typography.titleMedium)
                        Text("Off by default. Enable only if you want a floating mic with another keyboard. Chirp reads the focused field locally to insert safely. Keyboard dictation works without Accessibility.")
                        TextButton(accessibilitySettings) { Text(if (state.bubbleEnabled) "Floating mic enabled ✓" else "Enable optional floating mic") }
                        Text("Settings → Accessibility → Installed apps. If sideloading blocks this optional feature: Apps → Chirp Keyboard → ⋮ → Allow restricted settings.")
                        TextButton(forget) { Text("Forget pairing") }
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

@Composable
private fun Preference(label: String, checked: Boolean, enabled: Boolean = true, changed: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
        Switch(checked, changed, enabled = enabled, modifier = Modifier.semantics { contentDescription = label })
    }
}
