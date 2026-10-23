package dev.chirp.android

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder

/**
 * Keeps the Notes microphone running with the screen off or another app in front. It records nothing itself: the
 * session lives in the Notes screen's view model, which starts this while recording (from the visible activity, as
 * Android requires for the microphone) and stops it after. The notification carries no notes or transcript text.
 */
class NotesService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            startForeground(ID, notification(this), ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
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

        fun set(context: Context, on: Boolean) {
            val intent = Intent(context, NotesService::class.java)
            if (!on) { context.stopService(intent); return }
            try { context.startForegroundService(intent) } catch (_: RuntimeException) { }
        }

        fun notification(context: Context): Notification {
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(NotificationChannel(CHANNEL, context.getString(R.string.notes_channel), NotificationManager.IMPORTANCE_LOW)
                .apply { setShowBadge(false) })
            fun open(action: String?, code: Int) = PendingIntent.getActivity(context, code,
                NotesActivity.intent(context).setAction(action), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            return Notification.Builder(context, CHANNEL)
                .setSmallIcon(R.drawable.ic_mic)
                .setContentTitle(context.getString(R.string.notes_recording))
                .setContentIntent(open(null, 0))
                .addAction(Notification.Action.Builder(null, context.getString(R.string.notes_stop), open(ACTION_STOP, 1)).build())
                .setOngoing(true).setCategory(Notification.CATEGORY_SERVICE).setVisibility(Notification.VISIBILITY_PUBLIC)
                .setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
                .build()
        }
    }
}
