# Mappy MVP Scope

This document defines the first shippable Mappy release and its implementation
boundaries.

## MVP Goal

The MVP recreates the core watch experience:

- A Pebble color watch app displays a moving raster map underlay.
- The watch shows the user's current location and heading.
- The phone app can search for a destination with autocomplete and immediately
  display the resulting route on the watch.
- The watch can also request and display a route to an optional saved-location
  shortcut.
- The phone companion supplies map tiles, GPS updates, route data, nav steps,
  and settings.
- The Flutter companion provides a basic navigation search, optional
  saved-location UI, display settings, Google API key setup, and diagnostics.

MVP code uses explicit structs, clear names, versioned payloads, and documented
contracts shared by the watch and phone implementations.

The MVP has no project-hosted application server. All network-backed map, geocode,
and route work is done from the user's phone with the user's own Google API key
through the providers specified in this spec set. Mappy must not depend on a
project-hosted route proxy, tile generator, account service,
server-side tile generation, or server-side log collection.

## Target Platforms

| Layer | MVP target |
| --- | --- |
| Watch | Pebble Time 2 / `emery`, color screen, Pebble SDK C app |
| Pebble bridge | Android PebbleKit integration inside the Flutter companion; bundled PKJS is a comment-only no-op |
| Mobile app | Flutter Android first; iOS can remain scaffolded if Pebble bridge constraints require it |
| Backend | None |
| External services | Google APIs called directly from the phone using a user-supplied API key |

## Backend-Free Architecture

### Phone Runtime Ownership

MVP is Android-first. The Flutter app plus Android native integration is the
authoritative phone runtime for:

- Pebble transport through the PebbleKit Android integration.
- Google API key storage and validation.
- Location permission and GPS updates.
- Map source tile fetching and watch tile generation.
- Geocoding, route fetching, route simplification, and nav-step generation.
- Destination/settings persistence and diagnostics export.

The PebbleKit JS file bundled with the watch app must remain a comment-only
no-op for MVP. It must not contain the Google API key, make Google network
calls, respond independently to `CMD_TILE_REQUEST`, or maintain a second copy of
destination/settings state. If a later platform requires PKJS to own any runtime
work, a separate bridge spec must define the local no-server IPC/storage path
from Flutter to PKJS before implementation.

This decision avoids a hidden backend or secret-in-bundle workaround: all
credentialed work lives in the installed phone app under user control.

### Data Ownership

MVP data ownership:

- The mobile companion stores the user's Google API key locally.
- The API key is never compiled into the watch app, PKJS bundle, repository, or
  build artifacts.
- The phone performs geocoding, route fetches, route simplification, map tile
  generation, settings persistence, and diagnostic log storage.
- The watch stores only small persisted settings needed for fast startup, such
  as theme, backlight mode, travel mode, and last display state.
- The Android native companion bridge owns Pebble AppMessage transport for MVP.
- The Flutter app owns user-facing configuration, key validation UX,
  saved-location editing, permission prompts, and diagnostics export.

MVP external-service rules:

- Use only documented provider APIs with the user's configured credentials.
- Do not require an application account or project-hosted service.
- Do support a clear "missing/invalid Google API key" state before routing or
  map-tile work is attempted.
- Do document which Google APIs the user must enable once implementation picks
  the exact endpoints.
- Do keep provider-specific code behind interfaces so a later non-Google
  provider can be added without changing the watch protocol.
- Do not silently switch to an unconfigured provider. Any additional provider
  requires a provider-specific spec before implementation.

## Google Provider MVP

MVP Google API surface:

| Need | MVP Google API |
| --- | --- |
| Configurable map imagery for watch tiles | Google Map Tiles API, 2D road, satellite, hybrid, and terrain tiles |
| Autocomplete search and place resolution | Google Places API (New) Autocomplete and Place Details |
| Free-form ad-hoc or saved-location geocoding | Google Geocoding API |
| Routes and route polyline | Google Routes API `computeRoutes` |

Implementation notes:

- Map Tiles API 2D tiles require a session token created with the user's API key
  and the selected map source setting, then per-tile requests by
  z/x/y/session/key.
- Routes API requests use direct phone HTTPS calls to
  `https://routes.googleapis.com/directions/v2:computeRoutes` with the user's
  API key and a field mask limited to MVP needs.
