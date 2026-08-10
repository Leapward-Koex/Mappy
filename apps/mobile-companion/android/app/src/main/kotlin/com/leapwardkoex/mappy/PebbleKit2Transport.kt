package com.leapwardkoex.mappy

import android.content.Context
import io.rebble.pebblekit2.client.DefaultPebbleSender
import io.rebble.pebblekit2.common.model.TransmissionResult
import java.util.UUID
import kotlin.concurrent.thread
import kotlinx.coroutines.runBlocking

internal class PebbleKit2Transport(
    context: Context
) : PebbleTransport {
    private val appContext = context.applicationContext
    private val sender = DefaultPebbleSender(appContext)
    @Volatile
    private var receiver: PebbleTransportReceiver? = null
    @Volatile
    private var registeredUuid: UUID? = null

    override fun register(uuid: UUID, receiver: PebbleTransportReceiver) {
        registeredUuid = uuid
        this.receiver = receiver
        MappyWatchSessionHub.register(uuid, receiver)
    }

    override fun unregister() {
        MappyWatchSessionHub.unregister(receiver)
        receiver = null
        registeredUuid = null
    }

    override fun isWatchConnected(): Boolean = registeredUuid != null

    override fun isWatchAppActive(uuid: UUID): Boolean =
        MappyWatchSessionHub.isWatchAppActive(uuid)

    override fun startWatchApp(uuid: UUID) {
        thread(name = "mappy-pebble-start-watch", isDaemon = true) {
            runCatching {
                runBlocking { sender.startAppOnTheWatch(uuid, null) }
            }.onSuccess { result ->
                if (result.hasSuccess()) {
                    MappyWatchSessionHub.noteAppOpened(appContext, uuid)
                }
            }
        }
    }

    override fun stopWatchApp(uuid: UUID) {
        thread(name = "mappy-pebble-stop-watch", isDaemon = true) {
            runCatching {
                runBlocking { sender.stopAppOnTheWatch(uuid, null) }
            }.onSuccess {
                MappyWatchSessionHub.noteAppClosed(appContext, uuid)
            }
        }
    }

    override fun send(uuid: UUID, transactionId: Int, fields: Map<String, Any?>) {
        val dictionary = PebbleKit2AppMessageCodec.encode(fields)
        if (dictionary.isEmpty()) {
            throw IllegalArgumentException("Pebble AppMessage dictionary has no known keys.")
        }
        thread(name = "mappy-pebble-send-$transactionId", isDaemon = true) {
            val success = runCatching {
                runBlocking { sender.sendDataToPebble(uuid, dictionary, null) }
            }.getOrNull().hasSuccess()
            val target = receiver ?: return@thread
            if (success) {
                target.onWatchAck(transactionId)
            } else {
                target.onWatchNack(transactionId)
            }
        }
    }

    override fun sendAck(transactionId: Int) {
        // PebbleKit Android 2 receives ACK/NACK through BasePebbleListenerService
        // return values, so no separate broadcast is needed here.
    }

    override fun sendNack(transactionId: Int) {
        // See sendAck.
    }

    private fun Map<*, *>?.hasSuccess(): Boolean =
        this?.values?.any { it == TransmissionResult.Success } == true
}
