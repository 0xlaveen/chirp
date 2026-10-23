package dev.chirp.android

import android.Manifest
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PersistableBundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory

/** Dictate long-form text on the phone, edit it, copy or share it. Memory only: the text leaves with the screen. */
open class ScratchpadActivity : ComponentActivity() {
    internal open fun createModel(): ScratchpadModel = ScratchpadModel(applicationContext)
    internal open val tailscale: TailscaleControl by lazy { AndroidTailscale(this) }
    internal val model: ScratchpadModel by viewModels { viewModelFactory { initializer { createModel() } } }
    private val micPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) model.start() else model.status = "Microphone permission is needed to dictate — open mic settings"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Keep dictated text out of the Recents thumbnail.
        if (Build.VERSION.SDK_INT >= 33) setRecentsScreenshotEnabled(false)
        setContent {
            ChirpTheme { ScratchpadScreen(model, mic = ::mic, copy = ::copy, share = ::share, act = ::act) }
        }
    }
    override fun onStart() { super.onStart(); model.refresh() }
    override fun onStop() { model.pause(); super.onStop() }

    internal fun mic() {
        if (model.active || checkSelfPermission(Manifest.permission.RECORD_AUDIO) == android.content.pm.PackageManager.PERMISSION_GRANTED) model.toggle()
        else micPermission.launch(Manifest.permission.RECORD_AUDIO)
    }
    internal fun copy() {
        val text = model.field.text.takeIf { it.isNotBlank() } ?: return
        val clip = ClipData.newPlainText("Chirp dictation", text)
        // Keeps the text out of clipboard previews and overlays where the system supports it.
        clip.description.extras = PersistableBundle().apply {
            putBoolean(if (Build.VERSION.SDK_INT >= 33) ClipDescription.EXTRA_IS_SENSITIVE else "android.content.extra.IS_SENSITIVE", true)
        }
        getSystemService(ClipboardManager::class.java)?.setPrimaryClip(clip)
        model.status = "Copied"
    }
    internal fun share() {
        val text = model.field.text.takeIf { it.isNotBlank() } ?: return
        startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text), null))
    }
    internal fun act(action: DictationAction) {
        fun setup(section: String) = startActivity(Intent(this, SetupActivity::class.java).putExtra("section", section)
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP))
        when (action) {
            DictationAction.PAIR -> setup("pair")
            DictationAction.MICROPHONE -> startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null)))
            DictationAction.NETWORK, DictationAction.TAILSCALE_OPEN -> if (!tailscale.open()) setup("network")
            DictationAction.TAILSCALE_SETUP -> setup("network")
            DictationAction.TAILSCALE_ON -> if (tailscale.connect()) model.status = "Connecting Tailscale…" else if (!tailscale.open()) setup("network")
        }
    }

    companion object {
        /** Opens the Scratchpad from outside the app (Quick Settings tile). */
        fun intent(context: Context) = Intent(context, ScratchpadActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
    }
}

@Composable
internal fun ScratchpadScreen(model: ScratchpadModel, mic: () -> Unit, copy: () -> Unit, share: () -> Unit, act: (DictationAction) -> Unit) {
    val action = DictationAction.forStatus(model.status)
    Surface(Modifier.fillMaxSize()) {
        Box(Modifier.fillMaxSize().safeDrawingPadding(), contentAlignment = Alignment.TopCenter) {
            Column(Modifier.widthIn(max = 600.dp).fillMaxSize().padding(horizontal = 24.dp, vertical = 16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("CHIRP  /  SCRATCHPAD", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
                if (model.retained) Text(stringResource(R.string.debug_retention), Modifier.fillMaxWidth().background(androidx.compose.ui.graphics.Color(0xFFA41818)).padding(8.dp),
                    color = androidx.compose.ui.graphics.Color.White, style = MaterialTheme.typography.labelLarge)
                OutlinedTextField(model.field, { if (!model.active) model.field = it }, Modifier.fillMaxWidth().weight(1f).heightIn(min = 120.dp),
                    label = { Text("Scratchpad text") }, placeholder = { Text("Dictate, then edit here") }, readOnly = model.active,
                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences))
                if (model.active && model.partial.isNotEmpty()) Text(model.partial, Modifier.fillMaxWidth(), color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.bodyMedium, maxLines = 3)
                if (model.cleanupAvailable) Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterChip(!model.cleanup, { model.choose(null) }, label = { Text("Raw") }, enabled = !model.active)
                    model.profiles.forEach { profile ->
                        FilterChip(model.cleanup && model.style.id == profile.id, { model.choose(profile) },
                            label = { Text(profile.name) }, enabled = !model.active)
                    }
                }
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(model.status, Modifier.weight(1f).semantics { liveRegion = LiveRegionMode.Polite }, style = MaterialTheme.typography.bodyMedium)
                    if (action != null) TextButton({ act(action) }) { Text(action.label) }
                }
                MicButton(model, mic)
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(copy, Modifier.weight(1f), enabled = model.hasText) { Text("Copy") }
                    OutlinedButton(share, Modifier.weight(1f), enabled = model.hasText) { Text("Share") }
                    TextButton({ model.clear() }, enabled = model.hasText && !model.active) { Text("Clear") }
                }
                Text(if (model.historyOn) "Dictation history is on: each dictation is also saved, encrypted, on this phone. The text above is not."
                    else "Nothing is saved. This text is gone when you leave the Scratchpad.", style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}

@Composable
private fun MicButton(model: ScratchpadModel, onClick: () -> Unit) {
    val halo by animateDpAsState((96 + (if (model.active && !model.stopping) model.level.coerceIn(0.0, 1.0) * 36 else 0.0)).dp, label = "level")
    Box(Modifier.fillMaxWidth().height(136.dp), contentAlignment = Alignment.Center) {
        Box(Modifier.size(halo).background(MaterialTheme.colorScheme.primary.copy(alpha = .2f), CircleShape))
        Surface(onClick, Modifier.size(96.dp).semantics {
            role = Role.Button
            contentDescription = if (model.active) "Microphone: stop dictation" else "Microphone: tap to dictate"
        }, enabled = !model.stopping, shape = CircleShape, color = MaterialTheme.colorScheme.primary) {
            Box(contentAlignment = Alignment.Center) {
                androidx.compose.material3.Icon(painterResource(if (model.active) R.drawable.ic_stop else R.drawable.ic_mic), null,
                    Modifier.size(40.dp), tint = MaterialTheme.colorScheme.onPrimary)
            }
        }
    }
}