- Geocoding uses the current Google Geocoding API flow selected during
  implementation; store resolved coordinates locally so routine route requests
  do not geocode unchanged destinations.
- Every direct Google REST request from Android must include the Android
  application restriction headers `X-Android-Package` and `X-Android-Cert`.
  The package value comes from the runtime package name. The cert value is the
  active signing-certificate SHA-1 digest encoded as 40 hex characters with no
  delimiters.
- Key validation must include a negative restriction check: a request with an
  intentionally wrong package or cert must be rejected by each direct REST
  endpoint before MVP relies on that endpoint. If an endpoint accepts the wrong
  Android identity, MVP must block that direct provider path instead of telling
  users to use an unrestricted key. There is no proxy/backend fallback in MVP.
- The app must expose a setup checklist for required enabled APIs: Map Tiles
  API, Places API, Geocoding API, and Routes API.
- The app must expose map tile settings for road, satellite, hybrid, and terrain
  imagery plus rendered tile size. Provider requests use the fixed compact
  source profile, automatic response format, and nearest-palette tile encoding.
- Cache Google responses and map imagery only within the provider's current
  policy, response headers, and user-facing cache-clear controls.
- Show Google attribution in the mobile app and any watch-accessible place where
  the selected API terms require it. If watch attribution is required and cannot
  fit acceptably, MVP must switch provider or adjust UX before shipping.
- For walking and bicycling routes, both mobile and watch route displays must
  show a provider warning that these modes may be missing safe pedestrian or
  bicycling path detail.
- Treat quota, billing, API-disabled, invalid-key, permission-denied, and
  session-token failures as recoverable phone-side errors surfaced to the watch
  and mobile diagnostics.

## Watch Geometry MVP

The primary target is Pebble Time 2 / `emery`. The compact 54x63 crop format is
the MVP wire tile unit, while cache/grid dimensions are calculated from the
actual target screen.

MVP geometry decision:

- Compile-time target: `emery`.
- Tile crop: 54x63 pixels.
- Minimum visible grid on `emery`: 5 columns x 5 rows. The extra row/column is
  required because fixed 54x63 crop origins are quantized to tile-grid cells; a
  4x4 grid can leave uncovered right/bottom strips in worst alignment.
- Decoded tile memory target: 25 * 1,701 = 42,525 bytes plus metadata.
- The implementation must confirm actual `emery` screen bounds through Pebble
  SDK constants before hard-coding layout.
- A fallback Basalt build may use a measured 3x3 grid, but Basalt is not the MVP
  target.

## Included User Workflows

### Mobile Welcome And Readiness

- First mobile launch shows a dismissible introduction covering Navigate Now,
  BYOK Google setup, location permission, notification permission, the active
  watch-session foreground service, and Status/Diagnostics recovery.
- Later launches open the recurring app shell with Navigate as the primary tab.
- A debug/support action can replay the welcome flow.
- Status shows watch bridge, foreground-service, notification-permission,
  provider, and location readiness with concrete fix text.
- The phone UI exposes an Open Watch/Start Watch action that calls the native
  bridge path for launching the watch app.

### Startup And Map

- User launches the watch app.
- Watch sends readiness and persisted watch settings to the phone bridge.
- Phone bridge starts GPS updates and sends current location to the watch.
- Watch computes the target-calculated visible map crop grid, initially 5x5 on
  `emery`, and requests missing tiles.
- Phone bridge generates compressed raster tile payloads and sends them back.
- Watch decodes, caches, and renders the map.

### Live Position And Touch Pan

- GPS-follow mode is the default viewport behavior.
- Hardware buttons can zoom in/out and open the destination/settings menu.
- On RePebble SDK 4.9+ builds that define `PBL_TOUCH`, the production watch app
  must support touchscreen map panning on touch platforms such as `emery` and
  `gabbro`.
- Touch panning is a watch-local viewport override: drag updates the visible
  center, queues the same `CMD_TILE_REQUEST` messages as any other viewport
  change, and must not introduce a new phone command or provider path.
