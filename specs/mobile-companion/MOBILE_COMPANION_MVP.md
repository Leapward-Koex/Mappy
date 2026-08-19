# Mobile Companion MVP Spec

This spec defines the Android-first Flutter companion for the backend-free
Mappy MVP. The mobile companion is the authoritative phone
runtime. It owns user configuration, Google API access, phone location, Pebble
transport, map tile generation, route fetching, nav-step generation, and
diagnostics export.

## MVP Responsibilities

The mobile companion must:

- Let the user enter and validate their own Google API key.
- Store the key locally and securely.
- Explain which Google APIs must be enabled.
- Request and track phone location permission.
- Maintain the active navigation target, optional saved locations, and display
  settings.
- Own the Android native Pebble AppMessage bridge.
- Respond to watch tile, route, settings, and diagnostic messages.
- Generate map tile payloads locally on the phone.
- Call Google Places Autocomplete/Place Details, Geocoding, Routes, and Map
  Tiles APIs directly from the phone.
- Keep a bounded local diagnostic log and export it on user request.

The mobile companion must not:

- Depend on any project-hosted application backend.
- Upload logs, location, routes, destinations, or API keys to an application
  server.
- Compile a Google API key into source, assets, package metadata, release
  artifacts, or JS bundle. Local debug/profile builds may use the development
  hardcoded-key exception defined in `../shared/SECURE_STORAGE_SPEC.md`.
- Require account services, Google Maps notification-listener access, Timeline
  tokens, or voice features for MVP.

## Platform Scope

| Platform | MVP status |
| --- | --- |
| Android | Required |
| iOS | Scaffold only until a Pebble transport strategy is specified |

Android package and signing values may remain development defaults during local
development, but BYO Google key setup depends on stable package/signing
identity. The setup UI or docs must show the active package name and SHA-1
fingerprints for debug/release builds. Final app ID and release signing are a
pre-public-MVP gate.

The BYO key setup must tell users to apply both:

- Android application restriction for the active package and SHA-1 certificate,
- API restrictions for Map Tiles API, Places API, Geocoding API, and Routes API.

The app must not recommend unrestricted keys for MVP.

## Android Runtime Architecture

Flutter owns UI state and user interactions. Android native code owns durable
credential storage and platform integrations that Flutter cannot safely or
directly perform:

```text
Flutter UI/state
  -> destination/settings repository
  -> diagnostics repository
  -> redacted API key status view
  -> Android native Pebble bridge
       -> PebbleKit Android 2 listener service
       -> watch-session foreground service
       -> secure API key storage and validation
       -> AppMessage queue
       -> phone location provider
       -> Google provider adapters
       -> tile encoder
       -> route/nav-step worker
       -> watch command dispatcher
```

The native bridge exposes a small Flutter method/event channel API:

| Channel operation | Direction | Purpose |
| --- | --- | --- |
| `storeApiKey` | Flutter -> native | Pass user-entered key once for native secure storage. |
| `clearApiKey` | Flutter -> native | Remove stored key and stop credentialed work. |
| `getBridgeStatus` | Flutter -> native | Return watch/setup/provider/location/notification/foreground-service status snapshot. |
| `startWatchApp` | Flutter -> native | Request that Pebble/Rebble open the Mappy watch app and return updated status. |
| `requestNotificationPermission` | Flutter -> native | Request `POST_NOTIFICATIONS` when Android requires it for the watch-session notification and return updated status. |
| `validateProviderSetup` | Flutter -> native | Trigger provider validation. |
| `searchPlaces` | Flutter -> native | Return Google Places Autocomplete predictions for Navigate Now origin/destination search or saved-location editing. |
| `resolvePlace` | Flutter -> native | Resolve a selected place or geocoded free-form origin/destination into route-ready coordinates. |
| `startNavigation` | Flutter -> native | Start routing from current location or a resolved explicit origin to a resolved ad-hoc or saved-location target. |
| `setDestinations` | Flutter -> native | Push normalized saved-location records. |
| `setDestination` | Flutter -> native | Patch one normalized saved-location record. |
| `setSettings` | Flutter -> native | Push theme, units, travel mode, backlight, centered map orientation, tile animation, haptics, and navigation glance. |
| `setMapTileSettings` | Flutter -> native | Push map source and rendered tile size. |
| `requestLocationPermissionState` | Flutter -> native | Return permission state and prompt availability. |
| `clearCaches` | Flutter -> native | Clear tile, route, or provider-validation cache/status. |
| `clearDiagnostics` | Flutter -> native | Clear local diagnostic events. |
| `exportDiagnostics` | Flutter -> native | Produce redacted log export. |
| `bridgeStatus` | native -> Flutter | Watch/setup/provider/location/notification/foreground-service readiness. |
| `diagnosticEvent` | native -> Flutter | Append bridge/watch logs. |

