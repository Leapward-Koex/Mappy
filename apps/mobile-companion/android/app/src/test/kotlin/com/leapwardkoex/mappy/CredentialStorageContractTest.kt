package com.leapwardkoex.mappy

import java.io.File
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class CredentialStorageContractTest {
    @Test
    fun credentialPreferencesAreExcludedFromEveryAndroidBackupPath() {
        val manifest = sourceFile("src/main/AndroidManifest.xml")
        val legacyRules = sourceFile("src/main/res/xml/backup_rules.xml")
        val modernRules = sourceFile("src/main/res/xml/data_extraction_rules.xml")

        assertTrue(manifest.contains("android:allowBackup=\"false\""))
        assertTrue(manifest.contains("android:fullBackupContent=\"@xml/backup_rules\""))
        assertTrue(manifest.contains("android:dataExtractionRules=\"@xml/data_extraction_rules\""))
        assertTrue(legacyRules.contains("path=\"mappy_api_key_store.xml\""))
        assertTrue(modernRules.contains("<cloud-backup>"))
        assertTrue(modernRules.contains("<device-transfer>"))
        assertTrue(
            Regex("path=\\\"mappy_api_key_store\\.xml\\\"")
                .findAll(modernRules)
                .count() == 2
        )
    }

    @Test
    fun releasePackagingRequiresExplicitNonDebugSigning() {
        val buildScript = sourceFile("build.gradle.kts")

        assertFalse(buildScript.contains("signingConfigs.getByName(\"debug\")"))
        assertTrue(buildScript.contains("verifyReleaseSigning"))
        assertTrue(buildScript.contains("MAPPY_RELEASE_STORE_FILE"))
        assertTrue(buildScript.contains("MAPPY_RELEASE_KEY_ALIAS"))
        assertTrue(buildScript.contains("androiddebugkey"))
        assertTrue(buildScript.contains("CN=Android Debug"))
    }

    private fun sourceFile(relativePath: String): String {
        val candidates = listOf(
            File("app/$relativePath"),
            File(relativePath)
        )
        val file = candidates.firstOrNull(File::isFile)
        assertTrue(file != null, "$relativePath was not found from the unit test working directory.")
        return file.readText()
    }
}
