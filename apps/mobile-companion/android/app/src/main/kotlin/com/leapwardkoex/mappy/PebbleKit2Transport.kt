package com.leapwardkoex.mappy

import android.content.Context
import io.rebble.pebblekit2.client.DefaultPebbleSender
import io.rebble.pebblekit2.common.model.TransmissionResult
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

internal class PebbleKit2Transport(
    context: Context
) : PebbleTransport {
    private val appContext = context.applicationContext
    private val sender = DefaultPebbleSender(appContext)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
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

    override fun isWatchConnected(): Boolean =
        registeredUuid?.let(MappyWatchSessionHub::isWatchConnected) == true

    override fun isWatchAppActive(uuid: UUID): Boolean =
        MappyWatchSessionHub.isWatchAppActive(uuid)

    override fun startWatchApp(uuid: UUID) {
        scope.launch {
            val success = runCatching { sender.startAppOnTheWatch(uuid, null) }
                .getOrNull().hasSuccess()
            receiver?.onWatchLaunchResult(success)
        }
    }

    override fun stopWatchApp(uuid: UUID) {
        scope.launch {
            runCatching {
                sender.stopAppOnTheWatch(uuid, null)
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
        scope.launch {
            val success = runCatching {
                sender.sendDataToPebble(uuid, dictionary, null)
            }.getOrNull().hasSuccess()
            val target = receiver ?: return@launch
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