No server or cloud sync is allowed between these components.

## Android Permissions

MVP permission matrix:

| Permission/capability | Required | Use |
| --- | --- | --- |
| `INTERNET` | Yes | Direct Google API calls. |
| Fine location | Yes | GPS world pixels, default current-location route origin, map recentering. |
| Coarse location | Optional fallback | Degraded map recentering if user denies fine location. |
| Background location | Yes, for active watch sessions | Required so a watch-started location foreground service can keep streaming after the Flutter activity backgrounds. This is not general always-on navigation when the watch app is inactive. |
| Foreground service | Yes, watch-session only | Required while the Pebble watch app is actively bound to and requesting work from the companion. |
| Foreground service location type | Conditional | Required when the watch-session foreground service reads live phone location. |
| Notification permission | Conditional | Request only when the target Android version and notification UX require it for the foreground-service notification; denial must be surfaced without crashing. |
| Bluetooth permissions | Confirm during implementation | Use only if the chosen PebbleKit integration requires direct Bluetooth permissions on target Android versions. |
| Notification listener | No | Google Maps notification companion mode is non-MVP. |
| Share intent filter | Yes | Accept explicit `text/plain` Google Maps shares; it grants no background access. |
| Microphone | No | Voice dictation is non-MVP. |

The app must present missing permission states in the UI and send
`CMD_ERROR_STATE` category 3 to the watch when location is unavailable.
The release manifest must declare `INTERNET`, `ACCESS_FINE_LOCATION`, and
`ACCESS_COARSE_LOCATION`; debug/profile-only permissions are not sufficient.
It must also declare the watch-session foreground-service permissions and
service type required by `ANDROID_PEBBLE_BRIDGE_SPEC.md`.

MVP navigation may run while the watch app is open because that is a
user-visible watch session with an Android foreground-service notification. This
does not grant general always-on background navigation. If the watch app is not
active, the app must not continue live navigation in the background unless a
future background-navigation spec adds background-location permission, battery
policy, and user controls. If Android platform rules prevent a legal
watch-started location foreground service on a target device, the app must
surface a setup/status error instead of silently pretending navigation is live.
The companion must not pause the live watch GPS stream merely because the
Flutter activity is backgrounded while the watch-session foreground service or
active watch app is still present.
The setup flow must distinguish foreground location from all-the-time
background location. After foreground location is granted, route the user to
Android app settings for the background grant on Android versions that require
that path.

## Google API Key

User workflow:

1. User opens Setup/API Key.
2. User enters a Google API key.
3. Flutter sends the entered key once to Android native via `storeApiKey`.
4. Android native stores the key locally using secure storage backed by the
   Android Keystore where available.
5. Android native validates the key with the provider checks below and emits
   redacted status to Flutter.
6. UI shows one of:
   - not configured,
   - validating,
   - valid,
   - invalid key,
   - API disabled,
   - quota/billing issue,
   - network unavailable.

Development workflow:

- During local development, the Android app may seed secure storage from an
  ignored local hardcoded key in `android/local.properties` or equivalent build
  configuration.
