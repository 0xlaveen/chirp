package dev.chirp.android

import androidx.annotation.DrawableRes
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import dev.chirp.android.settings.connectionSummary
import dev.chirp.android.ui.*

@Composable
internal fun OnboardingPage(page: Int, state: SetupState, actions: OnboardingActions) {
    val next = { state.step = page + 1 }
    when (page) {
        PAGE_WELCOME -> PageFrame("Dictate anywhere", { PondHero() }, PrimaryAction("Get started") { next() }) {
            Body("Speak on your phone and your computer writes the words into any app, privately over Tailscale. " +
                "Meetings and thoughts can live in Notes: a recording that transcribes and organises itself while you talk.")
            Body("Dictation history and learning from your edits are on by default, encrypted on this phone. Turn them off in Settings → Dictation.")
        }
        PAGE_CHOICE -> PageFrame("How you’ll dictate", {}, PrimaryAction("Continue", state.inputMode != null) { next() }) {
            InputModeCards(state, actions.chooseMode)
        }
        PAGE_KEYBOARD -> if (state.inputMode == InputMode.OWN_KEYBOARD) {
            PageFrame("Turn on the floating mic", {}, when {
                state.advancedProtection -> PrimaryAction("Continue without it", onClick = actions.skipFloatingMic)
                state.bubbleEnabled -> PrimaryAction("Continue") { next() }
                else -> PrimaryAction("Open Accessibility settings", onClick = actions.accessibility)
            }) {
                FloatingMicGuide(state, actions.accessibility, actions.appSettings,
                    useKeyboard = { actions.chooseMode(InputMode.KEYBOARD) })
                if (!state.advancedProtection) TextButton(actions.skipFloatingMic) { Text("Skip for now") }
            }
        } else PageFrame("Turn on Chirp Keyboard", { Illustration(R.drawable.ic_keyboard) }, when {
            !state.inputEnabled -> PrimaryAction("Enable Chirp Keyboard", onClick = actions.keyboardSettings)
            !state.inputSelected -> PrimaryAction("Select Chirp Keyboard", onClick = actions.picker)
            else -> PrimaryAction("Continue") { next() }
        }) {
            Body("A full keyboard with Chirp’s microphone built in. Type normally, or tap the mic above the keys to dictate.")
            SettingsGroup {
                CheckRow("Enabled", state.inputEnabled)
                CheckRow("Selected as default", state.inputSelected)
            }
            val swipe = swipeTypingSummary(LocalContext.current)
            Tips("Samsung path and suggestions", "Keyboard tips",
                "Samsung: Settings → General management → Keyboard list and default.\n\n" +
                    "English autocorrect, next-word and emoji suggestions are ready to use. Personalised suggestions learn typed words on this device; " +
                    "turn them off in Chirp settings → Keyboard → Layouts, languages & typing → Text correction. Dictation finals bypass keyboard learning.\n\n$swipe")
        }
        PAGE_MIC -> PageFrame("Allow the microphone", { Illustration(R.drawable.ic_mic) }, if (state.mic) PrimaryAction("Continue") { next() }
            else PrimaryAction("Allow microphone", onClick = actions.grantMic)) {
            Body("Chirp listens only while you dictate or record a note. Notes and optional kept audio stay on this phone.")
            if (state.mic) SettingsGroup { CheckRow("Microphone allowed", true) }
            else if (state.micDenied) StatusBanner(StatusKind.Warning, "Allow the microphone to dictate", action = "Open app permissions", onAction = actions.appSettings, live = true)
            Tips("What Chirp keeps", "Your microphone",
                "The mic opens only when you start dictation or a note and is released when you stop. Dictation history and learning from your edits are on by default, encrypted on this phone; turn them off in Settings → Dictation. " +
                "Notes are kept locally; keeping their audio is optional and off by default.")
        }
        else -> PairPage(state, actions)
    }
}

