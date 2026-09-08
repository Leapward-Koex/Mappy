package com.leapwardkoex.mappy

import android.content.Context
import org.json.JSONObject
import java.util.Calendar

/** Fixed catalog, matched to the field masks and actions in GoogleMapTilesProvider. */
enum class ApiProduct(val id: String, val label: String, val unit: String, val defaultCap: Long?) {
    MAP_TILES("mapTiles2d", "2D Map Tiles", "tiles", 100_000),
    GEOCODING("geocoding", "Geocoding", "requests", 10_000),
    AUTOCOMPLETE("autocomplete", "Places Autocomplete Requests", "requests", 10_000),
    PLACE_DETAILS("placeDetailsPro", "Place Details Pro", "requests", 5_000),
    ROUTES("computeRoutesEssentials", "Compute Routes Essentials", "requests", 10_000);

    companion object {
        const val PRICING_URL = "https://developers.google.com/maps/billing-and-pricing/pricing"
        const val BILLING_URL = "https://developers.google.com/maps/billing-and-pricing/pay-as-you-go"
        const val REVIEWED_ON = "2026-09-08"
    }
}

data class ApiUsageSettings(
    val apiEnabled: Boolean = true,
    val mode: String = "block",
    val rolloverDay: Int = 1,
    val freeCaps: Map<ApiProduct, Long?> = ApiProduct.entries.associateWith { it.defaultCap }
) {
    init {
        require(mode in listOf("warn", "block")) { "Choose Warn or Block." }
        require(rolloverDay in 1..31) { "Billing day must be between 1 and 31." }
        require(freeCaps.keys == ApiProduct.entries.toSet()) { "Unknown or missing API product." }
        require(freeCaps.values.all { it == null || it in 0..MAX_CAP }) {
            "Free allowances must be whole numbers from 0 to $MAX_CAP."
        }
    }

    fun asMap(): Map<String, Any?> = mapOf(
        "apiEnabled" to apiEnabled, "mode" to mode, "rolloverDay" to rolloverDay,
        "freeCaps" to freeCaps.mapKeys { it.key.id }
    )

    companion object { const val MAX_CAP = 1_000_000_000L }
}

data class ApiUsageState(
    val periodStart: Long,
    val nextRollover: Long,
    val counters: Map<ApiProduct, Long> = ApiProduct.entries.associateWith { 0L }
)

interface ApiUsagePersistence {
    fun read(): String?
    fun write(value: String): Boolean
}

class PreferencesApiUsagePersistence(context: Context) : ApiUsagePersistence {
    private val preferences = context.applicationContext.getSharedPreferences("mappy_api_usage", Context.MODE_PRIVATE)
    override fun read(): String? = preferences.getString("state_v1", null)
    // Commit before dispatch; a process death must not lose already permitted usage.
    override fun write(value: String): Boolean = preferences.edit().putString("state_v1", value).commit()
}

internal class ApiUsageBlockedException(val reason: String, message: String) : RuntimeException(message)