- This path exists only for debug/profile provider testing. It must still route
  through Android native secure storage before provider use, and Flutter must
  only receive redacted key status.
- The native layer must mark development-seeded credentials separately from
  user-entered credentials. Startup seeding must not overwrite a user-entered
  key, and user-entered keys must use normal provider validation.
- For this development-seeded key only, debug/profile builds may allow an
  unrestricted Google key so live emulator/device verification can exercise Map
  Tiles, Geocoding, and Routes before production signing/restriction setup is
  complete.
- Release builds must not include the hardcoded development key.

Required enabled APIs for MVP:

- Google Map Tiles API.
- Google Places API.
- Google Geocoding API.
- Google Routes API.

Validation must not log the full key. Logs may include only a short redacted
prefix/suffix such as `AIza...abcd`.

The key is read by native runtime only at request time. Flutter receives only
redacted status after initial entry. The key is never sent to the watch and never
written to diagnostics export.

### Direct REST Authorization

All direct Google REST calls are issued by Android native code, not Flutter or
PKJS. Every Map Tiles, Places, Geocoding, and Routes request must include:

| Header | Value |
| --- | --- |
| `X-Android-Package` | `Context.getPackageName()` for the running app |
| `X-Android-Cert` | SHA-1 digest of the active signing certificate as 40 hex characters with no colons, spaces, or prefixes |

`X-Android-Cert` is derived from `PackageInfo.signingInfo` or the current
Android equivalent. The Cloud Console setup UI/docs may display the
colon-delimited SHA-1 fingerprint for user entry, but the HTTP header must use
the delimiter-free hex form.

Flutter must not supply or override these headers. Native code computes them for
each request. Diagnostics may report whether the header values were present, but
must not export full API keys.

Validation checks:

- Map Tiles API: create a session using the currently configured map source from
  `../shared/MAP_TILE_PIPELINE_MVP.md`. Validation must cover the default road
  source and any user-selected satellite, hybrid, or terrain source before
  treating it as usable.
- Geocoding API: perform a low-cost known-address or user-entered
  origin/destination validation only when needed.
- Places API: perform autocomplete and place detail requests only during
  Navigate Now search or saved-location editing; use field masks to request only
  prediction text, place IDs, formatted addresses, and coordinates needed for
  routing.
- Routes API: validate with the first real route request or a minimal route
  check only when the user asks to test routing.
- Restriction negative test: for each direct Google REST endpoint class used by
  MVP, native validation must repeat a low-cost request with an intentionally
  wrong `X-Android-Package` or `X-Android-Cert`. The expected result is
  authentication/permission rejection. If wrong headers are accepted, mark that
  endpoint unsupported for backend-free MVP and surface category 2 with setup
  text. Do not suggest an unrestricted key as the fix.

Map Tiles session tokens are keyed by API key hash, language, region, map type,
layer types, overlay flag, scale, and high-DPI flag. Session tokens and API keys
must be redacted in logs.

Provider status mapping:

| Provider condition | UI/watch category |
| --- | --- |
| No key stored | 1 missing key |
| Authentication failure/API disabled | 2 invalid key/API disabled |
| Quota, billing, or permission denied | 2 invalid key/API disabled |
| Network/DNS/timeout | 4 network unavailable |
| Map Tiles session/tile failure | 5 tile provider failure |
| Routes failure | 6 route provider failure |
| Geocoding no result for configured origin/destination | 6 route/geocoding provider failure |

## Navigation Search And Saved Locations

The primary route-starting workflow is Navigate Now search:

1. User keeps `From: Current location` or searches for a specific origin.
2. User types a destination place or address in the Flutter navigation search.
3. Native returns Google Places Autocomplete predictions using the stored key and
   Android package/cert headers.
4. User selects the destination prediction, and selects an origin prediction
   only when not using current location.
5. Native resolves Place Details needed for routing: label, formatted address,
   place ID, latitude, and longitude.
6. Native starts the route worker immediately with the selected origin policy,
   the resolved destination, and the selected/default travel mode.
