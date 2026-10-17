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
) {
    Surface(Modifier.fillMaxSize()) {
        Box(Modifier.fillMaxSize().safeDrawingPadding(), contentAlignment = Alignment.TopCenter) {
            Column(Modifier.widthIn(max = 600.dp).fillMaxWidth().verticalScroll(rememberScrollState()).padding(24.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Text("CHIRP  /  SETUP", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
                Text("Your voice.\nYour keyboard.", style = MaterialTheme.typography.headlineLarge)
                Text("Speak on your phone. Your Mac transcribes over Tailscale.", style = MaterialTheme.typography.bodyLarge)
                LinearProgressIndicator(progress = { (state.step + 1) / 4f }, modifier = Modifier.fillMaxWidth().semantics { contentDescription = "Setup progress" })
                Text("Step ${state.step + 1} of 4 · ${listOf("Microphone", "Input", "Pair Mac", "Try it")[state.step]}", style = MaterialTheme.typography.labelLarge)
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
                        Text("Allow the microphone", style = MaterialTheme.typography.titleLarge)
                        Text("The mic opens only when you start dictation and is released as soon as you stop. No recordings or transcripts are saved on this phone.")
                        Button(grantMic, Modifier.fillMaxWidth()) { Text(if (state.mic) "Microphone allowed ✓" else "Allow microphone") }
                        TextButton(appSettings) { Text("Open app permissions") }
                    }
                    1 -> {
                        Text("Keep Samsung Keyboard", style = MaterialTheme.typography.titleLarge)
                        Text("Optional floating mic: a button beside the focused text field. Your keyboard stays selected. Chirp reads only that field’s text and selection to insert safely; it never sends field contents to the Mac.")
                        Button(accessibilitySettings, Modifier.fillMaxWidth()) { Text(if (state.bubbleEnabled) "Floating mic enabled ✓" else "Enable floating microphone") }
                        Text("Settings → Accessibility → Installed apps → Chirp floating microphone. Sideload blocked? Try enabling once, then Apps → Chirp Voice → ⋮ → Allow restricted settings. Return here afterward.")
                        Text("Android 17 Advanced Protection can block non-accessibility tools. If the switch is unavailable, use Chirp Voice below.")
                        HorizontalDivider()
                        Text("Chirp Voice keyboard", style = MaterialTheme.typography.titleMedium)
                        Text("Works with editors that don’t support the floating mic. Enable Chirp, then use the keyboard button to select it. Voice shortcut launches start listening immediately; Samsung’s mic picker may offer only Samsung and Google.")
                        OutlinedButton(keyboardSettings, Modifier.fillMaxWidth()) { Text(if (state.inputEnabled) "Chirp Voice enabled ✓" else "Enable Chirp Voice keyboard") }
                        TextButton(picker) { Text("Choose keyboard") }
                    }
                    2 -> {
                        Text("Connect your Mac", style = MaterialTheme.typography.titleLarge)
                        Text("Turn on Tailscale on both devices. On the Mac, open Chirp’s pairing QR code. Scan it or paste the pairing link below.")
                        Button(scan, Modifier.fillMaxWidth(), enabled = !state.scanning) { Text(if (state.scanning) "Scanning…" else "Scan pairing QR") }
                        OutlinedTextField(state.link, { state.link = it }, Modifier.fillMaxWidth().semantics { contentDescription = "Private Chirp pairing link" },
                            label = { Text("Pairing link") }, singleLine = true,
                            visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
                        Text("QR scanning uses Google Play services. Paste works without the scanner. Pairing tokens are encrypted with Android Keystore.", style = MaterialTheme.typography.bodySmall)
                        Button(check, Modifier.fillMaxWidth(), enabled = !state.checking) { Text("Test connection & save pairing") }
                    }
                    3 -> {
                        Text("Try a sentence", style = MaterialTheme.typography.titleLarge)
                        Text("Tap the field below. Use the floating mic, or select Chirp Voice with the keyboard button. Tap to toggle; hold to talk. Cancel discards the utterance.")
                        // Deliberately a real native editor: exercises the same InputConnection/accessibility path as other apps.
                        val editorInk = MaterialTheme.colorScheme.onSurface.toArgb()
                        val editorHint = MaterialTheme.colorScheme.onSurfaceVariant.toArgb()
                        val editorAccent = MaterialTheme.colorScheme.primary.toArgb()
                        AndroidView(factory = { context -> EditText(context).apply {
                            hint = "Test dictation here"; minLines = 3
                            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
                            isSaveEnabled = false; importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS
                        } }, update = { editor ->
                            editor.setTextColor(editorInk); editor.setHintTextColor(editorHint)
                            editor.backgroundTintList = ColorStateList.valueOf(editorAccent)
                        }, modifier = Modifier.fillMaxWidth())
                        TextButton(picker) { Text("Choose keyboard") }
                        OutlinedButton(check, Modifier.fillMaxWidth(), enabled = !state.checking) { Text("Check Mac connection") }
                        Text("Mac unreachable — is Tailscale on?", style = MaterialTheme.typography.titleSmall)
                        Text("Check Tailscale is connected on both devices, wake the Mac, and check Chirp’s server is running. If pairing was replaced, scan a new QR code.")
                        Preference("Return to previous keyboard after dictation", state.returnToPrevious) { state.returnToPrevious = it; preferences() }
                        Preference("Haptic cues", state.haptics) { state.haptics = it; preferences() }
                        Preference(correctionLabel(state.health), state.correction,
                            state.health?.let { it.correctionAvailable && (!it.correctionLeavesMachine || it.correctionHost != null) } == true) {
                            state.correction = it; preferences()
                        }
                        Preference("Debug overlay (timings only)", state.debug) { state.debug = it; preferences() }
                        TextButton(forget) { Text("Forget pairing") }
                    }
                }
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    TextButton({ state.step-- }, enabled = state.step > 0) { Text("Back") }
                    if (state.step < 3) Button({ state.step++ }) { Text("Next") }
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
