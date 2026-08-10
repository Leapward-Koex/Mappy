# Provider Adapter Test Spec

This spec defines test coverage for Google provider adapters, map tile
generation, destination autocomplete, geocoding, routing, restricted-key
validation, and phone/watch protocol replay. The goal is to make provider
behavior testable without a physical watch or live Google calls in default CI.

## Design Basis

- Provider tests cover source-tile fetches, 54x63 watch crops, packed RLE
  payloads, geocoding, route simplification, nav-step chunks, and visible error
  mapping.

- MVP provider calls are direct phone-side Google Map Tiles, Places, Geocoding,
  and Routes calls using the user's key.
- Provider adapters must be behind interfaces and testable with fakes.
- Default tests must not require network access or a real API key.
- Live restricted-key validation is a release gate and must be opt-in.

## Adapter Boundaries

Provider interfaces:

```text
loadSourceTile(zoom, source_tile_x, source_tile_y, map_source_settings)
  -> raster image or pixel buffer covering exactly one provider source tile

geocodePlace(address_text, role, region, language)
  -> normalized origin or destination coordinates

autocompletePlace(input, role, session_token, location_bias)
  -> Google Places predictions for Navigate Now origin/destination search and saved-location editing

resolvePlace(place_id, session_token)
  -> normalized origin or destination coordinates and display metadata

computeRoute(origin, destination, travel_mode, language, region)
  -> normalized route
```

The Google Map Tiles concrete adapter may internally create and cache provider
sessions before satisfying `loadSourceTile`; tests should target the normalized
facade and add Google-specific session tests only around the concrete adapter.

Shared dependencies are injected:

- HTTP client.
- Secure key provider.
- Android identity/header provider.
- Clock.
- Network status detector.
- Diagnostics sink.

No adapter may read Flutter UI state directly or send AppMessages directly.
Adapters return normalized models or typed failures to workers.

## Default Test Modes

Pure unit tests:

- No Android runtime.
- No network.
- Fake HTTP responses.
- Golden fixtures.

Android/JVM tests:

- Fake secure storage.
- Fake Android identity provider.
- Fake transport.
- Optional Robolectric/instrumentation only where platform APIs are required.

Live provider tests:

- Disabled by default.
- Require explicit environment/config flag and user-provided test key.
- Must never run in default CI.
- Must log only redacted key status.

## Map Tile Tests

Golden fixtures:

- 256x256 four-color source tile.
- Four neighboring source tiles with unique quadrant colors.
- Day and night palette expected outputs.
- 54x63 expected palette-index grid, plus at least one larger supported watch
  tile size.
- RLE payload expected to decode losslessly.

Required cases:

- Crop fully inside one source tile.
- Crop crossing right boundary.
- Crop crossing bottom boundary.
- Crop crossing both right and bottom boundaries.
- Source session request bodies are generated for road, satellite, hybrid, and
  terrain settings, including required layer/overlay fields.
- Returned source tile dimensions 256x256, 512x512, and 1024x1024 map to the
  same 256 logical world-pixel tile coverage.
- Session requests use `scaleFactor1x`, `highDpi = false`, and omit
  `imageFormat`.
- Supported rendered watch tile size presets use the expected crop width/height
  and tile-chunking behavior.
- X tile wrapping at `2^zoom`.
- Y tile clamp/reject behavior at provider bounds.
- Missing key returns category 1 before network.
- Network failure returns category 4 or tile category 5 as specified by worker
  context.
- Provider quota/API/billing/permission failure maps to category 2 or 5 with
  safe diagnostics.
- Theme change invalidates encoded cache.
- Map source or rendered tile size changes invalidate provider sessions, source
  tile cache, encoded tile cache, and visible watch tile cache through
  `CMD_MAP_SETTINGS`.
- Centered map orientation changes do not invalidate provider sessions, source
  tile cache, or encoded tile cache; rotated GPS-follow coverage still uses
  ordinary x/y/zoom/theme `CMD_TILE_REQUEST` messages.
- Duplicate in-flight tile requests are deduped.
- Worst-case encoded payload fits negotiated AppMessage dictionary limits.

Tile protocol replay:

- Fake watch sends 25 visible `CMD_TILE_REQUEST` commands for `emery`.
- Worker produces matching `CMD_TILE` messages for all available fake tiles.
- Three NACK callbacks for a tile cause a drop diagnostic.

## Geocoding Tests

Golden fixtures:

- Successful address with formatted address and coordinates.
- Zero results.
- Permission denied.
- API disabled.
- Quota/billing issue.
- Network unavailable.
- Malformed provider response.

Required cases:

- Missing key returns category 1 with no HTTP request.
- Missing saved-location ID returns category 8.
- Text address geocodes and stores phone-local coordinates.
- Text origin geocodes and can be used as a route origin.
- Stored coordinates are reused until address changes or refresh is requested.
- No result returns category 6.
- Provider auth/setup failures return category 2.
- Provider metadata stays phone-local and is never sent to the watch.

## Routing Tests

Golden fixtures:

- Short drive route with 2..128 points.
- Long dense route requiring simplification.
- Route with more than 255 provider steps.
- One-point provider/simplification result.
- No-route provider result.
- Walking and bicycling route responses.
- UTF-8 instruction strings with multibyte characters near byte caps.

Required cases:

- Missing key returns category 1 with no HTTP request.
- Missing fresh GPS returns category 3 only when the route origin is current
  location.
- Explicit Places-backed origin can route without a fresh GPS origin after the
  origin resolves.
- Missing saved-location ID returns category 8.
- Invalid/API disabled/quota/billing/permission denied returns category 2.
- Network unavailable returns category 4.
- Geocode no result returns category 6.
- No-route sends zero-point `CMD_ROUTE_POINTS`, sends no nav steps, then sends
  category 7.
- Successful route preserves endpoints and produces 2..128 route points.
- Successful explicit-origin route uses the resolved origin coordinates in the
  Routes API request.
- One-point output maps to category 6 without clearing a prior valid route.
- First nav-step chunk contains at most three records.
- Instructions are capped on UTF-8 code point boundaries.
- More than 255 provider steps are deterministically coalesced or truncated.
- Watch next-step request is answered from local route cache without another
  provider call.

## Android Restricted-Key Tests

Static/local tests:

- Header provider returns active package name.
- Header provider returns SHA-1 signing certificate as 40 hex characters with no
  delimiters.
- Flutter cannot override `X-Android-Package` or `X-Android-Cert`.
- PKJS contains no provider calls.

Fake HTTP tests:

- Correct package/cert headers are attached to Map Tiles, Places, Geocoding,
  and Routes requests.
- Intentionally wrong package/cert headers produce typed permission failure in
  the fake provider.
- Typed permission failure maps to unsupported or provider-permission status
  according to `BYOK_PROVIDER_POLICY.md`.

Live opt-in tests:

- With a restricted test key, correct package/cert validation succeeds for each
  endpoint class used by MVP.
- With intentionally wrong package/cert headers, each endpoint class rejects the
  request.
- If any direct REST endpoint accepts wrong Android identity, MVP provider setup
  is blocked and no backend fallback is enabled.

Live tests must redact the key and may be skipped on machines without Android
signing identity access.

## Protocol Replay Tests

Replay harness must be able to run without a physical watch:

- Inject fake inbound watch dictionaries.
- Observe outbound phone dictionaries.
- Simulate ACK/NACK callbacks.
- Inspect diagnostics.

Required replay scripts:

- Startup with no key.
- Startup with valid setup and GPS.
- Tile request success and NACK drop.
- Destination push.
- Route request success.
- Route request no-route.
- Next nav-step request.
- Route clear.
- Centered map orientation change.
- Location denied.
- Provider network failure.

The replay harness should share constants with production protocol code.

## Golden Data Storage

Golden files live under a test fixture directory owned by the implementation,
for example:

```text
test/fixtures/provider/
test/fixtures/tiles/
test/fixtures/routes/
```

Golden files must not contain:

- Real API keys.
- Real provider session tokens.
- User home/work addresses.
- Precise user routes.

Use synthetic coordinates and fake addresses unless a public fixture location is
needed. Public fixture locations must be clearly marked.

## Coverage Matrix

| Area | Unit | Replay | Android fake | Live opt-in |
| --- | --- | --- | --- | --- |
| Key missing/invalid | yes | yes | yes | optional |
| Android headers | yes | no | yes | yes |
| Tile crop/RLE | yes | yes | no | optional |
| Geocode normalize/errors | yes | yes | yes | optional |
| Route simplify/steps | yes | yes | yes | optional |
| Queue ACK/NACK | yes | yes | no | no |
| Diagnostics redaction | yes | yes | yes | no |

## Acceptance Criteria

- Default tests prove provider workers can run without project-hosted backend
  endpoints.
- Golden tile RLE round-trips losslessly.
- Crop boundary tests cover one, two, and four source tiles.
- Routing tests cover success, no-route, malformed, and all MVP error
  categories.
- Restricted-key header logic is covered by fake tests and has a documented
  live opt-in validation path.
- Protocol replay covers watch commands required by MVP.
- Test fixtures contain no real credentials or private user data.