7. The watch receives the normal `CMD_ROUTE_POINTS` and `CMD_NAV_STEPS`
   payloads and displays navigation. `CMD_ROUTE_POINTS` includes `is_color`
   with the selected travel mode because no watch-originated route request
   preceded this flow.

This flow must not require a saved-location record. It must not mutate saved
locations unless the user explicitly chooses a save action.

Free-form typed origins or destinations may start navigation only after native
geocoding resolves coordinates. Geocoding must happen through the same provider
adapter and error mapping as saved-location geocoding.

Origin behavior:

- Current location is the default origin.
- Current-location origin requires a fresh GPS fix for route fetch.
- User may choose a specific origin by searching a place/address through Google
  Places Autocomplete and resolving it with Place Details or Geocoding.
- Specific-origin route fetch does not require a fresh GPS origin, but live
  watch progress must remain degraded until current phone GPS can be projected
  onto the route.

Saved locations are secondary convenience shortcuts for repeated destinations
and watch-only route starts.

MVP destination fields:

```text
saved_location_id: 0..253 (254 and 255 reserved by the watch protocol)
kind: home | work | custom
label: user-facing short label
address_text: editable address/search text
lat/lng: resolved coordinate, optional until geocoded
place_id/provider_id: optional provider metadata
travel_mode_default: walk | bike | drive
last_geocoded_at
geocode_status
```

Destination editing behavior:

- User can add, edit, and clear saved locations as a dynamic list, bounded by
  the watch protocol destination payload count.
- App validates label length and required address/coordinate data.
- App offers Google Places Autocomplete while the user edits destination search
  text.
- Selecting an autocomplete prediction resolves Place Details through native
  provider code and stores the selected place ID, formatted address, and
  coordinates.
- App geocodes changed free-form destinations with the user's key when no place
  prediction is selected.
- App stores resolved coordinates locally.
- App pushes a v1 `CMD_DESTINATIONS` payload to the watch after
  successful save or coordinate change.
- Empty placeholder slots are not rendered in Flutter or on the watch. If the
  watch sends a stale, missing, disabled, or reserved saved-location ID, the
  bridge returns `CMD_ERROR_STATE` category 8 without geocode or route provider
  calls.
- Saving a location is optional and must not be part of the default navigate-now
  flow.

## Settings

MVP settings:

| Setting | Source of truth | Watch sync |
| --- | --- | --- |
| Theme auto/day/night | Phone UI, watch can report startup persisted value | `CMD_THEME` |
| Units imperial/metric | Phone UI | `CMD_UNITS` |
| Travel mode default | Phone UI, watch can change current mode | `CMD_TRAVEL_MODE` |
| Backlight auto/always | Phone UI, watch can report startup persisted value | `CMD_BACKLIGHT` |
| Haptics all/turns/arrival/off | Phone UI, watch can report and change persisted value | `CMD_HAPTIC_MODE` |
| Navigation glance all/turns/arrival/off | Phone UI, watch can report and change persisted value | `CMD_GLANCE_MODE` |
| Centered map orientation north-up/face-forward | Phone UI, watch can report startup persisted value | `CMD_MAP_ORIENTATION` |
| Tile animation none/fade/fade+zoom | Phone UI, watch can report startup persisted value | `CMD_TILE_ANIMATION` |
| Map source | Phone UI | `CMD_MAP_SETTINGS` invalidates watch tile cache |
| Rendered tile size | Phone UI | `CMD_MAP_SETTINGS` invalidates watch tile cache |
| Diagnostics capture | Phone UI | Local only, optional `CMD_LOG_EVENT` behavior |

On watch reconnect, the phone reconciles state without blindly overwriting
watch-owned startup values. User changes made in the phone UI after reconnect
take precedence and are pushed to the watch.

Centered map orientation is a display setting specified by
`../shared/MAP_ORIENTATION_SETTING_SPEC.md`. Changing it must persist locally and
send `CMD_MAP_ORIENTATION`, but it must not call `setMapTileSettings`, clear
Google provider sessions, clear phone tile caches, or refresh the active route.
If the watch is manually panned, the new preference applies when the user
recenters rather than forcing an immediate camera jump.

