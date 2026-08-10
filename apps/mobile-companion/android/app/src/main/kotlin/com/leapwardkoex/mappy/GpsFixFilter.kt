package com.leapwardkoex.mappy

import kotlin.math.PI
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

internal data class GpsFixCandidate(
    val latitude: Double,
    val longitude: Double,
    val provider: String?,
    val wallTimeMillis: Long,
    val elapsedRealtimeNanos: Long,
    val accuracyMeters: Float?
) {
    val isGps: Boolean
        get() = provider == GPS_PROVIDER

    val hasMonotonicTime: Boolean
        get() = elapsedRealtimeNanos > 0L

    companion object {
        const val GPS_PROVIDER = "gps"
    }
}

internal object GpsFixFilter {
    fun isFresh(candidate: GpsFixCandidate, nowMillis: Long, staleThresholdMillis: Long): Boolean =
        nowMillis - candidate.wallTimeMillis <= staleThresholdMillis

    fun shouldAccept(
        candidate: GpsFixCandidate,
        previous: GpsFixCandidate?,
        nowMillis: Long,
        staleThresholdMillis: Long
    ): Boolean {
        if (!isFresh(candidate, nowMillis, staleThresholdMillis)) {
            return false
        }
        if (previous == null) {
            return true
        }
        if (isOutOfOrder(candidate, previous)) {
            return false
        }
        val previousAgeMillis = nowMillis - previous.wallTimeMillis
        if (
            previous.isGps &&
            !candidate.isGps &&
            previousAgeMillis in 0..RECENT_GPS_SUPERSEDES_NETWORK_MILLIS
        ) {
            return false
        }

        val distanceMeters = distanceMeters(previous, candidate)
        if (isImplausibleNonGpsJump(candidate, previous, distanceMeters)) {
            return false
        }
        if (isLargeAccuracyRegression(candidate, previous, distanceMeters)) {
            return false
        }
        return true
    }

    private fun isOutOfOrder(candidate: GpsFixCandidate, previous: GpsFixCandidate): Boolean =
        candidate.hasMonotonicTime &&
            previous.hasMonotonicTime &&
            candidate.elapsedRealtimeNanos <= previous.elapsedRealtimeNanos

    private fun isImplausibleNonGpsJump(
        candidate: GpsFixCandidate,
        previous: GpsFixCandidate,
        distanceMeters: Double
    ): Boolean {
        if (candidate.isGps || distanceMeters < IMPLAUSIBLE_JUMP_MIN_DISTANCE_METERS) {
            return false
        }
        if (!candidate.hasMonotonicTime || !previous.hasMonotonicTime) {
            return false
        }
        val elapsedSeconds =
            (candidate.elapsedRealtimeNanos - previous.elapsedRealtimeNanos) / 1_000_000_000.0
        if (elapsedSeconds <= 0.0) {
            return false
        }
        return distanceMeters / elapsedSeconds > MAX_NON_GPS_SPEED_METERS_PER_SECOND
    }

    private fun isLargeAccuracyRegression(
        candidate: GpsFixCandidate,
        previous: GpsFixCandidate,
        distanceMeters: Double
    ): Boolean {
        val candidateAccuracy = candidate.accuracyMeters?.toDouble() ?: return false
        val previousAccuracy = previous.accuracyMeters?.toDouble() ?: return false
        val significantDistance = maxOf(
            ACCURACY_REGRESSION_MIN_DISTANCE_METERS,
            previousAccuracy * 2.0
        )
        val significantAccuracyRegression = maxOf(
            previousAccuracy * ACCURACY_REGRESSION_FACTOR,
            previousAccuracy + ACCURACY_REGRESSION_MIN_DELTA_METERS
        )
        return distanceMeters > significantDistance &&
            candidateAccuracy > significantAccuracyRegression
    }

    private fun distanceMeters(a: GpsFixCandidate, b: GpsFixCandidate): Double {
        val lat1 = a.latitude.toRadians()
        val lat2 = b.latitude.toRadians()
        val dLat = (b.latitude - a.latitude).toRadians()
        val dLng = (b.longitude - a.longitude).toRadians()
        val h = sin(dLat / 2.0) * sin(dLat / 2.0) +
            cos(lat1) * cos(lat2) * sin(dLng / 2.0) * sin(dLng / 2.0)
        return 2.0 * EARTH_RADIUS_METERS * atan2(sqrt(h), sqrt(1.0 - h))
    }

    private fun Double.toRadians(): Double = this * PI / 180.0

    private const val EARTH_RADIUS_METERS = 6_371_000.0
    private const val RECENT_GPS_SUPERSEDES_NETWORK_MILLIS = 15_000L
    private const val IMPLAUSIBLE_JUMP_MIN_DISTANCE_METERS = 50.0
    private const val MAX_NON_GPS_SPEED_METERS_PER_SECOND = 60.0
    private const val ACCURACY_REGRESSION_FACTOR = 2.5
    private const val ACCURACY_REGRESSION_MIN_DELTA_METERS = 20.0
    private const val ACCURACY_REGRESSION_MIN_DISTANCE_METERS = 25.0
}