@Composable
private fun PairPage(state: SetupState, actions: OnboardingActions) {
    var paste by rememberSaveable { mutableStateOf(false) }
    val context = LocalContext.current
    if (state.connected) {
        val connection = connectionSummary(true, state.host, state.reachable, false, state.health)
        PageFrame("Connected", { Illustration(R.drawable.ic_check_circle) }, PrimaryAction("Finish", onClick = actions.finish)) {
            StatusBanner(connection.kind, connection.title, body = connection.summary, live = true)
            if (state.health?.debugRetention == true) StatusBanner(StatusKind.Error, "DEBUG RETENTION IS ON — the Chirp server may retain audio and text")
        }
        return
    }
    val busy = state.scanning || state.checking
    PageFrame("Scan the code on your computer", { Illustration(R.drawable.ic_qr_scan) },
        PrimaryAction(when { state.scanning -> "Scanning…"; state.checking -> "Connecting…"; else -> "Scan code" }, !busy, actions.scan)) {
        Body("Turn on Tailscale on both devices. On your computer, open Chirp → Settings → Devices → Pair a Phone.")
        if (state.wifiPermissionNeeded && !state.localNetwork) StatusBanner(StatusKind.Warning, "Allow Wi-Fi server access",
            body = "Needed only for servers on your Wi-Fi. Tailscale works without it.", action = "Allow", onAction = actions.grantNetwork)
        if (state.checking) StatusBanner(StatusKind.Info, "Connecting to your computer…", live = true)
        else when (state.pairIssue) {
            PairIssue.Unreachable -> {
                val tailscale = remember(context) { AndroidTailscale(context).installed() }
                StatusBanner(StatusKind.Error, "Couldn’t reach your computer", body = "Check Tailscale is on for both devices and Chirp is running on the computer.",
                    action = if (tailscale) "Open Tailscale" else "Try again", onAction = if (tailscale) actions.openTailscale else actions.retry, live = true)
            }
            PairIssue.ScannerUnavailable -> StatusBanner(StatusKind.Warning, "Scanner unavailable", body = "QR scanning uses Google Play services.",
                action = "Paste link instead", onAction = { paste = true }, live = true)
            PairIssue.InvalidLink -> StatusBanner(StatusKind.Error, "That isn’t a Chirp pairing code", action = "Scan again", onAction = actions.scan, live = true)
            null -> {}
        }
        if (!paste && state.link.isEmpty()) { if (state.pairIssue != PairIssue.ScannerUnavailable) TextButton({ paste = true }, Modifier.align(Alignment.CenterHorizontally)) { Text("Paste link instead") } }
        else {
            val invalid = state.link.isNotBlank() && runCatching { Pairing.parse(state.link) }.isFailure
            OutlinedTextField(state.link, { actions.pasteLink(it) }, Modifier.fillMaxWidth().semantics { contentDescription = "Private Chirp pairing link" },
                label = { Text("Pairing link") }, singleLine = true, isError = invalid,
                supportingText = { Text(if (invalid) "That isn’t a Chirp pairing link" else "Pasting a valid link connects right away") },
                visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
        }
        Tips("About scanning", "Scanning and pairing",
            "QR scanning uses Google Play services; Chirp needs no camera permission. Pasting the link works without the scanner. " +
                "Pairing tokens are encrypted with Android Keystore, and nothing is saved until your computer answers.")
    }
}

/**
 * Title, hero and scrolling content, with the page's one primary button pinned below (inside the system bars, never scrolled away).
 * The hero runs edge to edge; the text keeps the page gutter. At 200% font the content scrolls under the hero, button still pinned.
 */
@Composable
internal fun PageFrame(title: String, hero: @Composable () -> Unit, primary: PrimaryAction, content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Column(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.TopCenter) { hero() }
            Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Text(title, Modifier.fillMaxWidth().semantics { heading() }, style = MaterialTheme.typography.headlineMedium, textAlign = TextAlign.Center)
                content()
            }
        }
        Button(primary.onClick, Modifier.fillMaxWidth().padding(horizontal = 24.dp).heightIn(min = 56.dp), enabled = primary.enabled) { Text(primary.label) }
    }
}

/** The approved full-bleed pond artwork (spec §D), used as-is: no tiles, borders or overlays; a centre crop fills the width. */
@Composable
private fun PondHero() {
    Image(painterResource(R.drawable.chirp_pond), null, Modifier.fillMaxWidth().height(300.dp), contentScale = ContentScale.Crop)
}

@Composable
private fun Illustration(@DrawableRes icon: Int, wide: Boolean = false) {
    val scheme = MaterialTheme.colorScheme
    if (wide) Icon(painterResource(icon), null, Modifier.padding(horizontal = 24.dp, vertical = 8.dp), tint = scheme.primary)
    else Box(Modifier.size(152.dp).clip(CircleShape).background(scheme.surfaceContainerHigh), contentAlignment = Alignment.Center) {
        Icon(painterResource(icon), null, Modifier.size(72.dp), tint = scheme.primary)
    }
}

@Composable
private fun Body(text: String) = Text(text, Modifier.fillMaxWidth(), style = MaterialTheme.typography.bodyLarge, textAlign = TextAlign.Center,
    color = MaterialTheme.colorScheme.onSurfaceVariant)

/** One requirement: a check in a circle when met, an empty circle when not (an icon, not a "✓" character). */
@Composable
internal fun CheckRow(title: String, done: Boolean) {
    ListItem(headlineContent = { Text(title) }, modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp)
        .semantics(mergeDescendants = true) { stateDescription = if (done) "Done" else "Not done yet" },
        leadingContent = { Icon(painterResource(if (done) R.drawable.ic_check_circle else R.drawable.ic_circle_outline), null,
            tint = if (done) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline) },
        colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.surfaceContainer))
}

/** Secondary detail behind a text button, so a page keeps to one idea. */
@Composable
private fun ColumnScope.Tips(label: String, title: String, body: String) =
    LearnMore(title, body, Modifier.align(Alignment.CenterHorizontally), label)
