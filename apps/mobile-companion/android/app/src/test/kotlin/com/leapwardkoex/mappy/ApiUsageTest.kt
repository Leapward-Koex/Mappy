package com.leapwardkoex.mappy

import org.json.JSONObject
import java.util.Calendar
import java.util.TimeZone
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread
import kotlin.test.*

internal class MemoryApiUsagePersistence : ApiUsagePersistence {
    var value: String? = null
    var writable = true
    var writes = 0
    override fun read(): String? = value
    override fun write(value: String): Boolean {
        if (!writable) return false
        this.value = value
        writes++
        return true
    }
}

class ApiUsageTest {
    private fun date(year: Int, month: Int, day: Int, hour: Int = 0): Long = Calendar.getInstance().run {
        clear(); set(year, month - 1, day, hour, 0, 0); timeInMillis
    }

    private fun count(tracker: ApiUsageTracker, product: ApiProduct): Long =
        (tracker.snapshot()["products"] as List<*>).map { it as Map<*, *> }
            .single { it["id"] == product.id }["used"] as Long

    @Test fun defaultsAndPersistenceKeepTheFixedCatalog() {
        val store = MemoryApiUsagePersistence()
        val tracker = ApiUsageTracker(store, { date(2026, 9, 8) })
        val initial = tracker.snapshot()
        assertEquals(true, initial["apiEnabled"])
        assertEquals("block", initial["mode"])
        assertEquals(5, (initial["products"] as List<*>).size)
        tracker.update(mapOf("mode" to "warn", "rolloverDay" to 12,
            "freeCaps" to mapOf("geocoding" to 17L)))
        tracker.reserve(ApiProduct.GEOCODING)
        tracker.update(mapOf("apiEnabled" to false))
        val restored = ApiUsageTracker(store, { date(2026, 9, 8) })
        assertEquals(tracker.snapshot(), restored.snapshot())
        assertEquals(1L, count(restored, ApiProduct.GEOCODING))
        assertEquals(100_000L, (restored.snapshot()["freeCaps"] as Map<*, *>)["mapTiles2d"])
    }

    @Test fun migrationSeedsNewCatalogProductsWithoutResettingUsageOrSettings() {
        val store = MemoryApiUsagePersistence()
        val tracker = ApiUsageTracker(store)
        tracker.update(mapOf("mode" to "warn"))
        tracker.reserve(ApiProduct.GEOCODING, 23)
        val old = JSONObject(store.value!!)
        old.getJSONObject("settings").getJSONObject("freeCaps").remove("computeRoutesEssentials")
        old.getJSONObject("counters").remove("computeRoutesEssentials")
        store.value = old.toString()
        val restored = ApiUsageTracker(store)
        assertEquals(23L, count(restored, ApiProduct.GEOCODING))
        assertEquals(0L, count(restored, ApiProduct.ROUTES))
        assertEquals("warn", restored.snapshot()["mode"])
    }

    @Test fun exactCapBlocksOnlyThatProductAndWarningsFireOncePerThreshold() {
        val warnings = mutableListOf<String>()
        val tracker = ApiUsageTracker(MemoryApiUsagePersistence(), onChanged = { it?.let(warnings::add) })
        tracker.update(mapOf("freeCaps" to mapOf("geocoding" to 10)))
        repeat(8) { tracker.reserve(ApiProduct.GEOCODING) }
        assertEquals(1, warnings.size)
        tracker.reserve(ApiProduct.GEOCODING, 2)
        assertEquals(2, warnings.size)
        assertFailsWith<ApiUsageBlockedException> { tracker.reserve(ApiProduct.GEOCODING) }
        assertEquals(10L, count(tracker, ApiProduct.GEOCODING))
        tracker.reserve(ApiProduct.ROUTES)
        tracker.update(mapOf("mode" to "warn"))
        tracker.reserve(ApiProduct.GEOCODING, 5)
        assertEquals(15L, count(tracker, ApiProduct.GEOCODING))
        assertEquals(2, warnings.size)
    }

    @Test fun concurrentReservationsCannotOvershootTheCap() {
        val tracker = ApiUsageTracker(MemoryApiUsagePersistence())
        tracker.update(mapOf("freeCaps" to mapOf("mapTiles2d" to 7)))
        val start = CountDownLatch(1)
        val allowed = AtomicInteger()
        val workers = List(30) { thread {
            start.await()
            try { tracker.reserve(ApiProduct.MAP_TILES); allowed.incrementAndGet() }
            catch (_: ApiUsageBlockedException) { }
        } }
        start.countDown()
        workers.forEach { it.join(5_000); assertFalse(it.isAlive) }
        assertEquals(7, allowed.get())
        assertEquals(7L, count(tracker, ApiProduct.MAP_TILES))
    }