- On real touch hardware that exposes reliable multi-touch or pinch-distance
  data, the watch must support pinch-to-zoom-in and pinch-to-zoom-out as defined
  in `watch/WATCH_TOUCH_INPUT_SPEC.md`. Smooth transient zoom is preferred; a
  discrete level-change pinch fallback is acceptable when SDK or hardware limits
  make smooth zoom impractical.
- When `PBL_TOUCH` is absent or `touch_service_is_enabled()` is false, the app
  must retain the GPS-follow/button-only behavior.
- If the viewport is manually panned away from GPS-follow, the watch UI must
  suspend GPS-follow and any facing-up auto-rotation, render the browsed
  viewport north-up, and provide a compact way to recenter on the current GPS
  position. Panning must remain allowed while centered.
- Current-location facing direction comes from the Pebble watch compass where
  compass hardware is available.
- The same Pebble watch compass heading provides the active facing bearing used
  for facing-up map rotation on compass-capable watches. Phone GPS/course may
  only stand in for this source in non-compass test builds.
- Invalid or unavailable compass heading must be represented explicitly and hide
  or suppress the current-location view cone instead of showing stale direction.
- The centered map orientation preference defaults to north-up and can be
  changed to face-forward, where the watch rotates geographic layers only while
  GPS-follow is active so the wearer-facing compass bearing points toward the
  top of the screen, as specified by
  `shared/MAP_ORIENTATION_SETTING_SPEC.md`.
- Watch compass support is MVP for the current-location view cone. A phone-known
  declination correction is optional; the watch may use raw magnetic heading
  when a correction is unavailable.

### Navigate Now Route

- User keeps `From: Current location` or searches for a specific origin in the
  mobile app.
- User searches for a destination place/address in the mobile app.
- Native bridge returns Google Places Autocomplete predictions for destination
  and, when needed, specific-origin search.
- User selects the destination prediction, and selects an origin prediction only
  when not using current location.
- Native bridge resolves Place Details and immediately fetches a route from the
  selected origin to the destination without requiring a save step.
- Mobile app shows route loading, then watch-send confirmation and an active
  route summary with destination, distance/duration when known, first
  instruction when available, reroute, and clear.
- Phone bridge sends:
  - a simplified polyline for map drawing,
  - the first nav-step chunk,
  - enough metadata for current instruction and distance display.
- Watch renders the route line on top of the map.
- Watch renders only the untraveled portion of the active route, hiding
  dots/line at and behind the current on-route GPS projection while preserving
  route geometry so retracing steps can reveal it again.
- MVP includes nav-step chunking and basic local step progression:
  - phone sends up to three step records per chunk,
  - watch advances to the next step when GPS progress passes the current step
    threshold,
  - watch requests the next step chunk before its local cache is exhausted.

### Saved-Location Shortcut Route

- User may grow and edit a saved-location list in the mobile app, bounded by the
  watch destination payload protocol.
- Phone bridge pushes the packed saved-location list to the watch.
- User may select a saved location on the watch.
- Phone bridge follows the same route fetch and watch-output path as Navigate
  Now routing.

### Basic Reroute

- User can request a fresh route for the active destination from the watch.
- Automatic off-route detection is not required for MVP.
- If route fetch fails, watch remains on map view and shows a recoverable
  no-route/error state.

### Settings

MVP settings:

- Saved locations: label, address/text, travel mode default.
- Google API key: stored locally, user provided, with validation/status text.
- Notification permission: requested only when Android requires it for the
  watch-session foreground-service notification.
- Display units: imperial/metric.
- Theme: auto/day/night.
- Backlight: auto/always on, if supported by the watch app.
- Centered map orientation: north-up or face-forward.
- Diagnostic logging toggle and log export.
- Android share target for supported Google Maps locations and routes.

### Diagnostics

- Watch can send structured log events to the phone bridge.
- Phone bridge keeps a bounded local diagnostic buffer.
- Flutter app exposes a copy/export path for logs.

## Explicit Non-Goals For MVP

These features are not MVP:

- Any project-hosted backend server or proxy.
- Account, subscription, or entitlement services.
- Google Maps notification listener live companion mode.
- Always-on navigation after the active watch session ends.
- Automatic off-route rerouting without an explicit user action.
- Network declination lookup; `CMD_DECLINATION` accepts a correction only when
  the phone already has one.