Tile animation is a display setting specified by
`../watch/WATCH_TILE_LOAD_ANIMATION_SPEC.md`. Changing it must persist locally
and send `CMD_TILE_ANIMATION`, but it must not call `setMapTileSettings`, clear
Google provider sessions, clear phone tile caches, re-request visible tiles, or
refresh the active route.

Haptics and Navigation glance are independent display settings. Both default to
All, use `0` off, `1` turns, `2` arrival, and `3` all, and synchronize in both
directions. Changing either affects future one-shot navigation events only and
must not clear provider state, restart navigation, or replay a consumed alert.

### Map Tile Settings

Flutter must expose map tile settings that are understandable as source and
rendered-size choices, not provider jargon:

| User setting | Values | Native mapping |
| --- | --- | --- |
| Map source | Road, satellite, hybrid, terrain | Google Map Tiles `mapType`, `layerTypes`, and `overlay` as defined in `../shared/MAP_TILE_PIPELINE_MVP.md` |
| Rendered tile size | Supported watch tile crop presets | Watch tile crop width/height, cache keys, and `CMD_MAP_SETTINGS` width/height |

Defaults:

- Map source: road.
- Rendered tile size: compact `54x63` baseline.
- Provider session profile: `scaleFactor1x`, `highDpi = false`, and omitted
  `imageFormat`.
- Watch tile encoding: nearest-palette quantization.

Changing any map tile setting must be atomic from the user's perspective:

1. Persist the new setting locally.
2. Clear affected Map Tiles sessions, source tile cache, encoded tile cache, and
   in-flight tile work.
3. Create or lazily create a provider session for the new setting.
4. Send `CMD_MAP_SETTINGS` to the connected watch so it clears visible tile
   cache entries.
5. Leave current GPS, route, destinations, and watch UI state intact while fresh
   tiles load.

If a selected source is rejected by Google, unsupported for the user's key,
unavailable in the current region, too large for local memory, or unable to fit
the negotiated AppMessage payload, native must revert to the last known usable
setting or keep stale tiles visible and surface a recoverable tile provider
error. It must not silently fall back to a
different map source without a visible status.

## Location

The native bridge obtains phone location updates from Google Play services
`FusedLocationProviderClient` and converts them to zoom-16 world pixels.

GPS update behavior:

- Send `CMD_GPS` when position changes enough to move the watch marker or at a
  bounded interval while connected.
- Request live updates at an approximately one-second, one-meter cadence while
  the watch session is active, and force a resend of the latest fresh accepted
  fix within a few seconds even if the rounded watch pixel has not changed.
- The foreground-service/headless runtime owns the live stream; Flutter UI may
  observe stream status and initiate setup actions, but the stream must not
  depend on an open Activity.
- Include heading/course degrees when valid.
- Send heading sentinel `-1` when unavailable.
- Filter live updates before sending: reject stale fixes, out-of-order
  monotonic timestamps, recent network/coarse fixes that would override fresher
  GPS fixes, implausible non-GPS jumps, and large accuracy regressions.
- Stamp each watch-bound GPS message with the optional protocol metadata
  `gps_sequence`, `gps_elapsed_ms`, `gps_accuracy_cm`, and `gps_provider`.
- Persist last known location locally only if useful for fast startup; clearly
  mark it stale in diagnostics and do not route from stale location without a
  fresh fix or user confirmation.

Location freshness thresholds:

| Threshold | Value | Behavior |
| --- | ---: | --- |
| `location_fix_fresh_for_routing` | 20 seconds | Required for current-location route origins and reroutes. Older current-location origins return `CMD_ERROR_STATE` category 3. |
| `location_fix_stale_for_ui` | 60 seconds | Older fixes are marked stale in Flutter/watch status and suspend route progression. |
| `location_seed_max_age` | 30 minutes | Last known location may seed a non-routing startup map state only if clearly marked stale. |

