package com.leapwardkoex.mappy

internal fun resolveForegroundLocationState(
    fineGranted: Boolean,
    coarseGranted: Boolean,
    wasRequested: Boolean,
    shouldShowFineRationale: Boolean,
    shouldShowCoarseRationale: Boolean
): String = when {
    fineGranted -> "precise"
    coarseGranted -> "approximate"
    !wasRequested -> "requestAvailable"
    !shouldShowFineRationale && !shouldShowCoarseRationale -> "permanentlyDenied"
    else -> "denied"
}
