package com.leapwardkoex.mappy

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.util.Base64
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

interface GoogleCredentialStore {
    fun storeApiKey(plaintext: String): Map<String, Any?>
    fun clearApiKey(): Map<String, Any?>
    fun getPlaintextKey(): String?
    fun getStatus(): Map<String, Any?>
    fun clearValidationStatus(): Map<String, Any?>
    fun markValidationResult(
        validationState: String,
        validationDetail: String?,
        httpStatus: Int?,
        packageName: String,
        certSha1: String
    ): Map<String, Any?>
}

data class AndroidIdentity(val packageName: String, val certSha1: String)

interface AndroidIdentityProvider {
    fun currentIdentity(): AndroidIdentity
}

class RuntimeAndroidIdentityProvider(private val context: Context) : AndroidIdentityProvider {
    override fun currentIdentity(): AndroidIdentity {
        val packageName = context.packageName
        val packageInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            context.packageManager.getPackageInfo(packageName, PackageManager.GET_SIGNING_CERTIFICATES)
        } else {
            @Suppress("DEPRECATION")
            context.packageManager.getPackageInfo(packageName, PackageManager.GET_SIGNATURES)
        }

        val signatureBytes = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val signers = packageInfo.signingInfo?.apkContentsSigners.orEmpty()
            val signer = signers.firstOrNull()
                ?: throw IllegalStateException("No Android signing certificate found.")
            signer.toByteArray()
        } else {
            @Suppress("DEPRECATION")
            val signatures = packageInfo.signatures.orEmpty()
            val signature = signatures.firstOrNull()
                ?: throw IllegalStateException("No Android signing certificate found.")
            signature.toByteArray()
        }
        val sha1 = sha1Hex(signatureBytes)

        return AndroidIdentity(packageName = packageName, certSha1 = sha1)
    }

    companion object {
        internal fun sha1Hex(bytes: ByteArray): String =
            MessageDigest.getInstance("SHA-1")
                .digest(bytes)
                .joinToString("") { "%02X".format(it.toInt() and 0xFF) }
    }
}

data class GoogleHttpRequest(
    val url: String,
    val method: String = "GET",
    val headers: Map<String, String> = emptyMap(),
    val body: ByteArray? = null
)

data class GoogleHttpResponse(
    val httpStatus: Int,
    val bodyText: String,
    val bodyBytes: ByteArray
)

interface GoogleHttpClient {
    fun execute(request: GoogleHttpRequest): GoogleHttpResponse
}

interface BinaryStringEncoder {
    fun encode(bytes: ByteArray): String
}

class AndroidBase64StringEncoder : BinaryStringEncoder {
    override fun encode(bytes: ByteArray): String =
        Base64.encodeToString(bytes, Base64.NO_WRAP)
}

class UrlGoogleHttpClient : GoogleHttpClient {
    override fun execute(request: GoogleHttpRequest): GoogleHttpResponse {
        val connection = (URL(request.url).openConnection() as HttpURLConnection).apply {
            connectTimeout = NETWORK_TIMEOUT_MILLIS
            readTimeout = NETWORK_TIMEOUT_MILLIS
            requestMethod = request.method
            request.headers.forEach { (key, value) ->
                setRequestProperty(key, value)
            }
            if (request.body != null) {
                doOutput = true
            }
        }

        return try {
            request.body?.let { body ->
                connection.outputStream.use { it.write(body) }
            }
            val httpStatus = connection.responseCode
            val stream = if (httpStatus in 200..299) {
                connection.inputStream
            } else {
                connection.errorStream
            }
            val bytes = stream?.use { input ->
                val output = ByteArrayOutputStream()
                input.copyTo(output)
                output.toByteArray()
            } ?: ByteArray(0)
            GoogleHttpResponse(
                httpStatus = httpStatus,
                bodyText = bytes.toString(Charsets.UTF_8),
                bodyBytes = bytes
            )
        } finally {
            connection.disconnect()
        }
    }

    private companion object {
        private const val NETWORK_TIMEOUT_MILLIS = 10_000
    }
}