Stale locations may keep prior map tiles visible, but they must not trigger new
route provider calls for current-location origins or imply live navigation
progress. Explicit-origin route planning may still fetch a route after the
origin resolves, but watch progress remains degraded until fresh GPS exists.

## Map Tile Worker

The tile worker implements `../shared/MAP_TILE_PIPELINE_MVP.md`:

- Maintains Google Map Tiles session tokens.
- Fetches source tiles for the selected road, satellite, hybrid, or terrain
  configuration with the user's key.
- Reads pixels into a phone-local buffer.
- Generates 54x63 watch crops.
- Applies day/night palette mapping.
- RLE-encodes payloads.
- Sends `CMD_TILE`.
- Sends `CMD_ERROR_STATE` on setup/provider failures.

Cache requirements:

- Source tile cache is bounded by count and memory.
- Encoded watch tile cache is bounded and keyed by x/y/zoom/theme plus every map
  tile setting that affects output bytes.
- Cache clear control is exposed in diagnostics/settings.
- Cache policy must respect current Google response headers and terms.
- Tile worker state machine: idle, waiting_for_key, waiting_for_location,
  creating_session, loading_sources, encoding, sending, failed.
- Duplicate tile requests are deduped by world x/y/zoom/theme.
- Stale in-flight tile work is cancelled or ignored after zoom/theme changes.
- Oversized or repeatedly NACKed tiles send `CMD_ERROR_STATE` category 5 with
  failed command ID and tile x/y/z echoed as defined in
  `../shared/PROTOCOL_MVP.md`.

## Routing Worker

Route target sources:

| Source | Route target |
| --- | --- |
| Flutter Navigate screen | Resolved ad-hoc place/address with label, formatted address, optional place ID, and coordinates. |
| Flutter saved-location shortcut | Saved-location record. |
| Watch saved-location menu | `CMD_ROUTE_REQUEST` slot index and travel mode. |
| Watch reroute | Active route target cached by the phone. |

Route origin sources:

| Source | Route origin |
| --- | --- |
| Default Navigate Now | Fresh current phone GPS. |
| Explicit Navigate Now origin | Resolved place/address with label, formatted address, optional place ID, and coordinates. |
| Watch saved-location route | Fresh current phone GPS. |
| Reroute | Active route origin policy cached by the phone. |

Route request flow:

1. Receive a route request from Flutter `startNavigation`, a Flutter
   saved-location shortcut, or watch `CMD_ROUTE_REQUEST`.
2. Normalize the request into a route origin and route target. For watch
   requests, origin is current location and target is the saved location loaded
   by slot.
3. Ensure current location is fresh enough when the origin policy is current
   location. MVP freshness threshold is 20 seconds.
4. Resolve or geocode the explicit origin and destination only if coordinates
   are missing/stale.
5. Call Google Routes API `computeRoutes` directly from the phone.
6. Request fields needed for MVP only:
   - duration,
   - distance,
   - encoded polyline,
   - route legs/steps with navigation instruction, distance, duration, and
     start location where available.
7. Decode polyline.
8. Simplify/downsample to the watch route point cap.
9. Build nav-step chunks.
10. Store the active route target locally for reroute.
11. Send `CMD_ROUTE_POINTS`, including `is_color` with the active route travel
    mode (`0` walk, `1` bike, `2` drive).
12. Send first `CMD_NAV_STEPS` chunk.

Route worker state machine: idle, waiting_for_key, waiting_for_location,
geocoding, fetching_route, simplifying, sending_route, sending_steps, failed.
The worker stores the full normalized step list locally so watch
`CMD_NAV_STEPS` requests can be answered without another Google request.

Travel mode mapping:

| MVP mode | Google Routes mode |
| --- | --- |
| walk | `WALK` or current equivalent |
| bike | `BICYCLE` or current equivalent |
| drive | `DRIVE` |

Transit is not MVP.

