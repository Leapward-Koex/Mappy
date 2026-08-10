package com.leapwardkoex.mappy

import android.content.Context
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

    fun noteAppOpened(context: Context, uuid: UUID) {
        if (uuid != watchAppUuid) {
            noteDifferentAppOpened(context)
            return
        }
        HeadlessWatchRuntime.startIfNeeded(context.applicationContext)
        val target = synchronized(lock) {
            activeWatchAppUuids.add(uuid)
            receiver
        }
        WatchSessionForegroundService.startSession(context.applicationContext)
        WatchSessionForegroundService.noteActivity(context.applicationContext)
        target?.onWatchConnected()
    }

    private fun noteDifferentAppOpened(context: Context) {
        val target = synchronized(lock) {
            activeWatchAppUuids.remove(watchAppUuid)
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
            receiver
        }
        target?.onWatchDisconnected()
        WatchSessionForegroundService.stopSessionAfterGrace(context.applicationContext)
    }

    fun expireIdleSession(): Boolean {
        val target = synchronized(lock) { receiver }
        val status = (target as? WatchAppMessageBridge)?.status()
        val hasBridgeWork =
            (status?.get("queueLength") as? Number ?: 0).toInt() > 0 ||
                status?.get("inFlight") == true
        if (hasBridgeWork) {
            return false
        }
        val shouldNotify = synchronized(lock) {
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
        WatchSessionForegroundService.noteActivity(context.applicationContext)
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
}
