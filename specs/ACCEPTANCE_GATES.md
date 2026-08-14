# Acceptance Gates

This document collects verification gates for the Mappy spec set. Each
gate should be backed by automated tests, emulator/device checks, or explicit
manual release checks before the corresponding milestone is considered done.

## Static Architecture Gates

- Source scan finds no application-service endpoint outside the provider hosts
  documented by the shared specs.
- Release code contains no account, entitlement, or subscription flow;
  credentials enter only through Mappy's setup UI and remain in app storage.
- PKJS scan finds no `fetch`, `XMLHttpRequest`, `localStorage`,
  `Pebble.addEventListener('appmessage'...)`, provider endpoint, notification
  listener, share listener, or config-webview runtime in
  the production `phone` build.
- Fixture-mode PKJS responders are selected only by
  `MAPPY_WATCH_PHONE_MODE=fixture|real-fixture` or explicit emulator tooling
  commands, and contain no API keys or runtime network calls. Provider-derived
  real-fixture data remains a local, ignored input.
- Package metadata contains no unplanned companion URL, share target,
  notification filter, microphone capability, or unneeded location capability.
- Package metadata contains the Mappy Android companion package entry
  required for PebbleKit Android 2 bound-service communication.
- No Mappy code recommends unrestricted Google API keys.

## BYOK Provider Gates

- Fresh install with no key makes no Google map, geocode, or route request.
- User can store, validate, and clear a Google API key.
- Logs and UI show only redacted key status.
- Google Map Tiles API validation can create the default roadmap session with
  correct Android package/cert headers.
- User-selected Map Tiles source settings create fresh sessions for road,
  satellite, hybrid, and terrain configurations where enabled for the user's
  key.
- Google Places, Routes, and Geocoding calls include native-computed
  `X-Android-Package` and `X-Android-Cert` headers.
- Negative restriction tests with intentionally wrong package or cert are
  rejected for each direct REST endpoint class used by MVP.
- If any direct REST endpoint accepts wrong Android identity, the provider path
  is blocked and there is no backend fallback.
- There is no OSM/Nominatim fallback in MVP tests or runtime.

## Protocol Gates

- `py -3 tooling/test-protocol-consistency.py` (or `python3` on Unix) verifies
  message keys, command IDs, and watch UUID across `package.json`, C, Kotlin,
  Dart, the protocol spec, synthetic fixture, any present local real fixture,
  and emulator shell commands.
- Unit tests round-trip:
  - destination payloads,
  - route point payloads,
  - nav-step payloads,
  - error payloads,
  - tile RLE payloads.
- Unit tests round-trip `CMD_MAP_ORIENTATION` as the centered-map orientation
  preference and normalize unsupported orientation values to north-up.
- Unit tests round-trip `CMD_TILE_ANIMATION` and normalize unsupported animation
  values to no animation.
- Unit tests round-trip `CMD_HAPTIC_MODE` and `CMD_GLANCE_MODE`; missing or
  unsupported values normalize to All.
- Watch decode tests reject malformed, truncated, oversized, and unsupported
  payloads without fixed-buffer overflow.
- Phone replay tests can handle `CMD_TILE_REQUEST`, `CMD_ROUTE_REQUEST`, and
  `CMD_NAV_STEPS` without a physical watch.
- Phone/watch replay tests can apply `CMD_MAP_ORIENTATION` without clearing
  route, GPS, destination, or nav-step state.
- Phone/watch replay tests can apply `CMD_TILE_ANIMATION` without clearing
  route, GPS, destination, nav-step, provider, or tile-cache state.
- Phone/watch replay tests can apply haptic and glance presets independently
  without clearing state or replaying consumed feedback events.
- Phone/native tests can start a route from a resolved autocomplete destination
  without a saved-location record.
- Missing setup state returns `CMD_ERROR_STATE` rather than silent failure.
- No-route response sends zero-point `CMD_ROUTE_POINTS`, no nav steps, then
  category 7 error.

