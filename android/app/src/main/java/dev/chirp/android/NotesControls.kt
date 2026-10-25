package dev.chirp.android

import android.content.ComponentName
import android.content.Context
import android.service.quicksettings.TileService

/**
 * Reaches the Notes session from outside its screen: the recording notification's Pause, Resume and Stop, and the Quick
 * Settings tile. The session registers itself while it holds the microphone service. Main thread only; carries no text.
 */
internal object NotesControls {
    interface Session {
        val state: NotesRecorder.State
        /** Audio recorded so far, seconds (the notification's running time). */
        val recordedSeconds: Double
        /** The battery saver is skipping screen work (the screen is off). */
        val quiet: Boolean
        /** Voice edit: null when the Mac cannot edit by voice, else whether a command is listening. */
        val commanding: Boolean?
        /** Share sheet hand-off stays in process and is accepted only by a live note. */
        val shareTitle: String? get() = null
        fun appendShared(text: String): Boolean = false
        fun pause()
        fun resume()
        fun stop()
        /** The notification's Command action: start a command, or end the one listening. */
        fun command()
    }

    var session: Session? = null
        private set

    /** A notification button. False when there is no session to act on. */
    fun act(action: String?): Boolean {
        val current = session ?: return false
        when (action) {
            NotesService.ACTION_PAUSE -> current.pause()
            NotesService.ACTION_RESUME -> current.resume()
            NotesService.ACTION_STOP -> current.stop()
            NotesService.ACTION_COMMAND -> current.command()
            else -> return false
        }
        return true
    }

    /** The session's state changed: re-post the notification and ask the tile to redraw. */
    fun publish(context: Context, from: Session) {
        val state = from.state
        if (state.active) { session = from; NotesService.update(context, state == NotesRecorder.State.PAUSED, from.recordedSeconds, from.quiet, from.commanding) }
        else if (session === from) { session = null; NotesService.update(context, null, 0.0) }
        else return
        refreshTile(context)
    }

    fun release(context: Context, from: Session) { if (session === from) { session = null; refreshTile(context) } }

    private fun refreshTile(context: Context) {
        try { TileService.requestListeningState(context, ComponentName(context, NotesTileService::class.java)) } catch (_: RuntimeException) { }
    }
}
