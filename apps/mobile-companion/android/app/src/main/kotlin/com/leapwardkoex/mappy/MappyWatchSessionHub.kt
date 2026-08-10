package com.leapwardkoex.mappy

import android.content.Context
import android.os.SystemClock
import io.rebble.pebblekit2.common.model.PebbleDictionaryItem
import io.rebble.pebblekit2.common.model.ReceiveResult
import java.util.UUID

internal object MappyWatchSessionHub {
    val watchAppUuid: UUID = WATCH_APP_UUID

    private val lock = Any()
    private var receiver: PebbleTransportReceiver? = null
    private var registeredUuid: UUID? = null
    private var nextInboundTransactionId = 1
    private val activeWatchAppUuids = linkedSetOf<UUID>()
    private var lastSuccessfulActivityElapsed = 0L

    fun register(uuid: UUID, receiver: PebbleTransportReceiver) {
        synchronized(lock) {
            registeredUuid = uuid
            this.receiver = receiver
        }
    }

    fun unregister(receiver: PebbleTransportReceiver? = null) {
        synchronized(lock) {
            if (receiver == null || this.receiver === receiver) {
                this.receiver = null
                registeredUuid = null
            }
        }
    }

    fun hasReceiver(): Boolean =
        synchronized(lock) {
            receiver != null
        }

    fun isWatchAppActive(uuid: UUID): Boolean =
        synchronized(lock) {
            activeWatchAppUuids.contains(uuid)
        }

    fun isWatchConnected(uuid: UUID): Boolean =
        synchronized(lock) {
            uuid == watchAppUuid && activeWatchAppUuids.contains(uuid) &&
                lastSuccessfulActivityElapsed > 0L &&
                SystemClock.elapsedRealtime() - lastSuccessfulActivityElapsed < SESSION_STALE_MILLIS
        }

    fun noteSuccessfulActivity(context: Context) {
        synchronized(lock) {
            lastSuccessfulActivityElapsed = SystemClock.elapsedRealtime()
        }
        WatchSessionForegroundService.noteActivity(context.applicationContext)
    }

    fun noteAppOpened(context: Context, uuid: UUID) {
        if (uuid != watchAppUuid) {
            noteDifferentAppOpened(context)
            return
        }
        MappyWatchRuntime.get(context.applicationContext)
        val target = synchronized(lock) {
            activeWatchAppUuids.add(uuid)
            lastSuccessfulActivityElapsed = SystemClock.elapsedRealtime()
            receiver
        }
        if (WatchSessionForegroundService.isActive) {
            WatchSessionForegroundService.noteActivity(context.applicationContext)
        } else {
            WatchSessionForegroundService.startSession(context.applicationContext)
        }
        target?.onWatchConnected()
    }

    private fun noteDifferentAppOpened(context: Context) {
        val target = synchronized(lock) {
            activeWatchAppUuids.remove(watchAppUuid)
            lastSuccessfulActivityElapsed = 0L
            receiver
        }
        target?.onWatchDisconnected()
        WatchSessionForegroundService.stopSessionAfterDisconnect(context.applicationContext)
    }

    fun noteAppClosed(context: Context, uuid: UUID) {
        if (uuid != watchAppUuid) {
            return
        }
        val target = synchronized(lock) {
            activeWatchAppUuids.remove(uuid)
            lastSuccessfulActivityElapsed = 0L
            receiver
        }
        target?.onWatchDisconnected()
        WatchSessionForegroundService.stopSessionAfterGrace(context.applicationContext)
    }

    fun expireIdleSession(): Boolean {
        val target = synchronized(lock) { receiver }
        val status = (target as? WatchAppMessageBridge)?.status()
        if (status?.get("inFlight") == true) {
            return false
        }
        val shouldNotify = synchronized(lock) {
            if (lastSuccessfulActivityElapsed > 0L &&
                SystemClock.elapsedRealtime() - lastSuccessfulActivityElapsed < SESSION_STALE_MILLIS
            ) {
                return false
            }
            activeWatchAppUuids.remove(watchAppUuid)
        }
        if (shouldNotify) {
            target?.onWatchDisconnected()
        }
        return true
    }

    fun handleMessage(
        context: Context,
        uuid: UUID,
        data: Map<UInt, PebbleDictionaryItem>
    ): ReceiveResult {
        if (uuid != watchAppUuid) {
            return ReceiveResult.Nack
        }
        noteAppOpened(context, uuid)
        noteSuccessfulActivity(context.applicationContext)
        val target: PebbleTransportReceiver
        val transactionId: Int
        synchronized(lock) {
            if (registeredUuid != uuid || receiver == null) {
                return ReceiveResult.Nack
            }
            target = receiver ?: return ReceiveResult.Nack
            transactionId = nextInboundTransactionId
            nextInboundTransactionId = if (nextInboundTransactionId >= 255) 1 else nextInboundTransactionId + 1
        }
        return try {
            target.onWatchData(transactionId, PebbleKit2AppMessageCodec.decode(data))
            ReceiveResult.Ack
        } catch (_: Exception) {
            ReceiveResult.Nack
        }
    }

    private const val SESSION_STALE_MILLIS = 2 * 60_000L
}
