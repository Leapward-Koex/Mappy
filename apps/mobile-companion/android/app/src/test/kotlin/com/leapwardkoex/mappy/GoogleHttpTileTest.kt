package com.leapwardkoex.mappy

import java.io.ByteArrayInputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class GoogleHttpTileTest {
    @Test fun successfulTileImagesRemainBinaryButErrorsRetainText() {
        val bytes = byteArrayOf(0xFF.toByte(), 0x00, 0x80.toByte())
        val binary = UrlGoogleHttpClient { ResponseConnection(200, bytes) }
            .execute(GoogleHttpRequest("https://example.test/tile", expectsBinary = true))
        assertContentEquals(bytes, binary.bodyBytes)
        assertEquals("", binary.bodyText)
        val errorText = "Provider rejected the tile"
        val error = UrlGoogleHttpClient { ResponseConnection(403, errorText.toByteArray()) }
            .execute(GoogleHttpRequest("https://example.test/tile", expectsBinary = true))
        assertEquals(errorText, error.bodyText)
        val normal = UrlGoogleHttpClient { ResponseConnection(200, "session".toByteArray()) }
            .execute(GoogleHttpRequest("https://example.test/session"))
        assertEquals("session", normal.bodyText)
    }

    @Test fun cancellingOneSourceDisconnectsOnlyItsOwnConnection() {
        val first = BlockingConnection()
        val second = BlockingConnection()
        val client = UrlGoogleHttpClient { url -> if (url.path == "/first") first else second }
        val firstToken = TileCancellationToken()
        val secondToken = TileCancellationToken()
        val firstError = AtomicReference<Throwable>()
        val secondError = AtomicReference<Throwable>()
        val worker1 = thread {
            runCatching { client.execute(GoogleHttpRequest("https://example.test/first"), { false }, firstToken) }
                .exceptionOrNull()?.let(firstError::set)
        }
        val worker2 = thread {
            runCatching { client.execute(GoogleHttpRequest("https://example.test/second"), { false }, secondToken) }
                .exceptionOrNull()?.let(secondError::set)
        }
        try {
            assertTrue(first.started.await(5, TimeUnit.SECONDS))
            assertTrue(second.started.await(5, TimeUnit.SECONDS))
            firstToken.cancel()
            worker1.join(5_000)
            assertFalse(worker1.isAlive)
            assertTrue(firstError.get() is ProviderOperationCancelledException)
            assertEquals(1L, second.disconnected.count)
            assertEquals(null, secondError.get())
        } finally {
            secondToken.cancel()
            worker2.join(5_000)
        }
        assertFalse(worker2.isAlive)
        assertTrue(secondError.get() is ProviderOperationCancelledException)
    }

    private class ResponseConnection(private val status: Int, private val bytes: ByteArray) :
        HttpURLConnection(URL("https://example.test")) {
        override fun getResponseCode() = status
        override fun getInputStream() = ByteArrayInputStream(bytes)
        override fun getErrorStream() = ByteArrayInputStream(bytes)
        override fun disconnect() = Unit
        override fun usingProxy() = false
        override fun connect() = Unit
    }

    private class BlockingConnection : HttpURLConnection(URL("https://example.test")) {
        val started = CountDownLatch(1)
        val disconnected = CountDownLatch(1)
        override fun getResponseCode(): Int {
            started.countDown()
            check(disconnected.await(5, TimeUnit.SECONDS))
            throw IOException("Connection disconnected")
        }
        override fun disconnect() { disconnected.countDown() }
        override fun usingProxy() = false
        override fun connect() = Unit
    }
}
