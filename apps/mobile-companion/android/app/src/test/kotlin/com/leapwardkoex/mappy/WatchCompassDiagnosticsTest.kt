package com.leapwardkoex.mappy

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class WatchCompassDiagnosticsTest {
    @Test
    fun headingSourceRequiresForwardUpAndAcquiredHeading() {
        val state = WatchCompassDiagnostics()
        assertEquals("none", state.headingSource(1))
        assertEquals("compass_invalid", state.orientationFallback(1))

        state.apply("compass_heading_acquired", 2, 0)
        assertEquals("calibrated", state.status)
        assertEquals("magnetic", state.headingReference)
        assertEquals("watch_compass", state.headingSource(1))
        assertEquals("none", state.headingSource(0))
        assertNull(state.orientationFallback(1))
    }

    @Test
    fun semanticTransitionsExposeActualFallback() {
        val state = WatchCompassDiagnostics()
        state.apply("compass_calibration_started", 1, 0)
        assertEquals("compass_calibrating", state.orientationFallback(1))

        state.apply("compass_service_unavailable", -1, 0)
        assertEquals("compass_unavailable", state.orientationFallback(1))

        state.apply("compass_heading_lost", 3, 0)
        assertEquals("compass_stale", state.orientationFallback(1))

        state.apply("compass_heading_acquired", 2, 1)
        assertEquals("true", state.headingReference)
        assertNull(state.orientationFallback(1))
    }
}