## Watch Gates

- Watch boots with no phone and shows `WAITING_FOR_PHONE`.
- Watch boots with phone but missing key and shows setup-required state.
- Watch handles repeated `CMD_INIT`, settings, destination, GPS, and route
  updates idempotently.
- Watch renders a nonblank map on `emery` after GPS and visible tiles arrive.
- Visible tile cache covers full target screen for worst-case crop alignment.
- On real `emery` hardware with `PBL_TOUCH` enabled, single-finger pan changes
  the viewport and produces only normal tile requests.
- A qualifying recent fast liftoff coasts watch-locally in the release direction
  for 1..12 logical 30 ms ticks, no more than 360 ms and approximately 70 px.
  Slow, tap, held, and stale releases settle immediately.
- Tile requests and new tile-response decoding remain paused during drag and
  kinetic coast, and kinetic scheduler frames do not initiate route-detail
  requests. Settlement rebuilds request coverage once and resumes normal tile
  requests once after the existing 100 ms grace period; the visible grid
  completes within 5 seconds without transfer error.
- A new touchdown interrupts kinetic coast at its current viewport without an
  intermediate request resume. Menu/modal opening, zoom, recenter, touch loss,
  and other button actions settle before acting; teardown cancels without
  restarting work.
- Kinetic pan uses the existing shared visual scheduler and adds no heap
  allocation or phone/protocol/settings surface. Measured with
  `arm-none-eabi-size` against an identical-mode baseline, it grows production
  data+BSS by at most 64 bytes and the production binary by at most 3 KiB.
- On real `emery`, kinetic pan meets p95 input-to-first-changed-frame latency of
  at most 100 ms, p95 north-up coast draw time of at most 50 ms, no coast draw
  over 100 ms, and settlement within 450 ms.
- On real `emery` hardware with reliable pinch or multi-touch data, pinch out
  zooms in and pinch in zooms out using only existing `CMD_BUTTON` zoom
  notifications plus normal tile requests. If smooth pinch zoom is not shipped,
  the discrete-level fallback and reason are documented.
- If real `emery` hardware exposes touch panning but no reliable pinch or
  multi-touch data, the capability probe result is documented and hardware
  buttons remain the required zoom fallback.
- Non-touch and disabled-touch builds retain hardware-button zoom and map/route
  operation with no touch-only dependency.
- Heap test includes decoded tile cache, 4,096-byte AppMessage inbox, route
  buffers, nav-step buffers, menus, layers, and fonts.
- Current-location glyph matches `watch/CURRENT_LOCATION_VIEW_CONE_SPEC.md`:
  blue puck, white halo, outlined 90-degree blue view cone when heading is valid.
- Invalid heading hides the view cone and leaves a neutral blue puck.
- Once the complete puck halo is off-screen, the glyph is replaced by a rounded
  one-third-width blue line with a white outline at the clamped GPS edge
  position and a 3 px clear outer gap. Two-axis overflow anchors at a connected
  90-degree corner bend.
- The edge line follows successive viewport redraws during manual panning and
  disappears when recenter makes the puck halo visible again.
- Direction-up GPS-follow orientation rotates map tiles, route, destination
  marker, and current-location cursor consistently around the viewport center
  while GPS-follow is active.
- Direction-up GPS-follow smooths plausible short GPS movements by animating
  the map under the centered current-location cursor; north-up smooths plausible
  short GPS movements by animating the current-location cursor itself.
- GPS movement beyond the adaptive elapsed-time and travel-mode limit snaps
  immediately and does not delay tile requests, route progress, or arrival
  checks.
- Facing-up falls back to north-up without stale direction display when the
  facing bearing is invalid or stale.
- Direction-up tile coverage includes the rotated viewport footprint and has no
  blank corners after requested tiles arrive.