    @Test fun disableCoversEveryProductAndNonBillableSessionWork() {
        val tracker = ApiUsageTracker(MemoryApiUsagePersistence())
        tracker.reserve(ApiProduct.MAP_TILES, 0)
        assertEquals(0L, count(tracker, ApiProduct.MAP_TILES))
        tracker.update(mapOf("apiEnabled" to false, "mode" to "warn"))
        for (product in ApiProduct.entries) {
            assertEquals("api_disabled", assertFailsWith<ApiUsageBlockedException> { tracker.reserve(product) }.reason)
            assertEquals(0L, count(tracker, product))
        }
        assertFailsWith<ApiUsageBlockedException> { tracker.reserve(ApiProduct.MAP_TILES, 0) }
    }

    @Test fun zeroUnlimitedAndInvalidCaps() {
        val tracker = ApiUsageTracker(MemoryApiUsagePersistence())
        tracker.update(mapOf("freeCaps" to mapOf("geocoding" to 0)))
        assertFailsWith<ApiUsageBlockedException> { tracker.reserve(ApiProduct.GEOCODING) }
        tracker.update(mapOf("freeCaps" to mapOf("computeRoutesEssentials" to null)))
        tracker.reserve(ApiProduct.ROUTES, 1_000_000)
        tracker.update(mapOf("freeCaps" to mapOf("geocoding" to null)))
        tracker.reserve(ApiProduct.GEOCODING, 20_000)
        for (value in listOf(-1, 1.5, "12", 1_000_000_001L)) {
            assertFailsWith<IllegalArgumentException> { tracker.update(mapOf("freeCaps" to mapOf("geocoding" to value))) }
        }
        for (day in listOf(0, 32, 1.5)) {
            assertFailsWith<IllegalArgumentException> { tracker.update(mapOf("rolloverDay" to day)) }
        }
        assertFailsWith<IllegalArgumentException> { tracker.update(mapOf("freeCaps" to mapOf("unknown" to 5))) }
        assertFailsWith<IllegalArgumentException> { tracker.update(mapOf("counters" to emptyMap<String, Int>())) }
        assertFailsWith<IllegalArgumentException> { tracker.update(mapOf("mode" to "ignore")) }
    }

    @Test fun monthlyRolloverIsExactlyOnceAfterReloadOrSeveralMissedMonths() {
        var now = date(2026, 9, 8)
        val store = MemoryApiUsagePersistence()
        var tracker = ApiUsageTracker(store, { now })
        tracker.reserve(ApiProduct.GEOCODING, 7)
        now = date(2026, 10, 1) - 1
        assertEquals(7L, count(tracker, ApiProduct.GEOCODING))
        now++
        tracker = ApiUsageTracker(store, { now })
        assertEquals(0L, count(tracker, ApiProduct.GEOCODING))
        val writes = store.writes
        tracker.snapshot()
        assertEquals(writes, store.writes)
        tracker.reserve(ApiProduct.GEOCODING)
        now = date(2027, 2, 4)
        assertEquals(0L, count(tracker, ApiProduct.GEOCODING))
        assertEquals(date(2027, 3, 1), tracker.snapshot()["nextRollover"])
    }

    @Test fun billingDayClampsShortMonthsButReturnsToOriginalDay() {
        for (day in 29..31) {
            val feb = ApiUsageTracker.period(date(2026, 2, 28), day)
            assertEquals(date(2026, 2, 28), feb.periodStart)
            assertEquals(date(2026, 3, day), feb.nextRollover)
            val leap = ApiUsageTracker.period(date(2028, 2, 28), day)
            assertEquals(date(2028, 2, 29), leap.nextRollover)
        }
        val april = ApiUsageTracker.period(date(2026, 4, 30), 31)
        assertEquals(date(2026, 5, 31), april.nextRollover)
        assertEquals(date(2027, 1, 15), ApiUsageTracker.period(date(2026, 12, 20), 15).nextRollover)
    }

