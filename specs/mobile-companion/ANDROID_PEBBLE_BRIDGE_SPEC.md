# Android Pebble Bridge Spec

This spec defines the Android native bridge for MVP. It covers Pebble
AppMessage transport, Flutter/native
channels, connection lifecycle, queueing, permissions, package visibility, and
verification.

## Design Basis

- Pebble AppMessage allows one in-flight send, so the bridge serializes sends,
  prioritizes fresh GPS over bulk tiles, and abandons a tile after three NACKs.
- The authoritative constants and payload shapes are documented in
  `../shared/PROTOCOL_MVP.md`.
- The Mappy watch sends `CMD_INIT`, `CMD_TILE_REQUEST`,
  `CMD_ROUTE_REQUEST`, `CMD_NAV_STEPS`, `CMD_ROUTE_CLEAR`, `CMD_TRAVEL_MODE`,
  and `CMD_LOG_EVENT`.

- Android native code owns the Pebble transport for MVP.
- PKJS remains a comment-only package entrypoint and must not register an
  AppMessage responder.
- Flutter owns the user-facing setup and settings UI, but it does not own
  Pebble callbacks or provider request headers.

## Ownership

| Responsibility | Owner |
| --- | --- |
| Pebble AppMessage registration | Android native bridge |
| Watch app UUID and message-key mapping | Shared constants generated from `../../apps/pebble-watch/package.json` |
| Inbound command dispatch | Android native bridge |
| Outbound queue and ACK/NACK handling | Android native bridge |
| Google API key storage and validation | Android native secure storage/provider layer |
| Provider REST calls and Android restriction headers | Android native provider adapters |
| Location permission and location updates | Android native location service |
| User setup, destinations, settings, diagnostics screens | Flutter |
| UI-to-native command surface | Flutter method channel |
| Native-to-UI status stream | Flutter event channel |

## Integration Boundary

The implementation must wrap PebbleKit Android behind a small internal adapter:

```text
PebbleTransport
  register(uuid, receiver)
  unregister()
  isWatchConnected()
  isWatchAppActive(uuid)
  startWatchApp(uuid)
  stopWatchApp(uuid)
  send(uuid, dictionary, ack, nack)
```

Production code must depend on this adapter, not directly on static PebbleKit
calls throughout the app. This makes replay tests possible without a phone or
watch and keeps the PebbleKit dependency localized.

Selected transport strategy for MVP:

- Use PebbleKit Android 2 bound-service communication, not the legacy
  `com.getpebble.action.app.*` broadcast protocol.
- Depend on the `io.rebble.pebblekit2:client` API or an equivalent vendored
  build of `pebble-dev/PebbleKitAndroid2`.
- Implement a manifest-declared listener service that subclasses
  `BasePebbleListenerService` and handles `onMessageReceived`, `onAppOpened`,
  and `onAppClosed` for the Mappy watch UUID.
- Declare the listener service with the
  `io.rebble.pebblekit2.RECEIVE_DATA_FROM_WATCH` intent action so the Pebble
  Android app can bind to it and wake the companion process when the watch app
  opens.
- Use `DefaultPebbleSender` or the equivalent PebbleKit Android 2 sender API
  for outbound AppMessage sends and phone-initiated `startAppOnTheWatch` /
  `stopAppOnTheWatch`.
- Keep PebbleKit Android 2 calls inside the adapter and listener/service
  boundary; the rest of the bridge consumes `PebbleTransport`.
- If the dependency is supplied as an AAR/JAR instead of a Maven coordinate, keep
  it under the Android project and document the source in the implementation PR.
- Do not implement direct Bluetooth transport in MVP.
- Do not use a notification listener, share receiver, direct Bluetooth
  transport, or background location service for MVP.

If no PebbleKit-compatible Android transport can be made to build, MVP watch
integration is blocked. Do not fall back to a production PKJS worker unless
`../companion-js/COMPANION_JS_MVP.md` is amended first.

## Package And Manifest

Application identity:

- Android application ID: `com.leapwardkoex.mappy`.
- The setup UI must show the active package name and signing certificate SHA-1
  used for Google API key restrictions.

Required MVP permissions:

