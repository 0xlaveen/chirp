package dev.chirp.android

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent

/**
 * Live Notes on the phone: record a meeting or a long think-aloud, and the Mac turns it into Markdown notes while the
 * transcript fills in beside them. Kept until Save, Copy or Share, with a sealed recovery copy meanwhile ([NotesJournal]).
 * The screen itself is [NotesScreen], which the app shell also hosts as its Notes tab; both share one session ([NotesSessionHolder]).
 */
open class NotesActivity : ComponentActivity() {
    internal open fun createModel(): NotesModel = NotesModel(applicationContext)
    internal open val tailscale: TailscaleControl by lazy { AndroidTailscale(this) }
    internal val model: NotesModel by lazy { NotesSessionHolder.model(this, ::createModel) }
    private val host = NotesHost(this, { tailscale }, { model })
    private var recordOnResume = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Keep the notes out of the Recents thumbnail.
        if (Build.VERSION.SDK_INT >= 33) setRecentsScreenshotEnabled(false)
        handle(intent)
        setContent {
            ChirpTheme {
                NotesScreen(model, record = ::record, copy = ::copy, share = ::share, act = ::act, leave = ::leave, save = ::save)
            }
        }
    }
    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); handle(intent) }
    override fun onStart() { super.onStart(); NotesSessionHolder.visible(model, this, true); model.refresh() }
    // Screen off or another app in front: the battery saver skips screen work until this is visible again.
    override fun onStop() { NotesSessionHolder.visible(model, this, false); super.onStop() }
    // The microphone service may only start from a visible screen: the tile's Record waits until this one is.
    override fun onResume() { super.onResume(); if (recordOnResume) { recordOnResume = false; if (!model.state.active) record() } }

    private fun handle(intent: Intent?) {
        when (intent?.action) {
            NotesService.ACTION_STOP -> if (model.state.live) model.stop()
            NotesService.ACTION_RECORD -> recordOnResume = true
            else -> return
        }
        setIntent(Intent(intent).setAction(null))
    }

    internal fun record() = host.record()

    /** Back while recording keeps it going in the background; with notes, it asks first (nothing is saved). */
    internal fun leave(discard: Boolean) {
        when {
            model.state.active -> moveTaskToBack(true)
            discard || !model.dirty || model.keepSession() -> { model.clear(); finish() }
        }
    }

    internal fun copy() = host.copy()
    internal fun share() = host.share()
    internal fun save() = host.save()
    internal fun write(uri: Uri) = host.write(uri)
    internal fun act(action: DictationAction) = host.act(action)

    companion object {
        /** Opens Notes from outside (the recording notification), reusing the running screen. */
        fun intent(context: Context) = Intent(context, NotesActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
    }
}
