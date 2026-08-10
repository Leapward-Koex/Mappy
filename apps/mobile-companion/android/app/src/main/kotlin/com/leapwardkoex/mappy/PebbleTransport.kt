package com.leapwardkoex.mappy

import java.util.UUID

internal interface PebbleTransport {
    fun register(uuid: UUID, receiver: PebbleTransportReceiver)

    fun unregister()

    fun isWatchConnected(): Boolean

    fun isWatchAppActive(uuid: UUID): Boolean

    fun startWatchApp(uuid: UUID)

    fun stopWatchApp(uuid: UUID)

    fun send(uuid: UUID, transactionId: Int, fields: Map<String, Any?>)

    fun sendAck(transactionId: Int)

    fun sendNack(transactionId: Int)
}

internal interface PebbleTransportReceiver {
    fun onWatchData(transactionId: Int, fields: Map<String, Any?>)

    fun onWatchAck(transactionId: Int)

    fun onWatchNack(transactionId: Int)

    fun onWatchConnected()

    fun onWatchDisconnected()

    fun onWatchLaunchResult(success: Boolean) {}
}