When `walk` or `bike` is selected or displayed, Flutter must show a warning that
the route mode is beta and may be missing safe pedestrian or bicycling path
detail. The warning must appear in travel-mode setup and active route status.
The watch also shows a compact warning while an active walk/bike route is
displayed.

No-route behavior:

- Send zero-point `CMD_ROUTE_POINTS`.
- Then send `CMD_ERROR_STATE` category 7 with short text.

Reroute behavior:

- User-triggered reroute repeats the route request for the active route origin
  policy and active route target. Current-location origins use fresh GPS;
  explicit origins reuse the resolved origin unless the user changes it.
- Automatic off-route reroute is not MVP.

## Pebble Transport

The Android native bridge owns:

- watch app UUID configuration,
- PebbleKit Android 2 dependency and initialization,
- manifest-declared `BasePebbleListenerService` binding for
  `io.rebble.pebblekit2.RECEIVE_DATA_FROM_WATCH`,
- watch package `companionApp.android.apps` metadata for the Mappy
  companion package IDs,
- watch-session foreground service lifecycle,
- Android package visibility/queries needed to discover Pebble/Rebble services,
- Android 12+ Bluetooth permission decision if the selected integration needs
  direct Bluetooth access,
- AppMessage registration,
- method/event channels to Flutter,
- one logical outbound send queue,
- ACK/NACK handling,
- reconnect handling,
- inbound command dispatch.

Watch-session service behavior:

- Starting the watch app must wake the native listener service without requiring
  the Flutter activity to be opened manually.
- `onAppOpened` or the first valid `CMD_INIT` starts the foreground service.
- `onAppClosed`, active-app reconciliation, disconnect grace timeout, or the
  idle watchdog defined in `ANDROID_PEBBLE_BRIDGE_SPEC.md` stops it.
- The service notification must be neutral and must not disclose precise route,
  destination, location, or credential details.

Queue behavior:

- Control messages and GPS updates may jump ahead of tile payloads.
- Tile sends are dropped after three NACK callbacks, meaning three total failed
  send attempts.
- Route and destination sends should be reported visibly on failure.
- Do not run a second PKJS responder in parallel.

Implementation must add the native components, dependencies, package visibility,
and runtime permission handling needed for the selected PebbleKit integration.
The current `MainActivity` scaffold is not sufficient by itself.

## Watch Error Matrix

| Failure | Watch command | Correlation fields | Retry/backoff | Route/map clearing |
| --- | --- | --- | --- | --- |
| Missing key | `CMD_ERROR_STATE` category 1 | failed command ID | none until key changes | keep prior map/route |
| Invalid/API disabled/quota/billing/permission denied | category 2 | failed command ID, HTTP/status code in diagnostics only | exponential/manual retry | keep prior map/route unless request was no-route |
| Current-location origin permission/fix/stale unavailable | category 3 | failed command ID | retry on permission/location change | suspend route progression |
| Network unavailable | category 4 | failed command ID | bounded exponential retry for tiles; manual or connectivity retry for routes | keep stale data |
| Tile provider failure | category 5 | tile x/y/z, `chunk_index = CMD_TILE_REQUEST` | max three failed send attempts per tile | keep stale/blank tile |
| Route provider failure | category 6 | diagnostics route target ID; `chunk_offset` saved-location ID when present, otherwise 0 | manual retry/reroute | keep prior route unless request explicitly clears |
| No route found | zero-point `CMD_ROUTE_POINTS`, then category 7 | diagnostics route target ID; `chunk_offset` saved-location ID when present, otherwise 0 | manual retry/reroute | clear active route |
| Saved-location ID missing/unconfigured | category 8 | saved-location ID | retry after saved-location edit | keep map |
| Explicit origin or destination geocode has no result | category 6 | diagnostics route target ID; `chunk_offset` saved-location ID when present, otherwise 0 | retry after search or saved-location edit/geocode | keep map |

All watch error text is capped at 47 UTF-8 bytes on code point boundaries.

