package dev.chirp.android

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.os.IBinder

/**
 * Keeps the Notes microphone running with the screen off or another app in front. It records nothing itself: the
 * session lives in the Notes screen's view model, which starts this while recording (from the visible activity, as
 * Android requires for the microphone) and stops it after. While it runs, a paused session can resume from the
 * background. The notification (also on the lock screen) has Pause/Resume and Stop and carries no notes or transcript text.
 */
class NotesService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action != null) {
            // A notification button: the session acts on it; a stale one (no session) has nothing to keep running.
            if (!NotesControls.act(intent.action)) stopSelf(startId)
            return START_NOT_STICKY
        }
        try {
            val session = NotesControls.session
            startForeground(ID, notification(this, session?.state == NotesRecorder.State.PAUSED, session?.recordedSeconds ?: 0.0),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        } catch (_: RuntimeException) {
            // Not allowed now (no microphone permission, or not started from the visible screen): recording goes on
            // only while the screen is in front.
            stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) { stopSelf() }

    companion object {
        const val ID = 5701
        const val CHANNEL = "notes"
        const val ACTION_STOP = "dev.chirp.android.notes.STOP"
        const val ACTION_PAUSE = "dev.chirp.android.notes.PAUSE"
        const val ACTION_RESUME = "dev.chirp.android.notes.RESUME"
        /** Opens Notes and starts recording (the Quick Settings tile). */
        const val ACTION_RECORD = "dev.chirp.android.notes.RECORD"

        fun set(context: Context, on: Boolean) {
            val intent = Intent(context, NotesService::class.java)
            if (!on) { context.stopService(intent); return }
            try { context.startForegroundService(intent) } catch (_: RuntimeException) { }
        }

        /** Re-posts the running service's notification (paused or recording); null removes it. */
        fun update(context: Context, paused: Boolean?, elapsed: Double, saver: Boolean = false) {
            val manager = context.getSystemService(NotificationManager::class.java)
            try { if (paused == null) manager.cancel(ID) else manager.notify(ID, notification(context, paused, elapsed, saver)) } catch (_: RuntimeException) { }
        }

        /** [saver]: the battery saver is skipping screen work; the notes catch up the moment the screen is back. */
        fun notification(context: Context, paused: Boolean = false, elapsed: Double = 0.0, saver: Boolean = false): Notification {
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(NotificationChannel(CHANNEL, context.getString(R.string.notes_channel), NotificationManager.IMPORTANCE_LOW)
                .apply { setShowBadge(false) })
            val open = PendingIntent.getActivity(context, 0, NotesActivity.intent(context), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            fun control(action: String, code: Int, icon: Int, label: Int) = Notification.Action.Builder(Icon.createWithResource(context, icon),
                context.getString(label), PendingIntent.getService(context, code, Intent(context, NotesService::class.java).setAction(action),
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)).build()
            return Notification.Builder(context, CHANNEL)
                .setSmallIcon(R.drawable.ic_mic)
                .setContentTitle(context.getString(if (paused) R.string.notes_paused else R.string.notes_recording))
                .apply { if (saver) setSubText(context.getString(R.string.notes_saver)) }
                .setContentIntent(open)
                .addAction(if (paused) control(ACTION_RESUME, 2, R.drawable.ic_record, R.string.notes_resume)
                    else control(ACTION_PAUSE, 3, R.drawable.ic_pause, R.string.notes_pause))
                .addAction(control(ACTION_STOP, 1, R.drawable.ic_stop, R.string.notes_stop))
                // The elapsed time counts on while recording, also on the lock screen.
                .setShowWhen(!paused).setUsesChronometer(!paused).setWhen(System.currentTimeMillis() - (elapsed * 1000).toLong())
                .setOngoing(true).setCategory(Notification.CATEGORY_SERVICE).setVisibility(Notification.VISIBILITY_PUBLIC)
                .setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
                .build()
        }
    }
}