| Permission | Reason |
| --- | --- |
| `android.permission.INTERNET` | Direct Google Map Tiles, Places, Geocoding, and Routes calls. |
| `android.permission.ACCESS_FINE_LOCATION` | Current-location route origin, live marker, heading/course where available. |
| `android.permission.ACCESS_COARSE_LOCATION` | Graceful degraded location state when only coarse permission is granted. |
| `android.permission.ACCESS_BACKGROUND_LOCATION` | Required when the watch can start or keep a live location foreground service after the Flutter activity is backgrounded. The app must route users to Android settings for the all-the-time grant where Android does not expose it in the foreground runtime prompt. |
| `android.permission.FOREGROUND_SERVICE` | Watch-session foreground service while the Pebble watch app is actively using the companion. |
| `android.permission.FOREGROUND_SERVICE_LOCATION` | Required on Android versions that gate foreground services which access location. |
| `android.permission.POST_NOTIFICATIONS` | Required on Android versions that gate display of the user-visible watch-session foreground-service notification. This is not notification-listener access. |

Forbidden MVP permissions and components:

- Notification listener service.
- Microphone or dictation capability.
- Always-on navigation service unrelated to an active watch session.
- Unrelated application package metadata or intent filters.

Required MVP components:

- A `BasePebbleListenerService` subclass exported for PebbleKit Android 2 binding
  and filtered to `io.rebble.pebblekit2.RECEIVE_DATA_FROM_WATCH`.
- An activity `ACTION_SEND`/`text/plain` intent filter for explicit Google Maps
  shares, as specified by `../shared/COMPANION_SHARE_MODE_SPEC.md`.
- A watch-session foreground service that owns the long-lived companion runtime
  while the Mappy watch app is open.
- A user-visible foreground-service notification with neutral text such as
  "Mappy watch session active". Do not include precise destination, route, API
  key, or location details in the notification without a privacy spec update.

Package visibility:

- The manifest may declare only the exact Pebble/Rebble package queries required
  by the selected PebbleKit integration.
- Do not add broad package queries or unrelated app visibility.
- The implementation PR must record the package names verified by emulator or
  device testing.

## Flutter Channels

Use stable channel names:

```text
app.mappy.bridge/methods
app.mappy.bridge/events
```

Method channel requests:

| Method | Direction | Payload | Result |
| --- | --- | --- | --- |
| `getBridgeStatus` | Flutter -> native | none | Snapshot status. |
| `startWatchApp` | Flutter -> native | none | Requests the Pebble/Rebble app to open the Mappy watch app and returns updated bridge status. |
| `requestNotificationPermission` | Flutter -> native | none | Requests `POST_NOTIFICATIONS` when required by Android and returns updated bridge status. |
| `storeApiKey` | Flutter -> native | plaintext key once | Redacted validation state. |
| `clearApiKey` | Flutter -> native | none | Key removed and setup state pushed to watch. |
| `validateProviderSetup` | Flutter -> native | optional force flag | Provider validation result. |
| `searchPlaces` | Flutter -> native | query text, role `origin`/`destination`/`saved_location`, session token handle, optional location bias | Places autocomplete predictions for Navigate Now origin/destination search or saved-location editing. |
| `resolvePlace` | Flutter -> native | role, place ID plus session token handle, or free-form text | Route-ready label, address, place ID, and coordinates from Place Details or geocoding. |
| `startNavigation` | Flutter -> native | origin policy/current-location or resolved explicit origin, resolved ad-hoc or saved-location target, travel mode | Starts route worker without requiring a saved-location record. |
| `setDestinations` | Flutter -> native | normalized saved-location records up to the watch protocol payload count | Persisted and pushed when watch ready. |
| `setDestination` | Flutter -> native | one normalized saved-location record or disabled slot | Persisted patch and pushed when watch ready. |
| `setSettings` | Flutter -> native | units, theme, travel mode, backlight, centered map orientation, tile animation, haptic mode, glance mode | Persisted and pushed when applicable. |
| `requestLocationPermissionState` | Flutter -> native | none | Permission state and whether prompt is needed. |
| `clearCaches` | Flutter -> native | cache kinds: `tiles`, `routes`, `provider_validation` | Counts/status removed. |
| `clearDiagnostics` | Flutter -> native | none | Local diagnostic events cleared. |
| `exportDiagnostics` | Flutter -> native | redaction/export options | Local file URI or bytes for share sheet. |

Event channel events:

