# BYOK Provider Policy

This policy is authoritative for credentials, provider calls, caching, and
attribution in Mappy.

## Policy Summary

- Mappy is bring-your-own-key.
- MVP uses direct phone-side Google API calls with the user's Google API key.
- Mappy has no project-hosted route proxy, tile proxy, account, or log
  collection service.
- The watch and PKJS never receive API keys or provider tokens.
- There is no OSM/Nominatim fallback in MVP.
- Provider work uses only the documented adapters listed below.
- Any future provider must be specified before implementation.

## Credential Behavior

- `AIza...`-shaped Google API keys are accepted through the mobile setup flow
  and validated locally.
- Other input shapes are rejected locally without a network request.

## MVP Google APIs

MVP uses these Google APIs:

| Need | API |
| --- | --- |
| Map source imagery | Google Map Tiles API, 2D road, satellite, hybrid, and terrain tiles as configured in `MAP_TILE_PIPELINE_MVP.md` |
| Origin/destination autocomplete and place resolution | Google Places API (New) Autocomplete and Place Details |
| Free-form origin/destination address resolution | Google Geocoding API |
| Route geometry and steps | Google Routes API `computeRoutes` |

Places API use is limited to autocomplete-backed navigation search,
saved-location editing, and place resolution. The watch protocol receives only
normalized saved-location records and route/nav payloads; it never receives
Places session tokens or API keys.

## Android Key Restrictions

The mobile setup flow must direct users to configure:

- Android application restriction for the active package name and SHA-1
  certificate fingerprint.
- API restrictions for Map Tiles API, Places API, Geocoding API, and Routes API.

Direct REST calls must be made by Android native code and include:

| Header | Value |
| --- | --- |
| `X-Android-Package` | Runtime `Context.getPackageName()`. |
| `X-Android-Cert` | Active signing-certificate SHA-1 as 40 lowercase or uppercase hex characters with no delimiters. |

Flutter must not compute or override these headers. PKJS must not perform these
calls.

## Validation Requirements

Validation statuses:

- not configured,
- validating,
- valid,
- invalid key,
- API disabled,
- quota or billing issue,
- provider permission denied,
- network unavailable,
- unsupported restricted-key behavior.

For each direct REST endpoint class used by MVP, native validation must include
a negative restriction check using an intentionally wrong package or certificate
header. The expected result is authentication or permission rejection.

If wrong Android identity is accepted by a provider endpoint, Mappy
must block that direct provider path and surface setup failure. It must not
recommend an unrestricted key and must not fall back to a Mappy proxy.

Development exception:

- Debug/profile builds may seed secure storage from the ignored hardcoded
  development key described in `SECURE_STORAGE_SPEC.md`.
- For that seeded development key only, native validation may treat successful
  correct Map Tiles, Places, Geocoding, and Routes requests as sufficient even if
  intentionally wrong Android package/certificate headers are accepted.
- This exception must be gated by native development-key provenance, not by
  plaintext equality alone. User-entered keys must clear development provenance
  and must not be overwritten by startup seeding.
- This exception exists only to verify live provider behavior before production
  package/signing restrictions are configured.
- User-entered keys, release builds, and any non-development credential path
  must continue to enforce the wrong-identity rejection checks above.

## Secret Handling

- Raw key is accepted only in the setup entry flow.
- Native code stores the key locally using secure storage backed by Android
  Keystore where available.
- Flutter receives only redacted status after storage.
- Watch receives no key material.
- PKJS receives no key material.
- Diagnostics may show a redacted key shape such as `AIza...abcd`, never the
  full value.
- Clearing the key stops credentialed work and clears provider sessions.

## Provider Adapter Rules

Provider adapters must expose normalized operations:

```text
loadSourceTile(zoom, source_tile_x, source_tile_y, map_source_settings)
autocompletePlace(input, role, session_token, location_bias)
resolvePlace(place_id, session_token)
geocodePlace(address_text, role, region, language)
computeRoute(origin, destination, travel_mode, language, region)
```

The watch protocol must not depend on provider-specific response fields.
Adapters map provider data into Mappy domain models before encoding watch
payloads.

For MVP, only the Google adapter is specified. Alternate adapters are blocked
until a spec covers:

- endpoints and authorization,
- provider terms and attribution,
- rate limits and user-agent rules,
- cache policy,
- route and geocode coverage,
- privacy behavior,
- error mapping,
- tests and fixtures.

## OSM And Nominatim

OSM/Nominatim is not an MVP fallback. It must not be silently used when the
Google key is missing, invalid, quota-limited, or unsupported.

A future OSM/Nominatim spec must define at least:

- tile provider or renderer,
- geocoder endpoint and required user agent,
- routing provider if routing is included,
- attribution on phone and watch,
- rate limiting and cache rules,
- offline behavior if any,
- privacy disclosures,
- error mapping compatible with `CMD_ERROR_STATE`.

## Caching And Attribution

- Source map tiles, encoded watch tiles, routes, geocoding results, and provider
  sessions are cached only within provider policy and response headers.
- Map tile source, quality, image-format, and palette-detail settings are local
  user preferences. They must be included in provider session and tile cache keys
  whenever they affect fetched bytes or encoded watch output.
- User can clear local provider caches.
- Google attribution must be shown wherever terms require it.
- If watch attribution is required and cannot fit acceptably, the provider path
  is blocked until the UX is revised or a different provider is specified.
- Walking and bicycling routes must show a provider warning that safe pedestrian
  or bicycling path detail may be incomplete.

## Error Mapping

| Condition | Watch category |
| --- | ---: |
| Missing key | 1 |
| Invalid key, API disabled, quota, billing, or provider permission denied | 2 |
| Missing location permission, no fix, or stale current-location origin | 3 |
| Network unavailable | 4 |
| Tile provider failure | 5 |
| Geocoding or route provider failure | 6 |
| No route found | 7 |
| Destination not configured | 8 |

Errors must be recoverable. Provider failures should not erase valid stale map
or route state unless the route worker explicitly sends a zero-point route
payload for no-route.

## Static Guardrails

Mappy runtime code must not contain:

- undocumented provider URLs,
- account or credential-relay handlers,
- application-backend route proxy code,
- automatic external log upload.
