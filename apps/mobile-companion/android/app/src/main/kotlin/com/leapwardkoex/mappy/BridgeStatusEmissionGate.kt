package com.leapwardkoex.mappy

internal class BridgeStatusEmissionGate(
    private val intervalMillis: Long,
    private val nowMillis: () -> Long,
    private val schedule: (Runnable, Long) -> Unit,
    private val cancel: (Runnable) -> Unit,
    private val payloadSupplier: () -> Map<String, Any?>,
    private val emitter: (Map<String, Any?>) -> Unit
) {
    private var lastEvaluationAtMillis: Long? = null
    private var lastFingerprint: Map<String, Any?>? = null
    private var emissionPending = false
    private val pendingEmission = Runnable { emitPending() }

    init {
        require(intervalMillis > 0L) { "Bridge status interval must be positive." }
    }

    fun request(force: Boolean = false) {
        val now = nowMillis()
        if (force) {
            cancelPending()
            evaluateAndEmit(force = true)
            return
        }

        val lastEvaluation = lastEvaluationAtMillis
        if (lastEvaluation == null || now - lastEvaluation >= intervalMillis) {
            cancelPending()
            evaluateAndEmit(force = false)
            return
        }

        if (!emissionPending) {
            emissionPending = true
            val delayMillis = (intervalMillis - (now - lastEvaluation)).coerceAtLeast(0L)
            schedule(pendingEmission, delayMillis)
        }
    }

    fun reset() {
        cancelPending()
        lastEvaluationAtMillis = null
        lastFingerprint = null
    }

    private fun emitPending() {
        if (!emissionPending) return
        emissionPending = false
        evaluateAndEmit(force = false)
    }

    private fun evaluateAndEmit(force: Boolean) {
        val payload = payloadSupplier()
        val fingerprint = LinkedHashMap(payload).apply { remove("timestampMillis") }
        try {
            if (force || fingerprint != lastFingerprint) {
                emitter(payload)
                lastFingerprint = fingerprint
            }
        } finally {
            lastEvaluationAtMillis = nowMillis()
        }
    }

    private fun cancelPending() {
        if (!emissionPending) return
        emissionPending = false
        cancel(pendingEmission)
    }
}
