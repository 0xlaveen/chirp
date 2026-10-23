package dev.chirp.android

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/** Quick Settings tile: one tap collapses the shade and opens the Scratchpad. It holds no state and no text. */
open class ScratchpadTileService : TileService() {
    override fun onStartListening() {
        qsTile?.apply { state = Tile.STATE_INACTIVE; updateTile() }
    }
    override fun onClick() {
        val intent = ScratchpadActivity.intent(this)
        val pending = PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        // Pairing is credential-encrypted: ask for the screen lock first instead of opening a screen that cannot work.
        if (locked()) unlock { open(intent, pending) } else open(intent, pending)
    }
    internal open fun locked() = isLocked
    internal open fun unlock(then: Runnable) = unlockAndRun(then)
    internal open fun open(intent: Intent, pending: PendingIntent) {
        if (Build.VERSION.SDK_INT >= 34) startActivityAndCollapse(pending)
        else @Suppress("DEPRECATION") startActivityAndCollapse(intent)
    }
}
