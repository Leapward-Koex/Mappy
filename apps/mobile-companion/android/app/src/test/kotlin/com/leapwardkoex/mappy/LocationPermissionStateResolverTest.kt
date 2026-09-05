package com.leapwardkoex.mappy

import kotlin.test.Test
import kotlin.test.assertEquals

class LocationPermissionStateResolverTest {
    @Test
    fun grantsPreserveAccuracy() {
        assertEquals(
            "precise",
            resolveForegroundLocationState(
                fineGranted = true,
                coarseGranted = true,
                wasRequested = true,
                shouldShowFineRationale = false,
                shouldShowCoarseRationale = false
            )
        )
        assertEquals(
            "approximate",
            resolveForegroundLocationState(
                fineGranted = false,
                coarseGranted = true,
                wasRequested = true,
                shouldShowFineRationale = false,
                shouldShowCoarseRationale = false
            )
        )
    }

    @Test
    fun anUnrequestedPermissionCanBeRequested() {
        assertEquals(
            "requestAvailable",
            resolveForegroundLocationState(
                fineGranted = false,
                coarseGranted = false,
                wasRequested = false,
                shouldShowFineRationale = false,
                shouldShowCoarseRationale = false
            )
        )
    }

    @Test
    fun denialRemainsRequestableWhileAndroidShowsRationale() {
        assertEquals(
            "denied",
            resolveForegroundLocationState(
                fineGranted = false,
                coarseGranted = false,
                wasRequested = true,
                shouldShowFineRationale = true,
                shouldShowCoarseRationale = false
            )
        )
    }

    @Test
    fun requestedPermissionWithoutRationaleRequiresSettings() {
        assertEquals(
            "permanentlyDenied",
            resolveForegroundLocationState(
                fineGranted = false,
                coarseGranted = false,
                wasRequested = true,
                shouldShowFineRationale = false,
                shouldShowCoarseRationale = false
            )
        )
    }
}
