package com.leapwardkoex.mappy

import java.io.File
import kotlin.test.Test
import kotlin.test.assertTrue

class MappyWatchCommandDispatcherSyncContractTest {
    @Test
    fun startupResendsBothFeedbackSettingsFromThePersistedSnapshot() {
        val body = functionBody(dispatcherSource(), "private fun handleInit")

        val snapshot = body.indexOf("val currentSettings = synchronized(lock) { settings }")
        val haptics = body.indexOf("hapticModeMessage(currentSettings)")
        val glance = body.indexOf("glanceModeMessage(currentSettings)")
        assertTrue(snapshot >= 0, "Startup must snapshot the durable display settings.")
        assertTrue(haptics > snapshot, "Startup must resend the persisted Haptics mode.")
        assertTrue(glance > haptics, "Startup must independently resend the persisted Glance mode.")
    }

    @Test
    fun watchOriginFeedbackUpdatesNormalizePersistEchoAndEmitTheSettingsEvent() {
        val source = dispatcherSource()
        val dispatch = functionBody(source, "fun dispatch")
        val update = functionBody(source, "private fun updateScalarSetting")

        assertTrue(
            dispatch.contains("CMD_HAPTIC_MODE -> updateScalarSetting(CMD_HAPTIC_MODE"),
            "Watch-origin Haptics messages must use the scalar settings reconciliation path."
        )
        assertTrue(
            dispatch.contains("CMD_GLANCE_MODE -> updateScalarSetting(CMD_GLANCE_MODE"),
            "Watch-origin Glance messages must use the scalar settings reconciliation path."
        )
        assertTrue(
            update.contains("CMD_HAPTIC_MODE -> settings.copy(hapticMode = feedbackModeProtocolValue(value))"),
            "Watch-origin Haptics values must normalize before persistence."
        )
        assertTrue(
            update.contains("CMD_GLANCE_MODE -> settings.copy(glanceMode = feedbackModeProtocolValue(value))"),
            "Watch-origin Glance values must normalize before persistence."
        )
        assertTrue(update.contains("saveNativeDisplaySettings(appContext, settings)"))
        assertTrue(update.contains("CMD_HAPTIC_MODE -> listOf(hapticModeMessage(settings))"))
        assertTrue(update.contains("CMD_GLANCE_MODE -> listOf(glanceModeMessage(settings))"))

        val save = update.indexOf("saveNativeDisplaySettings(appContext, settings)")
        val event = update.indexOf("\"event\" to \"displaySettingsChanged\"")
        assertTrue(event > save, "The durable update must complete before Flutter is notified.")
        assertTrue(update.contains("\"source\" to \"watch\""))
        assertTrue(update.contains("\"settings\" to displaySettingsMap(updatedSettings)"))
    }

    @Test
    fun sharedPreferencesContractLoadsAndSavesIndependentNormalizedFeedbackModes() {
        val source = sourceFile("NativeDisplaySettings.kt")
        val load = functionBody(source, "internal fun loadNativeDisplaySettings")
        val save = functionBody(source, "internal fun saveNativeDisplaySettings")

        assertTrue(load.contains("preferences.getInt(HAPTIC_MODE_SETTING, DEFAULT_HAPTIC_MODE)"))
        assertTrue(load.contains("preferences.getInt(GLANCE_MODE_SETTING, DEFAULT_GLANCE_MODE)"))
        assertTrue(
            Regex("hapticMode\\s*=\\s*feedbackModeProtocolValue\\s*\\(").containsMatchIn(load)
        )
        assertTrue(
            Regex("glanceMode\\s*=\\s*feedbackModeProtocolValue\\s*\\(").containsMatchIn(load)
        )
        assertTrue(
            save.contains(".putInt(HAPTIC_MODE_SETTING, feedbackModeProtocolValue(settings.hapticMode))")
        )
        assertTrue(
            save.contains(".putInt(GLANCE_MODE_SETTING, feedbackModeProtocolValue(settings.glanceMode))")
        )
        assertTrue(save.contains(".apply()"))
    }

    private fun dispatcherSource(): String = sourceFile("MappyWatchCommandDispatcher.kt")

    private fun sourceFile(name: String): String {
        val candidates = listOf(
            File("app/src/main/kotlin/com/leapwardkoex/mappy/$name"),
            File("src/main/kotlin/com/leapwardkoex/mappy/$name")
        )
        val file = candidates.firstOrNull { it.isFile }
        assertTrue(file != null, "$name was not found from the unit test working directory.")
        return file.readText()
    }

    private fun functionBody(source: String, signature: String): String {
        val signatureStart = source.indexOf(signature)
        assertTrue(signatureStart >= 0, "Missing function $signature.")
        val bodyStart = source.indexOf('{', signatureStart)
        assertTrue(bodyStart >= 0, "Missing body for $signature.")
        var depth = 0
        for (index in bodyStart until source.length) {
            when (source[index]) {
                '{' -> depth++
                '}' -> {
                    depth--
                    if (depth == 0) return source.substring(bodyStart + 1, index)
                }
            }
        }
        error("Unterminated body for $signature.")
    }
}