## Diagnostics

Diagnostic log sources:

- mobile UI actions,
- permission/key status changes,
- Google API failures,
- tile worker failures,
- route worker failures,
- watch `CMD_LOG_EVENT`,
- Pebble transport ACK/NACK and reconnect events.

Log rules:

- Bounded ring buffer.
- Stored locally.
- Export only by explicit user action.
- Redact API keys, precise access tokens, and any obvious credential-like text.
- Include a cache-clear control.
- Include enough protocol context to debug tile and route failures: command ID,
  tile x/y/z, route target ID, saved-location ID when present, error
  category, and HTTP status where safe.

Static/replay guardrails:

- No project-hosted application-service endpoint.
- No account, subscription, or credential-relay flow.
- No undocumented or unauthenticated provider tile URL.
- No Pebble Timeline calls.
- No notification-listener access.
- Input that is not shaped like a Google API key is rejected locally without a
  network request.

## Remaining Release And Verification Gaps

The Flutter/Android implementation now includes the major MVP slices: secure
key storage, native provider calls, location permission, PebbleKit bridge,
watch-session foreground service, map tile and routing workers, Google Maps
share intake, saved
locations, settings, diagnostics, first-run welcome, and first-class Navigate
UI. Remaining gates before public MVP:

- Verify the watch-session foreground-service lifecycle on target Android
  versions, including Android 12+ background-start and Android 14+ while-in-use
  location restrictions.
- Verify `POST_NOTIFICATIONS` request/denial behavior on Android versions that
  require it for visible foreground-service notifications.
- Complete hardware/emulator evidence for watch app open/close, `CMD_INIT`,
  tile request/response, route/reroute, permission denial, and diagnostics
  export flows.
- Configure final release package/signing and document debug/release SHA-1
  fingerprints before public MVP.
- Review current provider terms, attribution, and cache policy before release.
- Keep welcome/showcase copy aligned with UI changes that move, rename, or
  change the meaning of guided controls.

## UI Scope

MVP screens:

- First-run welcome and replayable guided tour.
- First-class Navigate/search.
- Status/readiness dashboard.
- Google API key setup and validation status.
- Permissions status.
- Saved locations editor.
- Display settings.
- Diagnostics/log export.

The UI should make backend-free operation explicit: the user supplies their own
Google API key, and all route/map work is performed locally on their phone.

## Acceptance Criteria

- App starts with no key and shows setup state without making Google requests.
- User can save a key and see validation status.
- Restricted-key validation uses native Android package/cert headers and rejects
  an intentionally wrong package/cert before direct Google REST is enabled.
- Missing/invalid key is surfaced to the watch through `CMD_ERROR_STATE`.
- Android permission denial is surfaced in UI and to the watch.
- Navigate-now search can resolve a Places prediction and start a route without
  saving a saved-location record.
- Successful phone-started navigation shows an active-route summary and
  reroute/clear controls on the phone.
- Flutter exposes Open Watch/Start Watch and notification-permission recovery
  actions in welcome/status surfaces.
- Saved-location edits persist locally and push `CMD_DESTINATIONS`.
- A route request from the watch triggers direct phone-side Google Routes API
  call when setup is valid.
- Starting the watch app starts the native companion session and foreground
  service without manually opening the Flutter UI.
- Closing the watch app stops the watch-session foreground service after its
  grace period when no required work remains.
- Walk and bike route modes show the required warning in mobile route UI and on
  the watch active-route display.
- Centered map orientation changes are persisted and pushed to the watch without
  clearing provider caches or restarting navigation.
- A supported Google Maps share is parsed on cold or warm start and recomputed
  through Mappy's configured provider before route output is sent to the watch.
- A tile request from the watch triggers phone-side Map Tiles API source tile
  fetch and RLE tile response when setup is valid.
- Logs can be exported and do not contain the full API key.
- No code path requires a project-hosted server URL.
- Static checks prove no application backend, notification-listener, or
  unrelated credential flow is present in MVP code.
