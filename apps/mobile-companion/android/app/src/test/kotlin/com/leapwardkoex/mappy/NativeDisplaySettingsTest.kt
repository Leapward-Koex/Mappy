package com.leapwardkoex.mappy

import kotlin.test.Test
import kotlin.test.assertEquals

class NativeDisplaySettingsTest {
    @Test
    fun feedbackModesPreserveEveryProtocolPreset() {
        (0..3).forEach { mode ->
            assertEquals(mode, feedbackModeProtocolValue(mode))
        }
    }

    @Test
    fun missingOrInvalidFeedbackModesNormalizeToAll() {
        listOf<Int?>(null, -1, 4, Int.MAX_VALUE).forEach { mode ->
            assertEquals(DEFAULT_HAPTIC_MODE, feedbackModeProtocolValue(mode))
        }
        assertEquals(3, DEFAULT_HAPTIC_MODE)
        assertEquals(3, DEFAULT_GLANCE_MODE)

        val defaults = NativeDisplaySettings(
            travelMode = 2,
            unitsMode = 1,
            backlightMode = 0,
            mapOrientation = 0,
            tileAnimationMode = 1
        )
        assertEquals(3, defaults.hapticMode)
        assertEquals(3, defaults.glanceMode)
    }

    @Test
    fun displaySettingsExposeIndependentFeedbackModes() {
        val settings = NativeDisplaySettings(
            travelMode = 2,
            unitsMode = 1,
            backlightMode = 0,
            mapOrientation = 0,
            tileAnimationMode = 1,
            hapticMode = 1,
            glanceMode = 2
        )

        val values = displaySettingsMap(settings)

        assertEquals(1, values[HAPTIC_MODE_SETTING])
        assertEquals(2, values[GLANCE_MODE_SETTING])
    }

    @Test
    fun feedbackCommandsUseProtocolVersionFourIds() {
        assertEquals(4, WATCH_PROTOCOL_VERSION)
        assertEquals(406, CMD_HAPTIC_MODE)
        assertEquals(407, CMD_GLANCE_MODE)
    }
}
