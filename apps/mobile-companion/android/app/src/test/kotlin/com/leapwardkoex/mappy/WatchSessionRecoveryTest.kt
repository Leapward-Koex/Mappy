package com.leapwardkoex.mappy

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class WatchSessionRecoveryTest {
    private class Fixture {
        var active = true
        var gpsRequested = false
        var stops = 0
        var fixesDelivered = 0
        var now = 0L
        val tasks = linkedMapOf<Runnable, Long>()
        val recovery = WatchSessionRecovery(
            schedule = { task, delay -> tasks[task] = now + delay },
            cancel = { tasks.remove(it) },
            isSessionActive = { active },
            resumeGps = { gpsRequested = true },
            stopSession = {
                gpsRequested = false
                stops++
            }
        )

        fun advance(millis: Long) {
            now += millis
            tasks.filterValues { it <= now }.keys.toList().forEach {
                tasks.remove(it)
                it.run()
            }
        }

        fun locationFix() {
            if (gpsRequested) fixesDelivered++
        }
    }

    @Test
    fun reconnectBeforeGraceExpiresKeepsDeliveringLocationFixes() {
        val f = Fixture()
        f.recovery.resume()
        f.active = false
        f.recovery.stopAfter(30_000)
        f.advance(10_000)
        f.active = true
        f.recovery.resume()
        f.locationFix()
        f.advance(30_000)
        f.locationFix()
        assertTrue(f.gpsRequested)
        assertEquals(2, f.fixesDelivered)
        assertEquals(0, f.stops)
        assertTrue(f.tasks.isEmpty())
    }

    @Test
    fun reconnectAfterShutdownRequestsGpsAgainWithoutPhoneUiOrInit() {
        val f = Fixture()
        f.recovery.resume()
        f.active = false
        f.recovery.stopAfter(30_000)
        f.advance(30_000)
        assertFalse(f.gpsRequested)
        assertEquals(1, f.stops)
        f.active = true
        f.recovery.resume()
        f.locationFix()
        f.advance(4_000)
        f.locationFix()
        assertTrue(f.gpsRequested)
        assertEquals(2, f.fixesDelivered)
    }

    @Test
    fun lateAcknowledgementAfterCloseDoesNotCancelShutdown() {
        val f = Fixture()
        f.recovery.resume()
        f.active = false
        f.recovery.stopAfter(20_000)
        f.advance(5_000)
        f.recovery.resume()
        f.advance(15_000)
        assertFalse(f.gpsRequested)
        assertEquals(1, f.stops)
    }

    @Test
    fun reconnectProtectsAgainstStopAlreadyQueuedForDispatch() {
        val f = Fixture()
        f.active = false
        f.recovery.stopAfter(30_000)
        val obsoleteStop = f.tasks.keys.single()
        f.active = true
        f.recovery.resume()
        f.active = false
        f.recovery.stopAfter(20_000)
        obsoleteStop.run()
        assertEquals(0, f.stops)
        f.advance(20_000)
        assertEquals(1, f.stops)
    }

    @Test
    fun activeSessionAtDeadlineSurvivesDelayedResumeIntent() {
        val f = Fixture()
        f.active = false
        f.recovery.stopAfter(30_000)
        f.active = true
        f.advance(30_000)
        assertEquals(0, f.stops)
        assertTrue(f.gpsRequested)
    }

    @Test
    fun destroyedServiceCancelsItsPendingStop() {
        val f = Fixture()
        f.active = false
        f.recovery.stopAfter(20_000)
        val obsoleteStop = f.tasks.keys.single()
        f.recovery.cancelPendingStop()
        obsoleteStop.run()
        f.advance(30_000)
        assertEquals(0, f.stops)
    }
}