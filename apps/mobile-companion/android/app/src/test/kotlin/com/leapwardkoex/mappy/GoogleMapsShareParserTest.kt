package com.leapwardkoex.mappy

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class GoogleMapsShareParserTest {
    @Test
    fun parsesLocationShareWithCoordinates() {
        val result = GoogleMapsShareParser.parse(
            "Auckland Museum\n" +
                "https://www.google.com/maps/search/?api=1&query=-36.86097,174.77774%28Auckland%20Museum%29"
        )

        val share = parsedShare(result)
        assertEquals(GoogleMapsShareParser.ShareType.Location, share.type)
        assertEquals("www.google.com", share.safeHost)
        assertEquals("Auckland Museum", share.destination.label)
        assertEquals(-36.86097, share.destination.latitude)
        assertEquals(174.77774, share.destination.longitude)
        assertFalse(share.explicitOrigin)
    }

    @Test
    fun parsesLocationShareRequiringGeocodeFallback() {
        val result = GoogleMapsShareParser.parse(
            "Auckland Museum\n" +
                "https://www.google.com/maps/search/?api=1&query=Auckland%20Museum"
        )

        val share = parsedShare(result)
        assertEquals(GoogleMapsShareParser.ShareType.Location, share.type)
        assertEquals("Auckland Museum", share.destination.address)
        assertFalse(share.destination.hasCoordinates)
    }

    @Test
    fun parsesRouteShareWithExplicitOriginAndDestination() {
        val result = GoogleMapsShareParser.parse(
            "https://www.google.com/maps/dir/?api=1" +
                "&origin=Auckland%20Library" +
                "&destination=-36.86097,174.77774%28Auckland%20Museum%29" +
                "&travelmode=walking"
        )

        val share = parsedShare(result)
        assertEquals(GoogleMapsShareParser.ShareType.Route, share.type)
        assertTrue(share.explicitOrigin)
        assertEquals("Auckland Library", share.origin?.address)
        assertEquals("Auckland Museum", share.destination.label)
        assertEquals(GoogleMapsShareParser.TravelMode.Walk, share.travelMode)
    }

    @Test
    fun parsesRouteShareWithCurrentLocationOrigin() {
        val result = GoogleMapsShareParser.parse(
            "https://www.google.com/maps/dir/?api=1" +
                "&destination=Auckland%20Museum" +
                "&travelmode=driving"
        )

        val share = parsedShare(result)
        assertEquals(GoogleMapsShareParser.ShareType.Route, share.type)
        assertFalse(share.explicitOrigin)
        assertEquals("Auckland Museum", share.destination.address)
        assertEquals(GoogleMapsShareParser.TravelMode.Drive, share.travelMode)
    }

    @Test
    fun shortLinkRequiresRedirectThenParsesResolvedUrl() {
        val initial = GoogleMapsShareParser.parse("https://maps.app.goo.gl/abc123")
        assertTrue(initial is GoogleMapsShareParser.Result.RedirectRequired)
        assertEquals("maps.app.goo.gl", initial.safeHost)

        val resolved = GoogleMapsShareParser.parse(
            "Auckland Museum\nhttps://maps.app.goo.gl/abc123",
            resolvedUrl = "https://www.google.com/maps/search/?api=1&query=Auckland%20Museum",
            redirectHopCount = 1
        )
        val share = parsedShare(resolved)
        assertEquals(1, share.redirectHopCount)
        assertEquals("Auckland Museum", share.destination.address)
    }

    @Test
    fun rejectsUnsupportedRouteShapesAndNonGoogleUrls() {
        assertRejected(
            GoogleMapsShareParser.parse(
                "https://www.google.com/maps/dir/?api=1" +
                    "&origin=A&destination=B&travelmode=transit"
            )
        )
        assertRejected(
            GoogleMapsShareParser.parse(
                "https://www.google.com/maps/dir/A/B/C"
            )
        )
        assertRejected(
            GoogleMapsShareParser.parse("https://example.com/maps/place/Auckland")
        )
        assertRejected(GoogleMapsShareParser.parse("Meet me at the museum"))
    }

    private fun parsedShare(result: GoogleMapsShareParser.Result): GoogleMapsShareParser.Share {
        assertTrue(result is GoogleMapsShareParser.Result.Parsed, "Expected parsed share, got $result")
        return result.share
    }

    private fun assertRejected(result: GoogleMapsShareParser.Result) {
        assertTrue(result is GoogleMapsShareParser.Result.Rejected, "Expected rejection, got $result")
        assertNotNull(result.reason)
    }
}
