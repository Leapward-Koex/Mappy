package com.leapwardkoex.mappy

import kotlin.test.Test
import kotlin.test.assertEquals

class BridgeStatusEmissionGateTest {
    @Test
    fun firstRequestEmitsImmediately() {
        val fixture = Fixture()

        fixture.gate.request()

        assertEquals(listOf(0), fixture.emittedQueueLengths())
        assertEquals(0, fixture.scheduled.size)
    }

    @Test
    fun burstSchedulesOneTrailingEmissionWithLatestState() {
        val fixture = Fixture()
        fixture.gate.request()
        fixture.now = 10L
        fixture.queueLength = 1

        repeat(100) { fixture.gate.request() }

        assertEquals(1, fixture.scheduled.size)
        fixture.queueLength = 4
        fixture.inFlight = true
        fixture.runThrough(250L)
        assertEquals(listOf(0, 4), fixture.emittedQueueLengths())
    }

    @Test
    fun timestampOnlyChangesAreDeduplicated() {
        val fixture = Fixture()
        fixture.gate.request()

        fixture.now = 250L
        fixture.gate.request()
        assertEquals(1, fixture.emitted.size)

        fixture.now = 500L
        fixture.queueLength = 2
        fixture.gate.request()
        assertEquals(listOf(0, 2), fixture.emittedQueueLengths())
    }

    @Test
    fun resetCancelsPendingWorkAndAllowsForcedInitialSnapshot() {
        val fixture = Fixture()
        fixture.gate.request()
        fixture.now = 10L
        fixture.queueLength = 3
        fixture.gate.request()

        fixture.gate.reset()
        fixture.runThrough(250L)
        assertEquals(listOf(0), fixture.emittedQueueLengths())

        fixture.gate.request(force = true)
        assertEquals(listOf(0, 3), fixture.emittedQueueLengths())
    }

    @Test
    fun slowPayloadEvaluationDoesNotAllowAnImmediateFollowup() {
        val fixture = Fixture()
        fixture.payloadDurationMillis = 300L
        fixture.gate.request()
        fixture.queueLength = 1

        fixture.gate.request()

        assertEquals(listOf(0), fixture.emittedQueueLengths())
        assertEquals(1, fixture.scheduled.size)
    }

    private class Fixture {
        var now = 0L
        var queueLength = 0
        var inFlight = false
        var payloadDurationMillis = 0L
        val emitted = mutableListOf<Map<String, Any?>>()
        val scheduled = mutableListOf<Scheduled>()
        val gate = BridgeStatusEmissionGate(
            intervalMillis = 250L,
            nowMillis = { now },
            schedule = { runnable, delayMillis ->
                scheduled += Scheduled(now + delayMillis, runnable)
            },
            cancel = { runnable -> scheduled.removeAll { it.runnable === runnable } },
            payloadSupplier = {
                val payload = linkedMapOf(
                    "event" to "bridgeStatus",
                    "timestampMillis" to now,
                    "queueLength" to queueLength,
                    "inFlight" to inFlight
                )
                now += payloadDurationMillis
                payload
            },
            emitter = emitted::add
        )

        fun runThrough(targetMillis: Long) {
            while (true) {
                val next = scheduled.minByOrNull { it.atMillis } ?: break
                if (next.atMillis > targetMillis) break
                scheduled.remove(next)
                now = next.atMillis
                next.runnable.run()
            }
            now = targetMillis
        }

        fun emittedQueueLengths(): List<Int> =
            emitted.map { (it["queueLength"] as Number).toInt() }
    }

    private data class Scheduled(val atMillis: Long, val runnable: Runnable)
}
