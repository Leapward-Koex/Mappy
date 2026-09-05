package com.leapwardkoex.mappy

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SetupChecklistPersistenceTest {
    @Test
    fun appStatePreferenceContractUsesTheApprovedNames() {
        assertEquals("mappy_app_state", APP_STATE_PREFERENCES_NAME)
        assertEquals("setup_checklist_version", SETUP_CHECKLIST_VERSION_KEY)
    }

    @Test
    fun storedVersionsDefaultAndNormalizeToNonnegativeValues() {
        assertEquals(0, normalizeStoredSetupChecklistVersion(Int.MIN_VALUE))
        assertEquals(0, normalizeStoredSetupChecklistVersion(-1))
        assertEquals(0, normalizeStoredSetupChecklistVersion(0))
        assertEquals(12, normalizeStoredSetupChecklistVersion(12))
    }

    @Test
    fun setterAcceptsOnlyNonnegativePlatformIntegers() {
        assertEquals(0, setupChecklistVersionArgument(0))
        assertEquals(3, setupChecklistVersionArgument(3))
        assertEquals(Int.MAX_VALUE, setupChecklistVersionArgument(Int.MAX_VALUE.toLong()))
        assertEquals(7, setupChecklistVersionArgument(mapOf("version" to 7)))

        listOf(
            null,
            -1,
            -1L,
            Int.MAX_VALUE.toLong() + 1,
            1.0,
            "1",
            true,
            emptyMap<String, Any?>(),
            mapOf("version" to null)
        ).forEach { value ->
            assertNull(setupChecklistVersionArgument(value), "Unexpected accepted value: $value")
        }
    }

    @Test
    fun persistenceReturnsTheSynchronousCommitResult() {
        val source = sourceFile("NativeSetupChecklistPersistence.kt")

        assertTrue(source.contains("getSharedPreferences(APP_STATE_PREFERENCES_NAME"))
        assertTrue(source.contains(".getInt(SETUP_CHECKLIST_VERSION_KEY, 0)"))
        assertTrue(source.contains(".putInt(SETUP_CHECKLIST_VERSION_KEY, version)"))
        assertTrue(source.contains(".commit()"))
        assertTrue(!source.contains(".apply()"))
    }

    @Test
    fun bridgeExposesBothChecklistMethodsAndRejectsInvalidInput() {
        val source = sourceFile("MainActivity.kt")

        assertTrue(source.contains("\"getSetupChecklistVersion\" ->"))
        assertTrue(source.contains("NativeSetupChecklistPersistence.read(applicationContext)"))
        assertTrue(source.contains("\"setSetupChecklistVersion\" ->"))
        assertTrue(source.contains("setupChecklistVersionArgument(call.arguments)"))
        assertTrue(source.contains("\"invalid_setup_checklist_version\""))
        assertTrue(source.contains("NativeSetupChecklistPersistence.write(applicationContext, version)"))
    }

    private fun sourceFile(name: String): String {
        val candidates = listOf(
            File("app/src/main/kotlin/com/leapwardkoex/mappy/$name"),
            File("src/main/kotlin/com/leapwardkoex/mappy/$name")
        )
        val file = candidates.firstOrNull { it.isFile }
        assertTrue(file != null, "$name was not found from the unit test working directory.")
        return file.readText()
    }
}
