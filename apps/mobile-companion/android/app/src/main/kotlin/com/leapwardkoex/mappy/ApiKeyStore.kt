package com.leapwardkoex.mappy

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class ApiKeyStore(private val context: Context) : GoogleCredentialStore {
    private val preferences = context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    override fun storeApiKey(plaintext: String): Map<String, Any?> =
        synchronized(STORAGE_LOCK) {
            storeApiKey(plaintext, seededDevelopmentKey = false)
        }

    fun storeSeededDevelopmentApiKey(plaintext: String): Map<String, Any?> =
        synchronized(STORAGE_LOCK) {
            storeApiKey(plaintext, seededDevelopmentKey = true)
        }

    fun hasSeededDevelopmentKeyMarker(): Boolean =
        synchronized(STORAGE_LOCK) {
            preferences.getBoolean(KEY_SEEDED_DEVELOPMENT_KEY, false)
        }

    fun isSeededDevelopmentApiKey(expectedPlaintext: String): Boolean =
        synchronized(STORAGE_LOCK) {
            preferences.getBoolean(KEY_SEEDED_DEVELOPMENT_KEY, false) &&
                getPlaintextKey() == expectedPlaintext
        }

    private fun storeApiKey(plaintext: String, seededDevelopmentKey: Boolean): Map<String, Any?> {
        val trimmed = plaintext.trim()
        val rejection = validateInput(trimmed)
        if (rejection != null) {
            val configured = getPlaintextKey() != null
            return status(
                configured = configured,
                validationState = rejection,
                validationDetail = if (configured) {
                    "Replacement rejected; existing credential retained"
                } else {
                    "Rejected before storage"
                }
            )
        }

        val previousPreferences = preferenceSnapshot()
        val stagedAlias = freshManagedKeyAlias()
        var preferenceCommitStarted = false
        try {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.ENCRYPT_MODE, generateSecretKey(stagedAlias))
            val plaintextBytes = trimmed.toByteArray(StandardCharsets.UTF_8)
            val ciphertext = try {
                cipher.doFinal(plaintextBytes)
            } finally {
                plaintextBytes.fill(0)
            }
            val now = System.currentTimeMillis()

            // The old preference record and its key remain usable until this single
            // commit atomically switches every field to the staged key.
            preferenceCommitStarted = true
            check(
                preferences.edit()
                    .putString(KEY_CIPHERTEXT, Base64.encodeToString(ciphertext, Base64.NO_WRAP))
                    .putString(KEY_IV, Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
                    .putString(KEY_KEY_ALIAS, stagedAlias)
                    .putString(KEY_PREVIEW, redactedPreview(trimmed))
                    .putInt(KEY_LENGTH, trimmed.length)
                    .putBoolean(KEY_SEEDED_DEVELOPMENT_KEY, seededDevelopmentKey)
                    .putLong(KEY_UPDATED_AT, now)
                    .putString(KEY_VALIDATION_STATE, STATE_NOT_VALIDATED)
                    .remove(KEY_VALIDATION_DETAIL)
                    .remove(KEY_VALIDATION_HTTP_STATUS)
                    .remove(KEY_VALIDATION_UPDATED_AT)
                    .remove(KEY_PACKAGE_NAME)
                    .remove(KEY_CERT_SHA1)
                    .commit()
            ) {
                "Unable to persist encrypted credential storage."
            }
        } catch (exception: Exception) {
            if (preferenceCommitStarted) {
                // SharedPreferences updates its in-memory map before disk I/O. Restore
                // the prior snapshot if commit fails so callers can still use the old key.
                try {
                    restorePreferenceSnapshot(previousPreferences)
                } catch (_: Exception) {
                    // The prior durable record and its key have not been retired.
                }
            }
            deleteKeyAliasBestEffort(stagedAlias)
            throw exception
        }

        // Only after the new record is durable is it safe to retire the previous key.
        deleteRetiredManagedAliasesBestEffort(activeAlias = stagedAlias)
        return getStatus()
    }

    override fun clearApiKey(): Map<String, Any?> =
        synchronized(STORAGE_LOCK) {
            // Delete keys first so stale copies of any credential record are unusable.
            // All managed aliases are attempted even if one deletion fails.
            val keyDeletionFailure = deleteAllManagedAliases()
            check(preferences.edit().clear().commit()) {
                "Unable to clear encrypted credential storage."
            }
            if (keyDeletionFailure != null) {
                throw IllegalStateException(
                    "Unable to remove all encrypted credential keys.",
                    keyDeletionFailure
                )
            }
            getStatus()
        }

    override fun getPlaintextKey(): String? =
        synchronized(STORAGE_LOCK) {
            try {
                val ciphertext = preferences.getString(KEY_CIPHERTEXT, null)
                val iv = preferences.getString(KEY_IV, null)

                if (ciphertext == null && iv == null) {
                    if (preferences.all.isNotEmpty()) {
                        recoverFromUnreadableCredential()
                    }
                    return@synchronized null
                }
                if (ciphertext == null || iv == null) {
                    recoverFromUnreadableCredential()
                    return@synchronized null
                }

                val storedAlias = preferences.getString(KEY_KEY_ALIAS, null)
                val keyAlias = when {
                    storedAlias == null -> LEGACY_KEY_ALIAS
                    isManagedKeyAlias(storedAlias) -> storedAlias
                    else -> {
                        // Never use an alias supplied through mutable preference data
                        // unless it belongs to this store's strict namespace.
                        recoverFromUnreadableCredential()
                        return@synchronized null
                    }
                }

                // Decryption must never create a new key. Missing/inaccessible key
                // material means the ciphertext is orphaned and must be discarded.
                val key = existingSecretKey(keyAlias)
                if (key == null) {
                    recoverFromUnreadableCredential()
                    return@synchronized null
                }

                val cipher = Cipher.getInstance(TRANSFORMATION)
                cipher.init(
                    Cipher.DECRYPT_MODE,
                    key,
                    GCMParameterSpec(GCM_TAG_BITS, Base64.decode(iv, Base64.NO_WRAP))
                )
                val plaintextBytes = cipher.doFinal(Base64.decode(ciphertext, Base64.NO_WRAP))
                val plaintext = try {
                    String(plaintextBytes, StandardCharsets.UTF_8)
                } finally {
                    plaintextBytes.fill(0)
                }

                if (storedAlias == null) {
                    // Records written before alias versioning used the fixed legacy alias.
                    // Persist the resolved alias only after authenticated decryption.
                    try {
                        preferences.edit().putString(KEY_KEY_ALIAS, LEGACY_KEY_ALIAS).commit()
                    } catch (_: Exception) {
                        // Migration is opportunistic; the legacy record remains readable.
                    }
                }
                plaintext
            } catch (_: Exception) {
                recoverFromUnreadableCredential()
                null
            }
        }

    override fun getStatus(): Map<String, Any?> =
        synchronized(STORAGE_LOCK) {
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
        }

    override fun clearValidationStatus(): Map<String, Any?> =
        synchronized(STORAGE_LOCK) {
            if (!preferences.contains(KEY_CIPHERTEXT)) {
                return@synchronized getStatus()
            }

            preferences.edit()
                .putString(KEY_VALIDATION_STATE, STATE_NOT_VALIDATED)
                .remove(KEY_VALIDATION_DETAIL)
                .remove(KEY_VALIDATION_HTTP_STATUS)
                .remove(KEY_VALIDATION_UPDATED_AT)
                .apply()
            getStatus()
        }

    override fun markValidationResult(
        validationState: String,
        validationDetail: String?,
        httpStatus: Int?,
        packageName: String,
        certSha1: String
    ): Map<String, Any?> =
        synchronized(STORAGE_LOCK) {
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
            getStatus()
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

    private fun existingSecretKey(alias: String): SecretKey? {
        require(isManagedKeyAlias(alias)) { "Unrecognized encrypted credential key alias." }
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        return (keyStore.getEntry(alias, null) as? KeyStore.SecretKeyEntry)?.secretKey
    }

    private fun generateSecretKey(alias: String): SecretKey {
        require(isVersionedKeyAlias(alias)) { "New encrypted credentials require a versioned alias." }
        val keyGenerator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        keyGenerator.init(
            KeyGenParameterSpec.Builder(
                alias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(KEY_SIZE_BITS)
                .setRandomizedEncryptionRequired(true)
                .setUserAuthenticationRequired(false)
                .build()
        )
        return keyGenerator.generateKey()
    }

    private fun freshManagedKeyAlias(): String {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        repeat(KEY_ALIAS_GENERATION_ATTEMPTS) {
            val alias = VERSIONED_KEY_ALIAS_PREFIX + UUID.randomUUID().toString().replace("-", "")
            if (!keyStore.containsAlias(alias)) {
                return alias
            }
        }
        throw IllegalStateException("Unable to allocate an encrypted credential key alias.")
    }

    private fun preferenceSnapshot(): Map<String, Any?> =
        preferences.all.mapValues { (_, value) ->
            if (value is Set<*>) value.filterIsInstance<String>().toSet() else value
        }

    private fun restorePreferenceSnapshot(snapshot: Map<String, Any?>) {
        val editor = preferences.edit().clear()
        snapshot.forEach { (key, value) ->
            when (value) {
                is Boolean -> editor.putBoolean(key, value)
                is Float -> editor.putFloat(key, value)
                is Int -> editor.putInt(key, value)
                is Long -> editor.putLong(key, value)
                is String -> editor.putString(key, value)
                is Set<*> -> editor.putStringSet(key, value.filterIsInstance<String>().toSet())
            }
        }
        // commit() restores both the in-memory view and durable snapshot before the
        // replacement failure is returned to the caller.
        editor.commit()
    }

    private fun deleteKeyAliasBestEffort(alias: String) {
        if (!isManagedKeyAlias(alias)) return
        try {
            val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
            if (keyStore.containsAlias(alias)) {
                keyStore.deleteEntry(alias)
            }
        } catch (_: Exception) {
            // A later successful rotation, recovery, or explicit clear retries cleanup.
        }
    }

    private fun deleteRetiredManagedAliasesBestEffort(activeAlias: String) {
        try {
            val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
            managedAliases(keyStore)
                .filterNot { it == activeAlias }
                .forEach { alias ->
                    try {
                        keyStore.deleteEntry(alias)
                    } catch (_: Exception) {
                        // The active record is already durable; cleanup can be retried later.
                    }
                }
        } catch (_: Exception) {
            // The active record must remain available even if retired-key cleanup fails.
        }
    }

    private fun deleteAllManagedAliases(): Exception? {
        val keyStore = try {
            KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        } catch (exception: Exception) {
            return exception
        }

        val aliases = try {
            managedAliases(keyStore)
        } catch (exception: Exception) {
            return exception
        }

        var firstFailure: Exception? = null
        aliases.forEach { alias ->
            try {
                keyStore.deleteEntry(alias)
            } catch (exception: Exception) {
                if (firstFailure == null) {
                    firstFailure = exception
                }
            }
        }
        return firstFailure
    }

    private fun managedAliases(keyStore: KeyStore): List<String> {
        val result = mutableListOf<String>()
        val aliases = keyStore.aliases()
        while (aliases.hasMoreElements()) {
            val alias = aliases.nextElement()
            if (isManagedKeyAlias(alias)) {
                result += alias
            }
        }
        return result
    }

    private fun isManagedKeyAlias(alias: String): Boolean =
        alias == LEGACY_KEY_ALIAS || isVersionedKeyAlias(alias)

    private fun isVersionedKeyAlias(alias: String): Boolean =
        VERSIONED_KEY_ALIAS_PATTERN.matches(alias)

    private fun recoverFromUnreadableCredential() {
        // Recovery must not turn corrupt local state into an app crash. Both cleanup
        // operations are attempted independently so one failure cannot prevent the other.
        deleteAllManagedAliases()
        try {
            preferences.edit().clear().commit()
        } catch (_: Exception) {
            // A later read will retry recovery if the platform could not clear storage.
        }
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
        private const val KEY_ALIAS_GENERATION_ATTEMPTS = 4
        private const val KEY_SIZE_BITS = 256
        private const val LEGACY_KEY_ALIAS = "mappy_google_api_key"
        private const val PREFERENCES_NAME = "mappy_api_key_store"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val VERSIONED_KEY_ALIAS_PREFIX = "mappy_google_api_key_v2_"
        private val VERSIONED_KEY_ALIAS_PATTERN =
            Regex("mappy_google_api_key_v2_[0-9a-f]{32}")
        private val STORAGE_LOCK = Any()

        private const val KEY_CERT_SHA1 = "cert_sha1"
        private const val KEY_CIPHERTEXT = "ciphertext"
        private const val KEY_IV = "iv"
        private const val KEY_KEY_ALIAS = "key_alias"
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