- Manual pan from facing-up GPS-follow enters north-up manual-browse mode,
  suspends heading-driven map rotation, continues GPS/route progress updates,
  and provides a compact recenter action.
- Recenter restores GPS-follow and reapplies the selected centered-map
  orientation.
- Face-forward route start in Walk, Bike, and Drive uses the bounded fast
  bearing profile. A 180-degree target change remains animated and completes in
  no more than eight 30 ms ticks.
- During an active face-forward Walk route, deterministic walking-to-watch
  motion emits one look event and starts a 1.5-second fast-bearing window.
  Idle, short walks, stationary raises, closely spaced bumps, and vibration
  samples do not trigger it; another walking cadence rearms it.
- Opening a menu, manually panning, switching north-up, clearing/finishing the
  route, or leaving the app unsubscribes motion sensing and cancels fast
  reacquisition.
- Theme change clears visible tile cache and queues fresh tile requests.
- Walking and bicycling active routes display the provider warning.
- Walking active routes render as spaced blue dots with a white halo, including
  phone-started Navigate Now routes that did not originate from
  `CMD_ROUTE_REQUEST`.
- Walking route dots at or behind the current on-route GPS projection are hidden;
  moving the simulated GPS backward along the route reveals previously hidden
  dots.
- Bike and drive route lines are clipped at the current on-route GPS projection;
  moving the simulated GPS backward reveals previously hidden line segments.
- Fresh/user-visible walking route start emits one feedback event, switches to
  maximum supported map zoom, and requests visible tiles at that zoom. Only the
  All preset outputs that event.
- Upcoming non-final maneuvers consume one preview event before the turn and one
  turn-now event when due; repeating GPS positions or moving backward does not
  repeat either event, including when its outputs were disabled.
- Haptics and Glance independently implement All, Turns, Arrival, and Off. An
  enabled glance calls the transient interaction backlight API, does not latch
  the light, and remains independent of the face-forward wrist-look detector.
- Arrival always clears the trip and shows its modal even with both outputs Off.
- Changing Haptics cancels queued Mappy vibration. Navigation feedback follows
  its presets during Pebble Quiet Time.
- A sub-700 ms Select press retains its normal menu action. A hold of at least
  700 ms recenters once without opening Actions; menu holds are inert, arrival
  holds only dismiss the modal, and no-GPS holds show `Waiting for GPS`.
- Changing travel mode while a route is active queues a reroute and updates the
  route overlay style when the replacement route arrives.
- Zero-point route clears route and step state.
- Tile/provider failures do not erase a valid prior map.
- `capture-fixture` screenshots a nonblank synthetic-fixture map on the Pebble
  emulator without a connected phone.
- When local provider-map fixture files are present, `capture-real-fixture`
  screenshots them without altering the production or synthetic build modes.
- `capture-phone` screenshots the production phone-waiting path and does not
  bundle fixture responders.

## Mobile Companion Gates

- Android manifest declares only required MVP permissions and capabilities.
- Android launcher label is user-facing (`Mappy`) rather than a package or
  scaffold name.
- First launch shows the welcome flow; debug/support can replay it without
  clearing app data.
- Location permission denial is visible in Flutter and on watch.
- Notification permission state is visible in Flutter and requestable only from
  a user action when Android requires it for the watch-session foreground
  service.
- Navigate-now autocomplete search resolves a selected destination and starts
  routing without mutating saved locations.
- Navigate is a first-class recurring tab/screen, and successful navigation
  leaves a visible active-route summary on the phone.
- Saved-location edits persist locally and push a v1
  `CMD_DESTINATIONS`.
- Centered map orientation changes persist locally and push
  `CMD_MAP_ORIENTATION` without clearing provider caches or restarting active
  navigation. If the watch is manually panned, the setting takes effect on
  recenter rather than forcing an immediate camera jump.
- Tile animation changes persist locally and push `CMD_TILE_ANIMATION` without
  clearing provider caches, re-requesting tiles, or restarting active navigation.