    @Test fun localMidnightRolloverHandlesDaylightSaving() {
        val previousZone = TimeZone.getDefault()
        try {
            TimeZone.setDefault(TimeZone.getTimeZone("Pacific/Auckland"))
            val period = ApiUsageTracker.period(date(2026, 9, 28, 12), 28)
            assertEquals(date(2026, 9, 28), period.periodStart)
            assertEquals(date(2026, 10, 28), period.nextRollover)
        } finally { TimeZone.setDefault(previousZone) }
    }

    @Test fun changingDayOrMovingClockBackDoesNotEraseUsage() {
        var now = date(2026, 9, 8)
        val tracker = ApiUsageTracker(MemoryApiUsagePersistence(), { now })
        tracker.reserve(ApiProduct.GEOCODING, 9)
        tracker.update(mapOf("rolloverDay" to 12))
        assertEquals(date(2026, 10, 12), tracker.snapshot()["nextRollover"])
        now = date(2026, 9, 12)
        assertEquals(9L, count(tracker, ApiProduct.GEOCODING))
        tracker.update(mapOf("rolloverDay" to 5))
        assertEquals(date(2026, 11, 5), tracker.snapshot()["nextRollover"])
        now = date(2026, 8, 1)
        assertEquals(9L, count(tracker, ApiProduct.GEOCODING))
    }

    @Test fun failedPersistenceAndUnreadableDataNeverGrantRequests() {
        val store = MemoryApiUsagePersistence()
        val tracker = ApiUsageTracker(store)
        tracker.reserve(ApiProduct.GEOCODING)
        store.writable = false
        assertFailsWith<ApiUsageBlockedException> { tracker.reserve(ApiProduct.GEOCODING) }
        assertEquals(1L, count(tracker, ApiProduct.GEOCODING))
        assertFailsWith<ApiUsageBlockedException> { tracker.update(mapOf("apiEnabled" to false)) }
        store.value = "malformed"
        assertFailsWith<ApiUsageBlockedException> { ApiUsageTracker(store).reserve(ApiProduct.GEOCODING) }
    }

    @Test fun warningThresholdsPersistAcrossRestartAndResetAtRollover() {
        val store = MemoryApiUsagePersistence()
        var now = date(2026, 9, 8)
        val first = ApiUsageTracker(store, { now })
        first.update(mapOf("mode" to "warn", "freeCaps" to mapOf("geocoding" to 10)))
        first.reserve(ApiProduct.GEOCODING, 8)
        val warnings = mutableListOf<String>()
        val restored = ApiUsageTracker(store, { now }, { it?.let(warnings::add) })
        restored.reserve(ApiProduct.GEOCODING)
        assertTrue(warnings.isEmpty())
        restored.reserve(ApiProduct.GEOCODING)
        assertEquals(1, warnings.size)
        now = date(2026, 10, 1)
        restored.reserve(ApiProduct.GEOCODING, 8)
        assertEquals(2, warnings.size)
    }

    @Test fun throwingStorageFailureIsReportedAsLocalUsageFailure() {
        val storage = object : ApiUsagePersistence {
            override fun read(): String? = null
            override fun write(value: String): Boolean = throw java.io.IOException("Disk failure")
        }
        assertEquals("api_usage_unavailable", assertFailsWith<ApiUsageBlockedException> {
            ApiUsageTracker(storage).reserve(ApiProduct.GEOCODING)
        }.reason)
    }

    @Test fun oldSdkUsageIsIgnoredWithoutResettingUserProducts() {
        val store = MemoryApiUsagePersistence()
        val tracker = ApiUsageTracker(store)
        tracker.update(mapOf("mode" to "warn", "rolloverDay" to 12,
            "freeCaps" to mapOf("geocoding" to 123L)))
        tracker.reserve(ApiProduct.GEOCODING, 23)
        val expected = tracker.snapshot()
        val old = JSONObject(store.value!!)
        old.getJSONObject("settings").getJSONObject("freeCaps").put("mapsSdk", 0)
        old.getJSONObject("counters").put("mapsSdk", 99)
        store.value = old.toString()
        val restored = ApiUsageTracker(store)
        assertEquals(expected, restored.snapshot())
        assertFailsWith<IllegalArgumentException> {
            restored.update(mapOf("freeCaps" to mapOf("mapsSdk" to 0)))
        }
        restored.update(mapOf("apiEnabled" to false))
        val saved = JSONObject(store.value!!)
        assertFalse(saved.getJSONObject("counters").has("mapsSdk"))
        assertFalse(saved.getJSONObject("settings").getJSONObject("freeCaps").has("mapsSdk"))
        assertEquals(23L, count(restored, ApiProduct.GEOCODING))
    }
}