The Mappy protocol may reserve conceptual room for future features, but the MVP
implementation must not block on them.

## MVP Compatibility Decisions

| Area | Decision |
| --- | --- |
| Map tile shape | Use 54x63 crop payloads and an `emery`-appropriate visible cache, initially 5x5. |
| Tile compression | Use 4-bit palette RLE because it is compact, cheap to decode, and bounded; the provider request profile and local quantization remain fixed unless a later protocol version adds richer payloads. |
| Map source type | Add phone-side road/satellite/hybrid/terrain selection through Google Map Tiles session settings. |
| Saved-location count | Use a dynamic saved-location list; the watch renders the current payload records without empty placeholders. |
| Route point cap | Use a 128-point watch route cap for MVP after heap/performance verification; future route fidelity may use larger caps and a windowed overview/detail route model. |
| Nav step chunks | Keep small step chunks, initially three records per payload. |
| Field names | Code uses clear internal names; wire names may differ when both layers share the documented contract. |
| External services | Use documented phone-side Google API calls with a user-provided key. |

## MVP Deliverables

- Watch app with map layer, route layer, saved-location menu, button handling,
  AppMessage receiver/sender, settings persistence, and error states.
- Android phone bridge with AppMessage queue, GPS forwarding, tile generation,
  navigate-now and saved-location route request handling, saved-location sync,
  settings sync, and diagnostic capture.
- Bundled PKJS entrypoint that is a comment-only no-op for MVP.
- Flutter companion with navigate-now search, basic settings, optional saved
  locations, Google API key entry/validation status, permission status, and log
  export.
- Shared protocol and data-format tests for:
  - tile RLE encode/decode,
  - route point packing/unpacking,
  - destination packing/unpacking,
  - nav step chunk packing/unpacking.

## Acceptance Gates

MVP is not complete until these pass:

1. Fresh install without key: watch and mobile app reach a nonblank setup/error
   state, and no map or route network calls are attempted.
2. First valid key: after the user enters a valid Google API key and grants
   location permission, the watch reaches a nonblank map view using only phone
   network access and local app state.
3. Tile pipeline: a golden 54x63 tile encodes and decodes to the same palette
   index grid.
4. GPS: phone location update moves the watch marker, recenters the map, and
   hides/neutralizes heading when heading is unavailable.
5. Saved locations: editing saved locations in Flutter updates the watch menu.
6. Route: autocomplete-backed Navigate Now search draws a route polyline and
   displays the first instruction without saving a saved location.
7. Origin selection: Navigate Now can route from current location by default and
   from a Google Places-backed explicit origin when selected.
8. Nav progress: simulated movement across a route advances at least one step,
   visually hides the consumed route behind the simulated GPS position, reveals
   it again when simulated movement reverses, and triggers a next-step chunk
   request when needed.
9. Reroute: user-triggered reroute refreshes the active route or shows an error
   without crashing.
10. Settings: theme, units, backlight, and centered map orientation choices survive
    restart where supported.
11. Offline/failure: tile, route, and GPS failures produce visible degraded
    states and bounded retry behavior.
12. Diagnostics: watch and bridge logs can be exported from the mobile app.
13. Backend-free: routing and map generation still work with only local app
    state, phone network access, and the user's configured Google API key.
14. Emery geometry: the visible tile cache covers the full target screen without
    relying on Basalt-only 144x168 assumptions.

## Authoritative Detail Specs

- `shared/PROTOCOL_MVP.md`
- `shared/MAP_TILE_PIPELINE_MVP.md`
- `shared/ROUTING_MVP.md`
- `shared/SECURE_STORAGE_SPEC.md`
- `shared/DIAGNOSTICS_SPEC.md`
- `shared/PROVIDER_ADAPTER_TEST_SPEC.md`
- `watch/WATCH_APP_MVP.md`
- `watch/WATCH_UI_LAYOUT_SPEC.md`
- `watch/WATCH_TOUCH_INPUT_SPEC.md`
- `companion-js/COMPANION_JS_MVP.md`
- `mobile-companion/MOBILE_COMPANION_MVP.md`
- `mobile-companion/ANDROID_PEBBLE_BRIDGE_SPEC.md`
- `mobile-companion/FLUTTER_UI_SPEC.md`
