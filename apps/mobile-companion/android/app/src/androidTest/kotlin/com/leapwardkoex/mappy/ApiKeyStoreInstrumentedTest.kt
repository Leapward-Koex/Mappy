package com.leapwardkoex.mappy

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.nio.charset.StandardCharsets
import java.security.GeneralSecurityException
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ApiKeyStoreInstrumentedTest {
    private lateinit var context: Context
    private lateinit var store: ApiKeyStore

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        clearFixture()
        store = ApiKeyStore(context.applicationContext)
    }

    @After
    fun tearDown() {
        clearFixture()
    }

    @Test
    fun testStoresOnlyCiphertextAndUsesAes256VersionedKey() {
        val plaintext = fakeApiKey('A')

        val status = store.storeApiKey(plaintext)
        val storedValues = preferences().all
        val activeAlias = requireNotNull(preferences().getString(KEY_KEY_ALIAS, null))

        assertEquals(true, status["configured"])
        assertTrue(VERSIONED_KEY_ALIAS_PATTERN.matches(activeAlias))
        assertNotNull(storedValues[KEY_CIPHERTEXT])
        assertNotNull(storedValues[KEY_IV])
        assertFalse(storedValues.values.any { value -> value == plaintext })
        assertFalse(storedValues.toString().contains(plaintext))
        assertEquals(plaintext, store.getPlaintextKey())

        val secretKey = requireNotNull(loadSecretKey(activeAlias))
        val keyFactory = SecretKeyFactory.getInstance(secretKey.algorithm, ANDROID_KEYSTORE)
        val keyInfo = keyFactory.getKeySpec(secretKey, KeyInfo::class.java) as KeyInfo
        assertEquals(256, keyInfo.keySize)
    }

    @Test
    fun testClearSynchronouslyRemovesAllManagedAliasesOnly() {
        store.storeApiKey(fakeApiKey('B'))
        val activeAlias = activeAlias()
        val retiredAlias = VERSIONED_KEY_ALIAS_PREFIX + "0".repeat(32)
        generateTestKey(retiredAlias)
        generateTestKey(LEGACY_KEY_ALIAS)
        generateTestKey(UNRELATED_KEY_ALIAS)
        assertEquals(setOf(activeAlias, retiredAlias, LEGACY_KEY_ALIAS), managedAliases())

        val status = store.clearApiKey()

        assertEquals(false, status["configured"])
        assertTrue(preferences().all.isEmpty())
        assertTrue(managedAliases().isEmpty())
        assertTrue(keyStore().containsAlias(UNRELATED_KEY_ALIAS))
    }

    @Test
    fun testCorruptCiphertextRecoversAndRemovesAllManagedAliases() {
        store.storeApiKey(fakeApiKey('C'))
        generateTestKey(VERSIONED_KEY_ALIAS_PREFIX + "1".repeat(32))
        assertTrue(
            preferences().edit()
                .putString(KEY_CIPHERTEXT, "not-valid-base64")
                .commit()
        )

        assertNull(store.getPlaintextKey())
        assertEquals(false, store.getStatus()["configured"])
        assertTrue(preferences().all.isEmpty())
        assertTrue(managedAliases().isEmpty())
    }

    @Test
    fun testMissingIvRecoversToNotConfigured() {
        store.storeApiKey(fakeApiKey('D'))
        assertTrue(preferences().edit().remove(KEY_IV).commit())

        assertNull(store.getPlaintextKey())
        assertEquals(false, store.getStatus()["configured"])
        assertTrue(preferences().all.isEmpty())
        assertTrue(managedAliases().isEmpty())
    }

    @Test
    fun testOrphanedCiphertextRecoversToNotConfigured() {
        store.storeApiKey(fakeApiKey('E'))
        keyStore().deleteEntry(activeAlias())
        assertNotNull(preferences().getString(KEY_CIPHERTEXT, null))

        assertNull(store.getPlaintextKey())
        assertEquals(false, store.getStatus()["configured"])
        assertTrue(preferences().all.isEmpty())
        assertTrue(managedAliases().isEmpty())
    }

    @Test
    fun testReplacementCommitsNewAliasBeforeRetiringOldKey() {
        val firstPlaintext = fakeApiKey('F')
        store.storeApiKey(firstPlaintext)
        val firstAlias = activeAlias()
        val oldCiphertext = preferences().getString(KEY_CIPHERTEXT, null)
        val oldIv = preferences().getString(KEY_IV, null)
        assertTrue(keyStore().containsAlias(firstAlias))

        val replacementPlaintext = fakeApiKey('G')
        store.storeApiKey(replacementPlaintext)
        val replacementAlias = activeAlias()

        assertNotEquals(firstAlias, replacementAlias)
        assertTrue(keyStore().containsAlias(replacementAlias))
        assertFalse(keyStore().containsAlias(firstAlias))
        assertEquals(setOf(replacementAlias), managedAliases())
        assertEquals(replacementPlaintext, store.getPlaintextKey())

        val currentKey = requireNotNull(loadSecretKey(replacementAlias))
        var oldCiphertextDecrypted = false
        try {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(
                Cipher.DECRYPT_MODE,
                currentKey,
                GCMParameterSpec(
                    GCM_TAG_BITS,
                    Base64.decode(requireNotNull(oldIv), Base64.NO_WRAP)
                )
            )
            cipher.doFinal(Base64.decode(requireNotNull(oldCiphertext), Base64.NO_WRAP))
            oldCiphertextDecrypted = true
        } catch (_: GeneralSecurityException) {
            // Expected: the committed replacement uses independent key material.
        }
        assertFalse(oldCiphertextDecrypted)
    }

    @Test
    fun testLegacyRecordWithoutAliasIsReadAndMigrated() {
        val plaintext = fakeApiKey('H')
        val legacyKey = generateTestKey(LEGACY_KEY_ALIAS)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, legacyKey)
        val plaintextBytes = plaintext.toByteArray(StandardCharsets.UTF_8)
        val ciphertext = try {
            cipher.doFinal(plaintextBytes)
        } finally {
            plaintextBytes.fill(0)
        }
        assertTrue(
            preferences().edit()
                .putString(KEY_CIPHERTEXT, Base64.encodeToString(ciphertext, Base64.NO_WRAP))
                .putString(KEY_IV, Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
                .commit()
        )
        assertFalse(preferences().contains(KEY_KEY_ALIAS))

        assertEquals(plaintext, store.getPlaintextKey())
        assertEquals(LEGACY_KEY_ALIAS, preferences().getString(KEY_KEY_ALIAS, null))
        assertTrue(keyStore().containsAlias(LEGACY_KEY_ALIAS))
    }

    @Test
    fun testInvalidReplacementRetainsExistingCredentialAndRecord() {
        val plaintext = fakeApiKey('I')
        store.storeApiKey(plaintext)
        val originalAlias = activeAlias()
        val originalPreferences = preferences().all.toMap()

        val status = store.storeApiKey("invalid replacement")

        assertEquals(true, status["configured"])
        assertEquals(ApiKeyStore.STATE_INVALID_KEY, status["validationState"])
        assertEquals(
            "Replacement rejected; existing credential retained",
            status["validationDetail"]
        )
        assertEquals(originalPreferences, preferences().all)
        assertEquals(originalAlias, activeAlias())
        assertTrue(keyStore().containsAlias(originalAlias))
        assertEquals(plaintext, store.getPlaintextKey())
    }

    @Test
    fun testUntrustedPreferenceAliasIsNeverUsedOrDeleted() {
        store.storeApiKey(fakeApiKey('J'))
        generateTestKey(UNRELATED_KEY_ALIAS)
        assertTrue(
            preferences().edit()
                .putString(KEY_KEY_ALIAS, UNRELATED_KEY_ALIAS)
                .commit()
        )

        assertNull(store.getPlaintextKey())
        assertTrue(preferences().all.isEmpty())
        assertTrue(managedAliases().isEmpty())
        assertTrue(keyStore().containsAlias(UNRELATED_KEY_ALIAS))
    }

    private fun preferences() =
        context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    private fun keyStore(): KeyStore =
        KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }

    private fun activeAlias(): String =
        requireNotNull(preferences().getString(KEY_KEY_ALIAS, null))

    private fun loadSecretKey(alias: String): SecretKey? =
        (keyStore().getEntry(alias, null) as? KeyStore.SecretKeyEntry)?.secretKey

    private fun generateTestKey(alias: String): SecretKey {
        val keyGenerator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        keyGenerator.init(
            KeyGenParameterSpec.Builder(
                alias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return keyGenerator.generateKey()
    }

    private fun managedAliases(): Set<String> {
        val result = mutableSetOf<String>()
        val aliases = keyStore().aliases()
        while (aliases.hasMoreElements()) {
            val alias = aliases.nextElement()
            if (alias == LEGACY_KEY_ALIAS || VERSIONED_KEY_ALIAS_PATTERN.matches(alias)) {
                result += alias
            }
        }
        return result
    }

    private fun clearFixture() {
        context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
            .edit()
            .clear()
            .commit()
        val store = keyStore()
        val aliases = mutableListOf<String>()
        val enumeration = store.aliases()
        while (enumeration.hasMoreElements()) {
            aliases += enumeration.nextElement()
        }
        aliases
            .filter { alias ->
                alias == LEGACY_KEY_ALIAS ||
                    alias == UNRELATED_KEY_ALIAS ||
                    VERSIONED_KEY_ALIAS_PATTERN.matches(alias)
            }
            .forEach(store::deleteEntry)
    }

    private fun fakeApiKey(fill: Char): String = "AIza" + fill.toString().repeat(32)

    companion object {
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val GCM_TAG_BITS = 128
        private const val KEY_CIPHERTEXT = "ciphertext"
        private const val KEY_IV = "iv"
        private const val KEY_KEY_ALIAS = "key_alias"
        private const val LEGACY_KEY_ALIAS = "mappy_google_api_key"
        private const val PREFERENCES_NAME = "mappy_api_key_store"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val UNRELATED_KEY_ALIAS = "mappy_unrelated_test_key"
        private const val VERSIONED_KEY_ALIAS_PREFIX = "mappy_google_api_key_v2_"
        private val VERSIONED_KEY_ALIAS_PATTERN =
            Regex("mappy_google_api_key_v2_[0-9a-f]{32}")
    }
}