| Event | Required fields |
| --- | --- |
| `bridgeStatus` | watch connected, watch app active, watch ready, foreground-service state/error, setup state, provider state, location permission state, notification permission state. |
| `watchCommand` | command id, safe correlation fields, timestamp. |
| `sendResult` | command id, ACK/NACK, attempt count, safe correlation fields. |
| `providerStatus` | validation state, safe HTTP status/class, redacted key status. |
| `locationStatus` | permission state, fresh/stale flag, heading availability. |
| `diagnosticEvent` | event id, severity, source, redacted message. |

Flutter must not receive the stored full API key from native code. Native may
return only redacted key previews such as prefix plus length.

## AppMessage Constants

The bridge must use the Mappy watch UUID from
`../../apps/pebble-watch/package.json`.

All message keys and command IDs must match `../shared/PROTOCOL_MVP.md`.
Implementation should generate or share constants from one source of truth
instead of manually duplicating numeric values in unrelated files.

Inbound commands handled by Android native for MVP:

| Command | Handler |
| --- | --- |
| `CMD_INIT` | Mark watch ready, reconcile settings, push setup state, saved locations, GPS, and active route summary if present. |
| `CMD_TILE_REQUEST` | Queue/dedupe map tile crop work. |
| `CMD_ROUTE_REQUEST` | Resolve saved-location ID or active reroute target, then route. |
| `CMD_NAV_STEPS` | Return next nav-step chunk from local route cache. |
| `CMD_ROUTE_CLEAR` | Clear active route and route diagnostics state. |
| `CMD_TRAVEL_MODE` | Persist watch-selected travel mode and notify Flutter. |
| `CMD_MAP_ORIENTATION` | Persist watch-selected centered map orientation and notify Flutter, if watch-side editing is implemented. |
| `CMD_TILE_ANIMATION` | Persist watch-selected tile animation mode and notify Flutter, if watch-side editing is implemented. |
| `CMD_HAPTIC_MODE` | Persist the watch-selected haptic preset, echo normalized state, and notify Flutter. |
| `CMD_GLANCE_MODE` | Persist the watch-selected navigation-glance preset, echo normalized state, and notify Flutter. |
| `CMD_LOG_EVENT` | Store bounded diagnostic event. |
| `CMD_BUTTON` | Accept zoom/button telemetry only if still used by watch implementation. |

Commands reserved or forbidden for MVP must be ignored safely and logged at
debug level only.

## Startup And Reconnect

Native app startup:

1. Initialize secure storage, diagnostics, provider adapters, location service,
   PebbleKit Android 2 sender adapter, and watch-session service controller.
2. Ensure the manifest-declared `BasePebbleListenerService` is available for
   PebbleKit binding. Runtime registration alone is not sufficient.
3. Emit `bridgeStatus` to Flutter.
4. Do not make provider network calls until setup validation or a user/watch
   operation requires them.

Watch startup:

1. Watch opens AppMessage and sends `CMD_INIT`.
2. PebbleKit Android 2 binds to the listener service, waking the companion app
   if needed.
3. Listener `onAppOpened` for the Mappy UUID starts the watch-session
   foreground service. If `onAppOpened` is missed, the first valid
   `onMessageReceived`/`CMD_INIT` for the UUID must also start it.
4. Bridge marks `watchReady = true`.
5. Bridge stores watch startup settings from `CMD_INIT` and reconciles them with
   phone-owned settings.
6. Bridge pushes one of:
   - setup-required error,
   - location-required error,
   - waiting-for-GPS state,
   - ready state with destinations and latest GPS.
7. Bridge starts/continues visible tile work only after GPS and setup are ready.

Reconnect:

- Repeated `CMD_INIT` is idempotent.
- On reconnect, resend current setup state, settings, destinations, latest GPS,
  and active route summary if present.
- If a tile send is in flight during reconnect, let the ACK/NACK callback settle
  or expire; then refill visible tile work from current watch requests.
- Do not assume the watch kept route or tile state across app reinstall.

## Watch-Session Foreground Service

The companion must not depend on `MainActivity` or an open Flutter UI to answer
watch requests. While the Mappy watch app is active, Android native code
must run a foreground service dedicated to the Pebble companion session.

Start triggers:

- `BasePebbleListenerService.onAppOpened` for the Mappy watch UUID.
- First valid `onMessageReceived` for the Mappy UUID, including `CMD_INIT`,
  when no active watch session is already recorded.