- Haptic and glance changes persist locally, push their independent protocol
  commands, survive reconnect, and are editable from both watch and phone.
- Native bridge is the only AppMessage responder.
- Native bridge uses PebbleKit Android 2 bound-service communication, not the
  legacy `com.getpebble.action.app.*` broadcast protocol.
- Starting the watch app wakes the Android listener and starts the
  watch-session foreground service without the user manually opening Flutter.
- Flutter exposes an Open Watch/Start Watch recovery action that calls the
  native `startWatchApp` bridge path.
- Closing the watch app stops the watch-session foreground service after the
  specified grace delay when no required work remains.
- Outbound queue prioritizes GPS/control over stale tiles.
- Tile sends are dropped after three NACK callbacks and produce bounded error
  diagnostics.
- Route worker answers next-step requests from local route cache without another
  provider call.
- Route worker includes the active travel mode on `CMD_ROUTE_POINTS.is_color`
  so the watch can render phone-started walking routes correctly.
- Cache clear controls remove local tile, route, and provider-validation
  cache/status data as specified.

## Tile Pipeline Gates

- Golden 54x63 palette-index grid RLE-encodes and decodes without loss.
- Crop crossing a 256x256 logical source-tile boundary composites from the
  correct provider source tiles.
- Worst-case tile payload fits negotiated AppMessage dictionary limits.
- Tile worker deduplicates in-flight requests by x/y/zoom/theme.
- Theme changes invalidate encoded tile cache entries.
- Map source and rendered tile size changes invalidate provider sessions, source
  tile cache, encoded tile cache, and watch visible tile cache through
  `CMD_MAP_SETTINGS`.
- Google session requests use `scaleFactor1x`, `highDpi = false`, and omit
  `imageFormat`.
- High-DPI source tiles whose returned dimensions exceed 256x256 still produce
  correctly aligned 54x63 logical watch crops.
- Provider quota, billing, API-disabled, network, and session-token failures
  map to visible watch/mobile errors.

## Routing Gates

- Missing key fails before network request.
- Autocomplete-backed Navigate Now route can start without a saved-location
  slot.
- Navigate Now defaults origin to current location and routes from fresh GPS.
- Navigate Now can route from a Google Places/Geocoding-resolved explicit
  origin without requiring a saved-location record.
- Missing saved-location ID maps to category 8.
- Missing fresh GPS maps to category 3 when the selected origin is current
  location.
- Invalid key/API disabled/quota/billing/permission denied maps to category 2.
- Network unavailable maps to category 4.
- Geocode no result maps to category 6.
- Provider no-route maps to zero-point route plus category 7.
- Successful route preserves endpoints and produces 2..128 points.
- More than 255 provider steps are deterministically coalesced or truncated.
- First nav-step chunk contains no more than three records.
- Instructions are UTF-8 byte-safe and capped to watch buffer limits.
- User-triggered reroute replaces active route or reports a recoverable error.

## Diagnostics And Privacy Gates

- Diagnostic export is user-initiated.
- Export contains no full API key, access token, credential-like secret, or
  precise session token.
- Export includes enough context to debug protocol failures: command ID, error
  category, tile x/y/z, route origin ID, route target ID, saved-location ID
  when present, safe HTTP status, and timestamps.
- Logs are bounded and local.
- Location and route data are not uploaded except to the configured direct
  provider calls needed for the requested operation.

## Release Gates

- Android package ID remains `com.leapwardkoex.mappy` across release metadata.
- Debug and release SHA-1 fingerprints are documented in the setup UI/docs.
- Provider terms, attribution, and cache policy are reviewed against the
  implemented endpoints.
- Watch UI is screenshot-verified on target geometry.
- Emulator or hardware tests cover startup, setup error, map, route, reroute,
  no-route, network failure, invalid key, and diagnostics export.
