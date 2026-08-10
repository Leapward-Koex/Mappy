package com.leapwardkoex.mappy

import io.rebble.pebblekit2.client.BasePebbleListenerService
import io.rebble.pebblekit2.common.model.PebbleDictionaryItem
import io.rebble.pebblekit2.common.model.ReceiveResult
import io.rebble.pebblekit2.common.model.WatchIdentifier
import java.util.UUID

class MappyPebbleListenerService : BasePebbleListenerService() {
    override suspend fun onMessageReceived(
        watchappUUID: UUID,
        data: Map<UInt, PebbleDictionaryItem>,
        watch: WatchIdentifier
    ): ReceiveResult =
        MappyWatchSessionHub.handleMessage(this, watchappUUID, data)

    override fun onAppOpened(watchappUUID: UUID, watch: WatchIdentifier) {
        MappyWatchSessionHub.noteAppOpened(this, watchappUUID)
    }

    override fun onAppClosed(watchappUUID: UUID, watch: WatchIdentifier) {
        MappyWatchSessionHub.noteAppClosed(this, watchappUUID)
    }
}
