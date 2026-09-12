package com.leapwardkoex.mappy

/** Main-thread session recovery, independent of the phone Activity lifecycle. */
internal class WatchSessionRecovery(
    private val schedule: (Runnable, Long) -> Unit,
    private val cancel: (Runnable) -> Unit,
    private val isSessionActive: () -> Boolean,
    private val resumeGps: () -> Unit,
    private val stopSession: () -> Unit
) {
    private var pendingStop: Runnable? = null

    fun resume() {
        // A late send ACK after the watch app closes must not revive its session.
        if (!isSessionActive()) return
        cancelPendingStop()
        // Explicitly request GPS again: a prior stop clears the streamer's request flag.
        resumeGps()
    }

    fun stopAfter(delayMillis: Long) {
        cancelPendingStop()
        val task = object : Runnable {
            override fun run() {
                if (pendingStop !== this) return
                pendingStop = null
                if (isSessionActive()) {
                    resumeGps()
                } else {
                    stopSession()
                }
            }
        }
        pendingStop = task
        schedule(task, delayMillis)
    }

    fun cancelPendingStop() {
        pendingStop?.let(cancel)
        pendingStop = null
    }
}