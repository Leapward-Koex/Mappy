package com.leapwardkoex.mappy

internal class WatchCompassDiagnostics {
    var status: String? = null
        private set
    var headingUsable: Boolean = false
        private set
    var headingReference: String = "magnetic"
        private set

    fun apply(eventName: String, detail: Int?, referenceDetail: Int?) {
        when (eventName) {
            "compass_calibration_started" -> {
                status = "calibrating"
                headingUsable = false
            }
            "compass_service_unavailable" -> {
                status = "unavailable"
                headingUsable = false
            }
            "compass_heading_lost" -> {
                status = statusName(detail)
                headingUsable = false
            }
            "compass_heading_acquired" -> {
                status = statusName(detail)
                headingUsable = true
                headingReference = if (referenceDetail == 1) "true" else "magnetic"
            }
        }
    }

    fun headingSource(mapOrientation: Int): String =
        if (mapOrientation == 1 && headingUsable) "watch_compass" else "none"

    fun orientationFallback(mapOrientation: Int): String? {
        if (mapOrientation != 1 || headingUsable) {
            return null
        }
        return when (status) {
            "calibrating" -> "compass_calibrating"
            "unavailable" -> "compass_unavailable"
            "stale" -> "compass_stale"
            else -> "compass_invalid"
        }
    }

    private fun statusName(detail: Int?): String = when (detail) {
        -1 -> "unavailable"
        1 -> "calibrating"
        2 -> "calibrated"
        3 -> "stale"
        else -> "invalid"
    }
}
