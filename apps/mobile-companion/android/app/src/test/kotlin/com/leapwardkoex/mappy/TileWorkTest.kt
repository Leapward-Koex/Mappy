package com.leapwardkoex.mappy

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class TileWorkTest {
    @Test fun cancelledOwnerStillCompletesForLiveFollower() {
        val jobs = SharedTileJobs<String, Int>()
        val ownerToken = TileCancellationToken()
        val owner = jobs.acquire("source", ownerToken)
        val follower = jobs.acquire("source", TileCancellationToken())
        ownerToken.cancel()
        assertFalse(owner.cancellation.isCancelled)
        owner.runIfOwner { 42 }
        assertEquals(42, follower.await())
        assertFailsWith<ProviderOperationCancelledException> { owner.await() }
        owner.close()
        follower.close()
    }

    @Test fun lastConsumerCancelsAndOldCompletionCannotDeleteReplacement() {
        val jobs = SharedTileJobs<String, Int>()
        val oldToken = TileCancellationToken()
        val old = jobs.acquire("tile", oldToken)
        oldToken.cancel()
        assertTrue(old.cancellation.isCancelled)
        val replacement = jobs.acquire("tile", TileCancellationToken())
        assertTrue(replacement.isOwner)
        old.runIfOwner { error("Cancelled task ran") }
        val follower = jobs.acquire("tile", TileCancellationToken())
        assertFalse(follower.isOwner)
        replacement.runIfOwner { 7 }
        assertEquals(7, follower.await())
        replacement.close()
        follower.close()
    }

    @Test fun failureCompletesEveryWaiterAndNextRequestRetries() {
        val jobs = SharedTileJobs<String, Int>()
        val first = jobs.acquire("tile", TileCancellationToken())
        val follower = jobs.acquire("tile", TileCancellationToken())
        first.runIfOwner { error("decode failed") }
        assertFailsWith<IllegalStateException> { first.await() }
        assertFailsWith<IllegalStateException> { follower.await() }
        first.close()
        follower.close()
        jobs.acquire("tile", TileCancellationToken()).use { retry ->
            assertTrue(retry.isOwner)
            retry.runIfOwner { 8 }
            assertEquals(8, retry.await())
        }
    }

    @Test fun clearCancelsOldGenerationWithoutAffectingNewWork() {
        val jobs = SharedTileJobs<String, Int>()
        val old = jobs.acquire("same-key", TileCancellationToken())
        jobs.cancelAll()
        val current = jobs.acquire("same-key", TileCancellationToken())
        old.runIfOwner { 1 }
        assertFailsWith<ProviderOperationCancelledException> { old.await() }
        current.runIfOwner { 2 }
        assertEquals(2, current.await())
        old.close()
        current.close()
    }

    @Test fun pixelCacheUsesByteBudgetAndEvictionLeavesActiveArraysIntact() {
        val cache = SourcePixelCache(16)
        val first = SourceTilePixels(2, 1, intArrayOf(11, 12))
        cache.put("first", first)
        cache.put("second", SourceTilePixels(2, 1, intArrayOf(21, 22)))
        assertEquals(first, cache.get("first"))
        cache.put("third", SourceTilePixels(2, 1, intArrayOf(31, 32)))
        assertNull(cache.get("second"))
        assertEquals(16L, cache.byteCount())
        cache.put("oversized", SourceTilePixels(5, 1, IntArray(5)))
        assertNull(cache.get("oversized"))
        cache.clear()
        assertEquals(0L, cache.byteCount())
        assertContentEquals(intArrayOf(11, 12), first.pixels)
    }

    @Test fun cancellationListenersAreScopedAndCalledOnce() {
        val token = TileCancellationToken()
        var calls = 0
        token.register { calls += 100 }.close()
        token.register { calls++ }
        token.cancel()
        token.cancel()
        token.register { calls++ }
        assertEquals(2, calls)
    }
}
