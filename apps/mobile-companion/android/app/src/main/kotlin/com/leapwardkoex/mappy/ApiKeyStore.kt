package com.leapwardkoex.mappy

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class ApiKeyStore(private val context: Context) : GoogleCredentialStore {
    private val preferences = context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    override fun storeApiKey(plaintext: String): Map<String, Any?> =
        storeApiKey(plaintext, seededDevelopmentKey = false)

    fun storeSeededDevelopmentApiKey(plaintext: String): Map<String, Any?> =
        storeApiKey(plaintext, seededDevelopmentKey = true)

    fun hasSeededDevelopmentKeyMarker(): Boolean =
        preferences.getBoolean(KEY_SEEDED_DEVELOPMENT_KEY, false)

    fun isSeededDevelopmentApiKey(expectedPlaintext: String): Boolean =
        hasSeededDevelopmentKeyMarker() && getPlaintextKey() == expectedPlaintext

    private fun storeApiKey(plaintext: String, seededDevelopmentKey: Boolean): Map<String, Any?> {
        val trimmed = plaintext.trim()
        val rejection = validateInput(trimmed)
        if (rejection != null) {
            return status(
                configured = false,
                validationState = rejection,
                validationDetail = "Rejected before storage"
            )
        }

        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val ciphertext = cipher.doFinal(trimmed.toByteArray(StandardCharsets.UTF_8))
        val now = System.currentTimeMillis()

        preferences.edit()
            .putString(KEY_CIPHERTEXT, Base64.encodeToString(ciphertext, Base64.NO_WRAP))
            .putString(KEY_IV, Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
            .putString(KEY_PREVIEW, redactedPreview(trimmed))
            .putInt(KEY_LENGTH, trimmed.length)
            .putBoolean(KEY_SEEDED_DEVELOPMENT_KEY, seededDevelopmentKey)
            .putLong(KEY_UPDATED_AT, now)
            .putString(KEY_VALIDATION_STATE, STATE_NOT_VALIDATED)
            .remove(KEY_VALIDATION_DETAIL)
            .remove(KEY_VALIDATION_HTTP_STATUS)
            .remove(KEY_VALIDATION_UPDATED_AT)
            .apply()

        return getStatus()
    }

    override fun clearApiKey(): Map<String, Any?> {
        preferences.edit().clear().apply()
        return getStatus()
    }

    override fun getPlaintextKey(): String? {
        val ciphertext = preferences.getString(KEY_CIPHERTEXT, null) ?: return null
        val iv = preferences.getString(KEY_IV, null) ?: return null

        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(
            Cipher.DECRYPT_MODE,
            secretKey(),
            GCMParameterSpec(GCM_TAG_BITS, Base64.decode(iv, Base64.NO_WRAP))
        )
        val plaintext = cipher.doFinal(Base64.decode(ciphertext, Base64.NO_WRAP))
        return String(plaintext, StandardCharsets.UTF_8)
    }

    override fun getStatus(): Map<String, Any?> =
        status(
            configured = preferences.contains(KEY_CIPHERTEXT),
            validationState = preferences.getString(KEY_VALIDATION_STATE, STATE_NOT_CONFIGURED)
                ?: STATE_NOT_CONFIGURED,
            validationDetail = preferences.getString(KEY_VALIDATION_DETAIL, null),
            httpStatus = if (preferences.contains(KEY_VALIDATION_HTTP_STATUS)) {
                preferences.getInt(KEY_VALIDATION_HTTP_STATUS, 0)
            } else {
                null
            }
        )

    override fun clearValidationStatus(): Map<String, Any?> {
        if (!preferences.contains(KEY_CIPHERTEXT)) {
            return getStatus()
        }

        preferences.edit()
            .putString(KEY_VALIDATION_STATE, STATE_NOT_VALIDATED)
            .remove(KEY_VALIDATION_DETAIL)
            .remove(KEY_VALIDATION_HTTP_STATUS)
            .remove(KEY_VALIDATION_UPDATED_AT)
            .apply()
        return getStatus()
    }

    override fun markValidationResult(
        validationState: String,
        validationDetail: String?,
        httpStatus: Int?,
        packageName: String,
        certSha1: String
    ): Map<String, Any?> {
        val editor = preferences.edit()
            .putString(KEY_VALIDATION_STATE, validationState)
            .putLong(KEY_VALIDATION_UPDATED_AT, System.currentTimeMillis())
            .putString(KEY_PACKAGE_NAME, packageName)
            .putString(KEY_CERT_SHA1, certSha1)

        if (validationDetail == null) {
            editor.remove(KEY_VALIDATION_DETAIL)
        } else {
            editor.putString(KEY_VALIDATION_DETAIL, validationDetail)
        }

        if (httpStatus == null) {
            editor.remove(KEY_VALIDATION_HTTP_STATUS)
        } else {
            editor.putInt(KEY_VALIDATION_HTTP_STATUS, httpStatus)
        }

        editor.apply()
        return getStatus()
    }

    private fun status(
        configured: Boolean,
        validationState: String,
        validationDetail: String?,
        httpStatus: Int? = null
    ): Map<String, Any?> =
        mapOf(
            "configured" to configured,
            "redactedPreview" to preferences.getString(KEY_PREVIEW, null),
            "length" to if (preferences.contains(KEY_LENGTH)) preferences.getInt(KEY_LENGTH, 0) else null,
            "updatedAtMillis" to if (preferences.contains(KEY_UPDATED_AT)) preferences.getLong(KEY_UPDATED_AT, 0L) else null,
            "validationState" to if (configured) validationState else STATE_NOT_CONFIGURED,
            "validationDetail" to validationDetail,
            "validationHttpStatus" to httpStatus,
            "validationUpdatedAtMillis" to if (preferences.contains(KEY_VALIDATION_UPDATED_AT)) {
                preferences.getLong(KEY_VALIDATION_UPDATED_AT, 0L)
            } else {
                null
            },
            "packageName" to context.packageName,
            "certSha1" to preferences.getString(KEY_CERT_SHA1, null)
        )

    private fun validateInput(value: String): String? {
        if (!hasSupportedGoogleApiKeyShape(value)) {
            return STATE_INVALID_KEY
        }
        return null
    }

    private fun redactedPreview(value: String): String {
        val prefix = value.take(6)
        val suffix = value.takeLast(4)
        return "$prefix...$suffix (${value.length})"
    }

    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        val existing = keyStore.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry
        if (existing != null) {
            return existing.secretKey
        }

        val keyGenerator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        keyGenerator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setUserAuthenticationRequired(false)
                .build()
        )
        return keyGenerator.generateKey()
    }

    companion object {
        const val STATE_API_DISABLED = "apiDisabled"
        const val STATE_INVALID_KEY = "invalidKey"
        const val STATE_NETWORK_UNAVAILABLE = "networkUnavailable"
        const val STATE_NOT_CONFIGURED = "notConfigured"
        const val STATE_NOT_VALIDATED = "notValidated"
        const val STATE_PROVIDER_PERMISSION_DENIED = "providerPermissionDenied"
        const val STATE_QUOTA_OR_BILLING = "quotaOrBillingIssue"
        const val STATE_UNSUPPORTED_RESTRICTED_KEY_BEHAVIOR = "unsupportedRestrictedKeyBehavior"
        const val STATE_VALID = "valid"
        const val STATE_VALIDATING = "validating"

        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val GCM_TAG_BITS = 128
        private const val KEY_ALIAS = "mappy_google_api_key"
        private const val PREFERENCES_NAME = "mappy_api_key_store"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"

        private const val KEY_CERT_SHA1 = "cert_sha1"
        private const val KEY_CIPHERTEXT = "ciphertext"
        private const val KEY_IV = "iv"
        private const val KEY_LENGTH = "length"
        private const val KEY_PACKAGE_NAME = "package_name"
        private const val KEY_PREVIEW = "preview"
        private const val KEY_SEEDED_DEVELOPMENT_KEY = "seeded_development_key"
        private const val KEY_UPDATED_AT = "updated_at"
        private const val KEY_VALIDATION_DETAIL = "validation_detail"
        private const val KEY_VALIDATION_HTTP_STATUS = "validation_http_status"
        private const val KEY_VALIDATION_STATE = "validation_state"
        private const val KEY_VALIDATION_UPDATED_AT = "validation_updated_at"
    }
}
