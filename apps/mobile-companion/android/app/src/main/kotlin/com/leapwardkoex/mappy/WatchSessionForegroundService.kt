package com.leapwardkoex.mappy

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper

class WatchSessionForegroundService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private val stopRunnable = Runnable { stopNow() }
    private val idleRunnable = Runnable { stopAfterIdle() }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP_AFTER_GRACE -> {
                handler.removeCallbacks(stopRunnable)
                handler.postDelayed(stopRunnable, STOP_GRACE_MILLIS)
            }
            ACTION_STOP_AFTER_DISCONNECT -> {
                handler.removeCallbacks(stopRunnable)
                handler.postDelayed(stopRunnable, DISCONNECT_GRACE_MILLIS)
            }
            ACTION_NOTE_ACTIVITY -> scheduleIdleStop()
            else -> {
                handler.removeCallbacks(stopRunnable)
                try {
                    startForeground(NOTIFICATION_ID, buildNotification())
                    isActive = true
                    lastStartError = null
                    scheduleIdleStop()
                } catch (error: RuntimeException) {
                    isActive = false
                    lastStartError = error.localizedMessage ?: "Watch session service could not start."
                    stopSelf(startId)
                }
            }
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        handler.removeCallbacks(stopRunnable)
        handler.removeCallbacks(idleRunnable)
        isActive = false
        HeadlessWatchRuntime.stopIfRunning()
        WatchLocationStreamer.stop(applicationContext, sendError = false)
        super.onDestroy()
    }

    private fun scheduleIdleStop() {
        handler.removeCallbacks(idleRunnable)
        handler.postDelayed(idleRunnable, IDLE_WATCHDOG_MILLIS)
    }

    private fun stopAfterIdle() {
        if (MappyWatchSessionHub.expireIdleSession()) {
            stopNow()
        } else {
            scheduleIdleStop()
        }
    }

    private fun stopNow() {
        HeadlessWatchRuntime.stopIfRunning()
        WatchLocationStreamer.stop(applicationContext, sendError = false)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    private fun buildNotification(): Notification {
        ensureNotificationChannel()
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Mappy")
            .setContentText("Watch session active")
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val manager = getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(CHANNEL_ID) != null) {
            return
        }
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Mappy watch session",
                NotificationManager.IMPORTANCE_LOW
            )
        )
    }

    companion object {
        private const val ACTION_START = "com.leapwardkoex.mappy.WATCH_SESSION_START"
        private const val ACTION_NOTE_ACTIVITY = "com.leapwardkoex.mappy.WATCH_SESSION_NOTE_ACTIVITY"
        private const val ACTION_STOP_AFTER_GRACE = "com.leapwardkoex.mappy.WATCH_SESSION_STOP_AFTER_GRACE"
        private const val ACTION_STOP_AFTER_DISCONNECT = "com.leapwardkoex.mappy.WATCH_SESSION_STOP_AFTER_DISCONNECT"
        private const val CHANNEL_ID = "mappy_watch_session"
        private const val NOTIFICATION_ID = 2601
        private const val STOP_GRACE_MILLIS = 20_000L
        private const val DISCONNECT_GRACE_MILLIS = 30_000L
        private const val IDLE_WATCHDOG_MILLIS = 10 * 60_000L

        @Volatile
        var isActive: Boolean = false
            private set

        @Volatile
        private var lastStartError: String? = null

        fun startSession(context: Context) {
            val intent = Intent(context, WatchSessionForegroundService::class.java)
                .setAction(ACTION_START)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (error: RuntimeException) {
                isActive = false
                lastStartError = error.localizedMessage ?: "Watch session service could not start."
            }
        }

        fun noteActivity(context: Context) {
            if (!isActive) {
                return
            }
            val intent = Intent(context, WatchSessionForegroundService::class.java)
                .setAction(ACTION_NOTE_ACTIVITY)
            try {
                context.startService(intent)
            } catch (error: RuntimeException) {
                isActive = false
                lastStartError = error.localizedMessage ?: "Watch session service could not refresh."
            }
        }

        fun stopSessionAfterGrace(context: Context) {
            val intent = Intent(context, WatchSessionForegroundService::class.java)
                .setAction(ACTION_STOP_AFTER_GRACE)
            try {
                context.startService(intent)
            } catch (error: RuntimeException) {
                isActive = false
                lastStartError = error.localizedMessage ?: "Watch session service could not stop cleanly."
            }
        }

        fun stopSessionAfterDisconnect(context: Context) {
            val intent = Intent(context, WatchSessionForegroundService::class.java)
                .setAction(ACTION_STOP_AFTER_DISCONNECT)
            try {
                context.startService(intent)
            } catch (error: RuntimeException) {
                isActive = false
                lastStartError = error.localizedMessage ?: "Watch session service could not stop cleanly."
            }
        }

        fun lastStartError(): String? = lastStartError
    }
}