- Phone-initiated `startWatchApp` after the sender confirms or strongly implies
  that the watch app has opened.

Runtime responsibilities:

- Own or bind to the durable bridge runtime, outbound queue, provider workers,
  location stream, diagnostics, and Flutter event fanout.
- Keep servicing watch messages when Flutter UI is not running.
- Keep the live watch GPS stream running while the Mappy watch app or
  watch-session foreground service remains active; do not stop it only because
  `MainActivity` receives `onPause` or the Flutter event sink disconnects.
- The foreground-service/headless runtime owns the live GPS stream. Flutter may
  observe and request setup actions, but Activity lifecycle must not be the
  owner of the active watch stream.
- Send `bridgeStatus.foregroundServiceActive = true` while the service is
  promoted, and include a safe `foregroundServiceLastError` when promotion
  fails.
- Report `notificationPermissionState` so Flutter can show whether the
  foreground-service notification is granted, requestable, denied, blocked by
  system settings, unavailable, or not required on this Android version.
- Request `POST_NOTIFICATIONS` only from a user-visible Flutter action; watch
  callbacks must not trigger a hidden runtime permission prompt.
- Use the Android foreground-service type required by the active work. If live
  GPS is read from the service, declare/use the `location` type and the matching
  foreground-service permission.
- Verify Android 12+ foreground-service start restrictions and Android 14+
  while-in-use location restrictions on target devices. If a background
  PebbleKit callback cannot legally start a location foreground service, the
  implementation must use an allowed Android companion-device/background-start
  exemption, require an explicit user-visible start flow, or surface a watch
  setup error. It must not silently fall back to an activity-only bridge.

Stop triggers:

- Primary: `BasePebbleListenerService.onAppClosed` for the Mappy UUID.
- Secondary: active-app reconciliation confirms the active Pebble app is not the
  Mappy UUID.
- Secondary: Pebble watch disconnects and remains disconnected for at least
  30 seconds.
- Watchdog: no valid inbound watch message, no successful outbound send,
  no in-flight send, no queued work, and no active route/tile/location work for
  10 minutes.

Stop behavior:

- Use a short grace delay, 10-30 seconds, before stopping after `onAppClosed` so
  quick close/reopen transitions do not churn the service.
- Before stopping, finish or cancel in-flight tile/route work according to the
  normal queue rules and persist diagnostics.
- Call `stopForeground` and `stopSelf` once no required work remains.
- Do not stop solely because tile requests are idle while PebbleKit still
  reports the watch app as active.
- If Flutter UI remains open after the watch service stops, the UI stays usable
  but watch status changes to not active/not ready.

## Outbound Queue

Only one Pebble AppMessage send may be in flight per watch UUID.

Priority order:

1. Setup/error/control messages.
2. GPS updates.
3. Destination/settings changes.
4. Route points and nav steps.
5. Tile responses.
6. Diagnostic acknowledgements or optional low-value telemetry.

Rules:

- GPS updates supersede stale queued GPS updates.
- Tile responses are deduped by `world_x, world_y, zoom, theme`.
- A tile response is dropped after three total failed send attempts.
- Dropping a tile must produce a bounded diagnostic event and must not clear a
  valid prior tile on the watch.
- Route points and nav steps are not silently dropped; failure must surface in
  diagnostics and, when useful, as `CMD_ERROR_STATE`.
- Queue length must be bounded. On overflow, drop lowest-priority stale tiles
  first.

## Location Bridge

Location service behavior:

- Use Google Play services `FusedLocationProviderClient` for both continuous
  watch-session updates and single current-location fixes.
- Request foreground location for user-visible setup/current-location actions.
  Require all-the-time/background location before claiming the companion can
  keep a watch-started active session updated after the phone UI backgrounds.
- For an active watch session, request updates at an approximately one-second
  minimum interval and one-meter minimum distance. Platform delivery may be
  slower, but the companion should not ask Android for a coarse multi-second /
  multi-meter stream for the watch marker.
- Force a resend of the latest fresh accepted fix within a few seconds even if
  the rounded watch world pixel and heading are unchanged.
- Convert location to zoom-16 world pixels before sending `CMD_GPS`.
- Send heading/course only when the platform reports a valid value.
- When heading is unavailable, send a sentinel documented in
  `../shared/PROTOCOL_MVP.md` so the watch suppresses the current-location view
  cone.
