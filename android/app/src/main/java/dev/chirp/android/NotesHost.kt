package dev.chirp.android

import android.Manifest
import android.app.Application
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PersistableBundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.ViewModelStoreOwner
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory

/**
 * One Live Notes session per process, shared by [NotesActivity] and the app shell's Notes tab: the recording notification,
 * the tile and either screen all reach the same notes. Cleared (kept or left for recovery, as [NotesModel.onCleared] does)
 * when the last screen showing it finishes for good; a rotation or fold keeps it.
 */
internal object NotesSessionHolder : ViewModelStoreOwner {
    override val viewModelStore = ViewModelStore()
    private var app: Application? = null
    private val hosts = mutableSetOf<ComponentActivity>()
    private val shown = mutableSetOf<Any>()
    /** The live session, if any screen has opened one (Home's Notes tile says "Recording"). */
    var current by mutableStateOf<NotesModel?>(null)
        private set

    fun model(host: ComponentActivity, create: () -> NotesModel): NotesModel {
        // A new process image (each Robolectric test) never inherits a session from the last.
        if (app !== host.application) { clear(); hosts.clear(); shown.clear(); app = host.application }
        if (hosts.add(host)) host.lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onDestroy(owner: LifecycleOwner) {
                hosts.remove(host); shown.remove(host)
                if (hosts.isEmpty() && !host.isChangingConfigurations && app === host.application) clear()
            }
        })
        return ViewModelProvider(this, viewModelFactory { initializer { create() } })[NotesModel::class.java].also { current = it }
    }
    private fun clear() { current = null; viewModelStore.clear() }

    /** The notes are on screen somewhere; the battery saver may quiet them only when no host shows them. */
    fun visible(model: NotesModel, host: Any, on: Boolean) {
        if (on) shown.add(host) else shown.remove(host)
        model.visible(shown.isNotEmpty())
    }
}

/** What a screen hosting [NotesScreen] needs from its activity: permission prompts, the save picker, copy, share and fix actions. */
internal class NotesHost(private val activity: ComponentActivity, private val tailscale: () -> TailscaleControl, private val model: () -> NotesModel) {
    private val micPermission = activity.registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) record() else model().message = "Microphone permission is needed to take notes — open mic settings"
    }
    /** Optional: without it the recording still runs, only its notification (with Stop) stays hidden. */
    private val notificationPermission = activity.registerForActivityResult(ActivityResultContracts.RequestPermission()) { model().start() }
    private val saveFile = activity.registerForActivityResult(ActivityResultContracts.CreateDocument("text/markdown")) { uri -> uri?.let(::write) }
    private var asked = false

    fun record() {
        val model = model()
        if (model.state.active) { model.toggle(); return }
        when {
            activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED -> micPermission.launch(Manifest.permission.RECORD_AUDIO)
            Build.VERSION.SDK_INT >= 33 && activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED &&
                !asked -> { asked = true; notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS) }
            else -> model.start()
        }
    }

    fun copy() {
        val model = model()
        if (!model.hasContent) return
        val clip = ClipData.newPlainText("Chirp notes", model.export())
        // Keeps the notes out of clipboard previews and overlays where the system supports it.
        clip.description.extras = PersistableBundle().apply {
            putBoolean(if (Build.VERSION.SDK_INT >= 33) ClipDescription.EXTRA_IS_SENSITIVE else "android.content.extra.IS_SENSITIVE", true)
        }
        activity.getSystemService(ClipboardManager::class.java)?.setPrimaryClip(clip)
        model.message = "Copied as Markdown"
    }
    fun share() {
        val model = model()
        if (!model.hasContent) return
        activity.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/markdown")
            .putExtra(Intent.EXTRA_SUBJECT, model.document.title().removePrefix("# ")).putExtra(Intent.EXTRA_TEXT, model.export()), null))
    }
    fun save() {
        val model = model()
        if (!model.hasContent) return
        try { saveFile.launch(model.document.fileName()) } catch (_: android.content.ActivityNotFoundException) { model.message = "No app to save files — use Share" }
    }
    fun write(uri: Uri) = model().save { activity.contentResolver.openOutputStream(uri, "wt") }
    fun act(action: DictationAction) {
        fun setup(section: String) = activity.startActivity(Intent(activity, SetupActivity::class.java).putExtra("section", section)
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP))
        val tailscale = tailscale()
        when (action) {
            DictationAction.PAIR -> setup("pair")
            DictationAction.MICROPHONE -> activity.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", activity.packageName, null)))
            DictationAction.NETWORK, DictationAction.TAILSCALE_OPEN -> if (!tailscale.open()) setup("network")
            DictationAction.TAILSCALE_SETUP -> setup("network")
            DictationAction.TAILSCALE_ON -> if (tailscale.connect()) model().message = "Connecting Tailscale…" else if (!tailscale.open()) setup("network")
        }
    }
}