/** One instance is shared by the phone and watch runtime. Reservations are serialized. */
class ApiUsageTracker(
    private val persistence: ApiUsagePersistence,
    private val now: () -> Long = System::currentTimeMillis,
    private val onChanged: (String?) -> Unit = {}
) {
    private var settings = ApiUsageSettings()
    private var state = period(now(), settings.rolloverDay)
    private var loadFailure = false

    init {
        try {
            persistence.read()?.let { raw ->
                val json = JSONObject(raw)
                require(json.getInt("version") == 1)
                val saved = json.getJSONObject("settings")
                val caps = saved.getJSONObject("freeCaps")
                settings = ApiUsageSettings(
                    saved.getBoolean("apiEnabled"), saved.getString("mode"), saved.getInt("rolloverDay"),
                    ApiProduct.entries.associateWith { product ->
                        if (!caps.has(product.id)) product.defaultCap
                        else if (caps.isNull(product.id)) null else caps.getLong(product.id)
                    }
                )
                val counts = json.getJSONObject("counters")
                state = ApiUsageState(json.getLong("periodStart"), json.getLong("nextRollover"),
                    ApiProduct.entries.associateWith { counts.optLong(it.id, 0L).also { n -> require(n >= 0) } })
                require(state.nextRollover > state.periodStart)
            }
        } catch (_: Exception) {
            // Do not silently replace unreadable usage with zero and permit more calls.
            loadFailure = true
        }
    }

    @Synchronized fun snapshot(): Map<String, Any?> {
        ensureLoaded()
        rollOver()
        return settings.asMap() + mapOf(
            "periodStart" to state.periodStart, "nextRollover" to state.nextRollover,
            "reviewedOn" to ApiProduct.REVIEWED_ON, "pricingUrl" to ApiProduct.PRICING_URL,
            "billingUrl" to ApiProduct.BILLING_URL,
            "products" to ApiProduct.entries.map { product ->
                mapOf("id" to product.id, "label" to product.label, "unit" to product.unit,
                    "defaultCap" to product.defaultCap, "freeCap" to settings.freeCaps[product],
                    "used" to state.counters.getValue(product), "warningLevel" to warningLevel(product))
            }
        )
    }

    /** Partial settings updates never accept counters, catalog edits, or reset commands. */
    @Synchronized fun update(values: Map<*, *>): Map<String, Any?> {
        ensureLoaded()
        rollOver()
        require(values.keys.all { it in setOf("apiEnabled", "mode", "rolloverDay", "freeCaps") }) {
            "Unknown API usage setting."
        }
        val caps = settings.freeCaps.toMutableMap()
        if (values.containsKey("freeCaps")) {
            val edits = values["freeCaps"] as? Map<*, *>
                ?: throw IllegalArgumentException("Free allowances must be a dictionary.")
            for ((id, value) in edits) {
                val product = ApiProduct.entries.firstOrNull { it.id == id }
                    ?: throw IllegalArgumentException("Unknown API product.")
                caps[product] = if (value == null) null else wholeNumber(value, ApiUsageSettings.MAX_CAP)
            }
        }
        val updated = settings.copy(
            apiEnabled = if (values.containsKey("apiEnabled")) values["apiEnabled"] as? Boolean
                ?: throw IllegalArgumentException("API enabled must be a boolean.") else settings.apiEnabled,
            mode = if (values.containsKey("mode")) values["mode"] as? String
                ?: throw IllegalArgumentException("Choose Warn or Block.") else settings.mode,
            rolloverDay = if (values.containsKey("rolloverDay")) wholeNumber(values["rolloverDay"], 31).toInt()
                else settings.rolloverDay,
            freeCaps = caps
        )
        // Changing the billing day must not erase current usage or grant an early reset.
        val updatedState = if (updated.rolloverDay != settings.rolloverDay) {
            state.copy(nextRollover = period(state.nextRollover - 1, updated.rolloverDay).nextRollover)
        } else state
        persist(updated, updatedState)
        onChanged(null)
        return snapshot()
    }

    /** units=0 guards non-billable session setup without charging a tile. */
    @Synchronized fun reserve(product: ApiProduct, units: Long = 1) {
        ensureLoaded()
        rollOver()
        require(units >= 0)
        if (!settings.apiEnabled) throw ApiUsageBlockedException("api_disabled",
            "Google Maps API requests are disabled in Settings > API usage.")
        val used = state.counters.getValue(product)
        val cap = settings.freeCaps[product]
        if (settings.mode == "block" && cap != null && (used >= cap || units > cap - used)) {
            throw ApiUsageBlockedException("api_limit_reached",
                "${product.label} reached its estimated free allowance. Requests are blocked until rollover; review Settings > API usage.")
        }
        if (units == 0L) return
        val previousLevel = warningLevel(product)
        val nextCount = Math.addExact(used, units)
        persist(settings, state.copy(counters = state.counters + (product to nextCount)))
        val level = warningLevel(product)
        val warning = if (level > previousLevel) {
            "${product.label}: ${if (level == 2) "100% of the estimated free allowance reached" else "80% of the estimated free allowance reached"}. " +
                if (settings.mode == "warn") "Warn mode allows further requests." else "Further requests stop at the allowance."
        } else null
        onChanged(warning)
    }

    private fun warningLevel(product: ApiProduct): Int {
        val cap = settings.freeCaps[product] ?: return 0
        val used = state.counters.getValue(product)
        return when { used >= cap -> 2; used.toDouble() >= cap * 0.8 -> 1; else -> 0 }
    }

    private fun ensureLoaded() {
        if (loadFailure) throw ApiUsageBlockedException("api_usage_unavailable",
            "API usage could not be read. Google Maps requests are blocked to protect your allowance.")
    }

    private fun rollOver() {
        val timestamp = now()
        if (timestamp >= state.nextRollover) persist(settings, period(timestamp, settings.rolloverDay))
    }

    private fun persist(nextSettings: ApiUsageSettings, nextState: ApiUsageState) {
        val json = JSONObject().put("version", 1).put("settings", JSONObject(nextSettings.asMap()))
            .put("periodStart", nextState.periodStart).put("nextRollover", nextState.nextRollover)
            .put("counters", JSONObject(nextState.counters.mapKeys { it.key.id }))
        if (!runCatching { persistence.write(json.toString()) }.getOrDefault(false)) throw ApiUsageBlockedException("api_usage_unavailable",
            "API usage could not be saved. Google Maps requests are blocked to protect your allowance.")
        settings = nextSettings
        state = nextState
    }

    companion object {
        private fun wholeNumber(value: Any?, max: Long): Long {
            require(value is Number && value.toDouble().isFinite() && value.toDouble() == value.toLong().toDouble() && value.toLong() in 0..max) {
                "Enter a whole number from 0 to $max."
            }
            return value.toLong()
        }

        // Calendar uses local time (including DST) and supports Android API 24.
        internal fun period(timestamp: Long, day: Int): ApiUsageState {
            fun boundary(monthOffset: Int): Long = Calendar.getInstance().run {
                timeInMillis = timestamp
                set(Calendar.DAY_OF_MONTH, 1)
                add(Calendar.MONTH, monthOffset)
                set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
                set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
                set(Calendar.DAY_OF_MONTH, minOf(day, getActualMaximum(Calendar.DAY_OF_MONTH)))
                timeInMillis
            }
            val thisMonth = boundary(0)
            return if (timestamp >= thisMonth) ApiUsageState(thisMonth, boundary(1))
                else ApiUsageState(boundary(-1), thisMonth)
        }
    }
}
