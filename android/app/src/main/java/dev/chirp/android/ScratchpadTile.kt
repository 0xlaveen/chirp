package dev.chirp.android

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/** A tile that opens one of Chirp's screens: collapses the shade, asking for the screen lock first. */
abstract class LaunchTileService : TileService() {
    protected fun launch(intent: Intent) {
        val pending = PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        // Pairing is credential-encrypted: ask for the screen lock first instead of opening a screen that cannot work.
        if (locked()) unlock { open(intent, pending) } else open(intent, pending)
    }
    internal open fun locked() = isLocked
    internal open fun unlock(then: Runnable) = unlockAndRun(then)
    // The Intent overload throws on API 34+; it is reached only on API 31-33, where the PendingIntent one does not exist.
    @SuppressLint("StartActivityAndCollapseDeprecated")
    internal open fun open(intent: Intent, pending: PendingIntent) {
        if (Build.VERSION.SDK_INT >= 34) startActivityAndCollapse(pending)
        else @Suppress("DEPRECATION") startActivityAndCollapse(intent)
    }
}

/** Quick Settings tile: one tap collapses the shade and opens the Scratchpad. It holds no state and no text. */
open class ScratchpadTileService : LaunchTileService() {
    override fun onStartListening() {
        qsTile?.apply { state = Tile.STATE_INACTIVE; updateTile() }
    }
    override fun onClick() = launch(ScratchpadActivity.intent(this))
}

/** Quick Settings tile for Notes: tap to open Notes and record, tap again to stop. Shows Recording or Paused; no text. */
open class NotesTileService : LaunchTileService() {
    override fun onStartListening() {
        val state = NotesControls.session?.state
        qsTile?.apply {
            this.state = if (state?.active == true) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
            subtitle = when (state) {
                NotesRecorder.State.STARTING, NotesRecorder.State.RECORDING -> "Recording"
                NotesRecorder.State.PAUSED -> "Paused"
                NotesRecorder.State.STOPPING -> "Finishing"
                else -> null
            }
            updateTile()
        }
    }
    override fun onClick() {
        val session = NotesControls.session
        // Stopping needs no unlock: it only ends a recording already running.
        if (session != null && session.state.live) { session.stop(); onStartListening() }
        else launch(NotesActivity.intent(this).setAction(if (session == null) NotesService.ACTION_RECORD else null))
    }
}