- Accept only fresh, monotonic fixes into the live GPS stream. Reject
  out-of-order platform timestamps, recent non-GPS fixes that would supersede a GPS
  fix, implausible non-GPS jumps, and large accuracy regressions.
- Include `gps_sequence`, `gps_elapsed_ms`, `gps_accuracy_cm`, and
  `gps_provider` on watch-bound `CMD_GPS` messages when platform data is
  available.
- Mark GPS stale after `MOBILE_COMPANION_MVP.md` threshold
  `location_fix_stale_for_ui`.

Permission denial:

- Flutter receives a visible permission-denied state.
- Watch receives `CMD_ERROR_STATE` category 3.
- Route provider work with current-location origin requires a fresh GPS origin.
- Route provider work with explicit origin may proceed after the explicit origin
  resolves, even if live GPS is unavailable or stale.
- Tile provider work still requires enough viewport state to request map tiles.

## Error Handling

The bridge maps errors through `CMD_ERROR_STATE`:

| Failure | Category |
| --- | ---: |
| Missing key | 1 |
| Invalid/API disabled/quota/billing/permission denied | 2 |
| Current-location origin permission/fix/stale unavailable | 3 |
| Network unavailable | 4 |
| Tile provider failure | 5 |
| Route/geocode provider failure | 6 |
| No route found | 7 |
| Saved-location ID missing/unconfigured | 8 |

Watch-facing text must be capped to 47 UTF-8 bytes on code point boundaries.
Native diagnostics may retain richer safe context, but never a full API key or
provider session token.

## Test Requirements

Unit/replay tests:

- Fake Pebble transport receives `CMD_INIT` and verifies setup-state replies.
- Fake transport verifies no PKJS responder is required.
- Fake PebbleKit Android 2 listener events start the watch-session foreground
  service on `onAppOpened` and first valid `CMD_INIT`.
- Fake listener `onAppClosed` stops the foreground service after the configured
  grace delay when no work remains.
- Active-app reconciliation stops the foreground service when the active watch
  app is confirmed to be a different UUID.
- Inbound `CMD_TILE_REQUEST`, `CMD_ROUTE_REQUEST`, and `CMD_NAV_STEPS` dispatch
  to the correct workers.
- `setSettings` with centered map orientation sends `CMD_MAP_ORIENTATION` and
  does not clear provider caches or restart active navigation.
- `setSettings` with tile animation sends `CMD_TILE_ANIMATION` and does not
  clear provider caches, re-request tiles, or restart active navigation.
- `setSettings` with haptic or glance mode persists and sends the corresponding
  command without clearing provider caches or restarting active navigation.
- Missing and invalid native preference values for haptic and glance mode
  normalize to `3` All; startup resends both durable settings after phone-ready.
- Queue prioritizes GPS/control over stale tiles.
- Tile NACK drops after three failed attempts.
- Repeated `CMD_INIT` is idempotent.
- Malformed dictionaries are rejected without crashing.

Integration tests:

- Flutter method channel can store/clear key through native code without reading
  the full key back.
- Permission denial is visible in Flutter and pushed to the watch as category 3.
- Emulator or device watch smoke test shows PebbleKit Android 2 listener binding,
  `CMD_INIT` handshake, watch-session foreground-service notification, and at
  least one native bridge response without manually opening the Flutter UI.

Static gates:

- Production PKJS contains no AppMessage responder.
- Android manifest contains PebbleKit Android 2 listener and watch-session
  foreground-service declarations.
- Android manifest contains no share target, notification listener, microphone,
  Timeline, or background-location surface.
- Watch package metadata contains only the Mappy companion package entries
  required for PebbleKit Android 2.
- Runtime network access is limited to provider endpoints named by the shared
  specifications.

## Acceptance Criteria

- Android native bridge is the only production AppMessage responder.
- Production transport uses PebbleKit Android 2 bound services, not legacy
  Pebble broadcast intents.
- Watch can start the companion runtime and foreground service from the watch
  app without the user manually opening the phone UI.
- Bridge can replay startup, setup-required, missing-location, destination push,
  map-orientation sync, tile request, route request, nav-step request, and
  route-clear flows through a fake transport.
- Bridge can build with the selected PebbleKit-compatible dependency or adapter.
- Manifest package visibility is documented and minimal for the selected
  transport.
- Watch emulator or hardware smoke test confirms the production watch can
  handshake with Android native code.
