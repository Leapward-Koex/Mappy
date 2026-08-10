package com.leapwardkoex.mappy

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class CredentialSafetyTest {
    @Test
    fun googleApiKeyShapeUsesStandaloneProviderContract() {
        assertTrue(hasSupportedGoogleApiKeyShape("AIza" + "A".repeat(16)))
        assertTrue(hasSupportedGoogleApiKeyShape("AIza" + "_a-Z9".repeat(8)))
        assertFalse(hasSupportedGoogleApiKeyShape("service_opaque123"))
        assertFalse(hasSupportedGoogleApiKeyShape("AIzaTooShort"))
    }

    @Test
    fun diagnosticRedactionRemovesGenericOpaqueTokensAndKnownSecrets() {
        val redacted = redactDiagnosticCredentials(
            "session service_opaque123; configured-value",
            knownSecrets = listOf("configured-value")
        )

        assertEquals("session [redacted-opaque-token]; [redacted]", redacted)
    }

    @Test
    fun diagnosticRedactionPreservesExistingCredentialProtections() {
        val redacted = redactDiagnosticCredentials(
            "api key=AIzaSyExampleGoogleKey0123456789 " +
                "Authorization: Bearer abc.def " +
                "https://example.test/path?session_token=secret-value"
        )

        assertFalse(redacted.contains("ExampleGoogleKey"))
        assertFalse(redacted.contains("abc.def"))
        assertFalse(redacted.contains("secret-value"))
    }
}
