package com.leapwardkoex.mappy

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class TilePipelineTest {
    private class Credentials : GoogleCredentialStore {
        @Volatile var key: String? = "test-key"
        @Volatile var state = ApiKeyStore.STATE_VALID
        override fun storeApiKey(plaintext: String): Map<String, Any?> { key = plaintext; state = ApiKeyStore.STATE_VALID; return getStatus() }
        override fun clearApiKey(): Map<String, Any?> { key = null; state = ApiKeyStore.STATE_NOT_CONFIGURED; return getStatus() }
        override fun getPlaintextKey() = key
        override fun getStatus(): Map<String, Any?> = mapOf("configured" to (key != null), "validationState" to state)
        override fun clearValidationStatus(): Map<String, Any?> { state = ApiKeyStore.STATE_NOT_VALIDATED; return getStatus() }
        override fun markValidationResult(validationState: String, validationDetail: String?, httpStatus: Int?, packageName: String, certSha1: String): Map<String, Any?> {
            state = validationState
            return getStatus()
        }
    }

    private class Http(private val tile: (GoogleHttpRequest) -> GoogleHttpResponse = { response("pixels") }) : GoogleHttpClient {
        val sessions = AtomicInteger()
        val tiles = AtomicInteger()
        override fun execute(request: GoogleHttpRequest): GoogleHttpResponse = if (request.url.contains("createSession")) {
            response("""{"tileWidth":256,"tileHeight":256,"session":"session-${sessions.incrementAndGet()}"}""")
        } else {
            tiles.incrementAndGet()
            tile(request)
        }
    }

    private class Decoder(private val beforeDecode: () -> Unit = {}) : SourceTileDecoder {
        val calls = AtomicInteger()
        val recycled = AtomicInteger()
        override fun decode(bytes: ByteArray): SourceTileRaster {
            calls.incrementAndGet()
            beforeDecode()
            return object : SourceTileRaster {
                override val width = 256
                override val height = 256
                override fun getPixel(x: Int, y: Int): Int = error("The crop should use bulk pixels")
                override fun readPixels() = IntArray(width * height) { 0xFFE5E6DF.toInt() }
                override fun recycle() { recycled.incrementAndGet() }
            }
        }
    }

    private fun provider(http: GoogleHttpClient, decoder: SourceTileDecoder, credentials: Credentials = Credentials()) =
        GoogleMapTilesProvider(credentials, object : AndroidIdentityProvider {
            override fun currentIdentity() = AndroidIdentity("test.package", "test-cert")
        }, http, sourceTileDecoder = decoder)

    @Test fun adjacentCropsReuseDownloadedAndBulkDecodedPixels() {
        val http = Http()
        val decoder = Decoder()
        val provider = provider(http, decoder)
        try {
            assertEquals(true, provider.watchTile(54, 63, 16)["ok"])
            val next = provider.watchTile(108, 63, 16)
            assertEquals(true, next["ok"])
            assertEquals(1, http.tiles.get())
            assertEquals(1, decoder.calls.get())
            assertEquals(1, decoder.recycled.get())
            val metrics = next["preparation_metrics"] as Map<*, *>
            assertEquals(1, metrics["sourcePixelCacheHits"])
            assertEquals("encodedCache", provider.watchTile(108, 63, 16)["tile_source"])
        } finally { provider.close() }
    }

    @Test fun boundarySourcesOverlapAndGlobalConcurrencyIsFour() {
        val firstFourStarted = CountDownLatch(4)
        val release = CountDownLatch(1)
        val active = AtomicInteger()
        val maximum = AtomicInteger()
        val http = Http {
            val count = active.incrementAndGet()
            maximum.accumulateAndGet(count, ::maxOf)
            firstFourStarted.countDown()
            try {
                check(release.await(5, TimeUnit.SECONDS))
                response("pixels")
            } finally { active.decrementAndGet() }
        }
        val provider = provider(http, Decoder())
        val results = List(2) { AtomicReference<Map<String, Any?>>() }
        val errors = List(2) { AtomicReference<Throwable>() }
        val workers = (0..1).map { index -> thread {
            try { results[index].set(provider.watchTile(240 + index * 1024, 240, 16)) }
            catch (error: Throwable) { errors[index].set(error) }
        } }
        try {
            assertTrue(firstFourStarted.await(5, TimeUnit.SECONDS), "Boundary tiles were fetched serially")
            assertEquals(4, active.get())
            release.countDown()
            workers.forEach { it.join(5_000); assertFalse(it.isAlive) }
            errors.forEach { assertEquals(null, it.get()) }
            results.forEach { assertEquals(true, it.get()["ok"]) }
            assertEquals(8, http.tiles.get())
            assertEquals(4, maximum.get())
        } finally { release.countDown(); provider.close() }
    }

    @Test fun overlappingDistinctCropsShareOneSourceJob() {
        val decoding = CountDownLatch(1)
        val release = CountDownLatch(1)
        val decoder = Decoder { decoding.countDown(); check(release.await(5, TimeUnit.SECONDS)) }
        val http = Http()
        val provider = provider(http, decoder)
        val first = AtomicReference<Map<String, Any?>>()
        val second = AtomicReference<Map<String, Any?>>()
        val worker1 = thread { first.set(provider.watchTile(54, 63, 16)) }
        assertTrue(decoding.await(5, TimeUnit.SECONDS))
        val worker2 = thread { second.set(provider.watchTile(108, 63, 16)) }
        try {
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
            while (worker2.state != Thread.State.TIMED_WAITING && System.nanoTime() < deadline) Thread.yield()
            assertEquals(Thread.State.TIMED_WAITING, worker2.state)
            release.countDown()
            worker1.join(5_000); worker2.join(5_000)
            assertFalse(worker1.isAlive); assertFalse(worker2.isAlive)
            assertEquals(true, first.get()["ok"])
            assertEquals(true, second.get()["ok"])
            assertEquals(1, http.tiles.get())
            assertEquals(1, decoder.calls.get())
            assertEquals(1, (second.get()["preparation_metrics"] as Map<*, *>)["sharedSourceHits"])
        } finally { release.countDown(); provider.close() }
    }

    @Test fun concurrentExpiredSourcesRenewSessionOnce() {
        val expiredRequests = CountDownLatch(4)
        val http = Http { request ->
            if (request.url.contains("session=session-1&")) {
                expiredRequests.countDown()
                check(expiredRequests.await(5, TimeUnit.SECONDS))
                response("expired", 403)
            } else response("pixels")
        }
        val provider = provider(http, Decoder())
        try {
            assertEquals(true, provider.watchTile(240, 240, 16)["ok"])
            assertEquals(2, http.sessions.get())
            assertEquals(8, http.tiles.get())
        } finally { provider.close() }
    }

    @Test fun clearingCredentialsDuringDecodeCannotPublishRetiredPixels() {
        val decoding = CountDownLatch(1)
        val release = CountDownLatch(1)
        val decoder = Decoder { decoding.countDown(); check(release.await(5, TimeUnit.SECONDS)) }
        val credentials = Credentials()
        val http = Http()
        val provider = provider(http, decoder, credentials)
        val error = AtomicReference<Throwable>()
        val worker = thread { runCatching { provider.watchTile(54, 63, 16) }.exceptionOrNull()?.let(error::set) }
        try {
            assertTrue(decoding.await(5, TimeUnit.SECONDS))
            provider.mutateCredentialState { credentials.clearApiKey() }
            release.countDown()
            worker.join(5_000)
            assertFalse(worker.isAlive)
            assertTrue(error.get() is ProviderOperationCancelledException)
            assertEquals(ApiKeyStore.STATE_NOT_CONFIGURED, credentials.state)
            provider.mutateCredentialState { credentials.storeApiKey("replacement-key") }
            assertEquals(true, provider.watchTile(54, 63, 16)["ok"])
            assertEquals(2, http.tiles.get())
            assertEquals(2, decoder.calls.get())
        } finally { release.countDown(); provider.close() }
    }

    @Test fun decodeFailureEvictsBadBytesAndCanRetry() {
        val calls = AtomicInteger()
        val delegate = Decoder()
        val decoder = object : SourceTileDecoder {
            override fun decode(bytes: ByteArray): SourceTileRaster? =
                if (calls.incrementAndGet() == 1) null else delegate.decode(bytes)
        }
        val http = Http()
        val provider = provider(http, decoder)
        try {
            assertEquals(false, provider.watchTile(54, 63, 16)["ok"])
            assertEquals(true, provider.watchTile(54, 63, 16)["ok"])
            assertEquals(2, http.tiles.get())
        } finally { provider.close() }
    }

    @Test fun cancellingOnlySessionConsumerDisconnectsCreationWithoutValidationFailure() {
        val http = SessionHttp()
        val credentials = Credentials()
        val provider = provider(http, Decoder(), credentials)
        val token = TileCancellationToken()
        val failure = AtomicReference<Throwable>()
        val worker = thread {
            runCatching { provider.watchTile(54, 63, 16, token) }.exceptionOrNull()?.let(failure::set)
        }
        try {
            assertTrue(http.started.await(5, TimeUnit.SECONDS))
            token.cancel()
            worker.join(5_000)
            assertFalse(worker.isAlive)
            assertTrue(http.cancelled.await(1, TimeUnit.SECONDS))
            assertTrue(failure.get() is ProviderOperationCancelledException)
            assertEquals(ApiKeyStore.STATE_VALID, credentials.state)
        } finally { http.release.countDown(); provider.close() }
    }

    @Test fun cancelledSessionOwnerDoesNotAbortAnotherCropSessionConsumer() {
        val http = SessionHttp()
        val provider = provider(http, Decoder())
        val firstToken = TileCancellationToken()
        val firstError = AtomicReference<Throwable>()
        val secondResult = AtomicReference<Map<String, Any?>>()
        val first = thread {
            runCatching { provider.watchTile(54, 63, 16, firstToken) }.exceptionOrNull()?.let(firstError::set)
        }
        assertTrue(http.started.await(5, TimeUnit.SECONDS))
        val second = thread { secondResult.set(provider.watchTile(108, 63, 16)) }
        try {
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
            while (second.state != Thread.State.TIMED_WAITING && System.nanoTime() < deadline) Thread.yield()
            assertEquals(Thread.State.TIMED_WAITING, second.state)
            firstToken.cancel()
            assertEquals(1L, http.cancelled.count)
            http.release.countDown()
            first.join(5_000); second.join(5_000)
            assertFalse(first.isAlive); assertFalse(second.isAlive)
            assertTrue(firstError.get() is ProviderOperationCancelledException)
            assertEquals(true, secondResult.get()["ok"])
            assertEquals(1, http.sessions.get())
        } finally { http.release.countDown(); provider.close() }
    }

    private class SessionHttp : GoogleHttpClient {
        val started = CountDownLatch(1)
        val release = CountDownLatch(1)
        val cancelled = CountDownLatch(1)
        val sessions = AtomicInteger()

        override fun execute(request: GoogleHttpRequest): GoogleHttpResponse = execute(request, { false }, null)

        override fun execute(request: GoogleHttpRequest, isCancelled: () -> Boolean,
            cancellation: TileCancellationToken?): GoogleHttpResponse {
            if (!request.url.contains("createSession")) return response("pixels")
            sessions.incrementAndGet()
            val registration = cancellation?.register { cancelled.countDown(); release.countDown() }
            try {
                started.countDown()
                check(release.await(5, TimeUnit.SECONDS))
                if (isCancelled()) throw ProviderOperationCancelledException()
                cancellation?.throwIfCancelled()
                return response("""{"tileWidth":256,"tileHeight":256,"session":"leased-session"}""")
            } finally { registration?.close() }
        }
    }

    private companion object {
        fun response(text: String, status: Int = 200) = GoogleHttpResponse(status, text, text.toByteArray())
    }
}
