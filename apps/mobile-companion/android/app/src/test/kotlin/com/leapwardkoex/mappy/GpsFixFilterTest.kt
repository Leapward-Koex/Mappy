package com.leapwardkoex.mappy

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class GpsFixFilterTest {
    @Test
    fun rejectsStaleFix() {
        val nowMillis = 120_000L

        assertFalse(
            GpsFixFilter.shouldAccept(
                candidate(wallTimeMillis = 50_000L),
                previous = null,
                nowMillis = nowMillis,
                staleThresholdMillis = 60_000L
            )
        )
    }

    @Test
    fun rejectsOutOfOrderMonotonicFix() {
        val previous = candidate(wallTimeMillis = 100_000L, elapsedRealtimeNanos = 200_000_000_000L)
        val older = candidate(wallTimeMillis = 101_000L, elapsedRealtimeNanos = 199_000_000_000L)

        assertFalse(
            GpsFixFilter.shouldAccept(
                older,
                previous,
                nowMillis = 101_000L,
                staleThresholdMillis = 60_000L
            )
        )
    }

    @Test
    fun recentGpsSupersedesNetworkFix() {
        val previous = candidate(provider = "gps", wallTimeMillis = 100_000L)
        val network = candidate(
            provider = "network",
            wallTimeMillis = 105_000L,
            elapsedRealtimeNanos = 105_000_000_000L
        )

        assertFalse(
            GpsFixFilter.shouldAccept(
                network,
                previous,
                nowMillis = 105_000L,
                staleThresholdMillis = 60_000L
            )
        )
    }

    @Test
    fun acceptsNewerGpsFix() {
        val previous = candidate(latitude = -36.8500, wallTimeMillis = 100_000L)
        val next = candidate(
            latitude = -36.8501,
            wallTimeMillis = 102_000L,
            elapsedRealtimeNanos = 102_000_000_000L
        )

        assertTrue(
            GpsFixFilter.shouldAccept(
                next,
                previous,
                nowMillis = 102_000L,
                staleThresholdMillis = 60_000L
            )
        )
    }

    @Test
    fun rejectsImplausibleNonGpsJump() {
        val previous = candidate(
            provider = "gps",
            wallTimeMillis = 100_000L,
            elapsedRealtimeNanos = 100_000_000_000L
        )
        val networkJump = candidate(
            latitude = 0.01,
            provider = "network",
            wallTimeMillis = 120_000L,
            elapsedRealtimeNanos = 110_000_000_000L
        )

        assertFalse(
            GpsFixFilter.shouldAccept(
                networkJump,
                previous,
                nowMillis = 120_000L,
                staleThresholdMillis = 60_000L
            )
        )
    }

    @Test
    fun rejectsLargeAccuracyRegression() {
        val previous = candidate(accuracyMeters = 5f, wallTimeMillis = 100_000L)
        val poorFix = candidate(
            latitude = 0.001,
            accuracyMeters = 100f,
            wallTimeMillis = 102_000L,
            elapsedRealtimeNanos = 102_000_000_000L
        )

        assertFalse(
            GpsFixFilter.shouldAccept(
                poorFix,
                previous,
                nowMillis = 102_000L,
                staleThresholdMillis = 60_000L
            )
        )
    }

    private fun candidate(
        latitude: Double = 0.0,
        longitude: Double = 0.0,
        provider: String = "gps",
        wallTimeMillis: Long = 100_000L,
        elapsedRealtimeNanos: Long = 100_000_000_000L,
        accuracyMeters: Float? = 5f
    ): GpsFixCandidate =
        GpsFixCandidate(
            latitude = latitude,
            longitude = longitude,
            provider = provider,
            wallTimeMillis = wallTimeMillis,
            elapsedRealtimeNanos = elapsedRealtimeNanos,
            accuracyMeters = accuracyMeters
        )
}
