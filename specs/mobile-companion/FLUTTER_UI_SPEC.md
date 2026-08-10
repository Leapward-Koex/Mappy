# Flutter UI Spec

This spec defines the production Flutter screens and interaction states for the
Android-first MVP companion. Flutter owns user-facing setup while Android native
owns the watch runtime. MVP has no notification listener or share target.

## Design Basis

- Flutter is the setup, navigation search, settings, saved-location, and
  diagnostics UI.
- Saved locations are a variable-length collection with explicit watch-visible
  labels.
- Troubleshooting state is sourced from Android's bounded local diagnostics.
- A user-supplied Google Maps Platform API key is the only MVP credential type.
- Android native owns credential storage, validation, location, provider calls,
  Pebble transport, and diagnostic persistence.
- The UI must make direct provider operation clear and must not add unplanned
  account, share, or notification-listener flows.

## App Structure

MVP screens:

| Screen | Purpose |
| --- | --- |
| Welcome | First-run introduction to navigation, BYOK setup, watch-session service, and troubleshooting. |
| Navigate | Search for a place/address and immediately start watch navigation. |
| Status | Show setup readiness, watch connection, provider validation, permission state, foreground-service state, notification permission state, and latest operation status. |
| API Key | Enter, validate, replace, and clear a Google API key. |
| Permissions | Request/check foreground location permission and explain watch impact. |
| Saved Locations | Optionally add, edit, and clear saved watch shortcuts. |
| Settings | Units, travel mode, theme, backlight, map source, and rendered tile size preferences. |
| Diagnostics | Recent events, cache controls, log export, and redaction status. |

Navigation:

- Use a bottom navigation bar or compact tab scaffold on phones.
- Navigate is the first recurring screen after the welcome flow is completed.
- Status is a first-class screen for readiness, recovery, and troubleshooting.
- Screens must remain usable in portrait on small Android phones.
- No marketing landing page is part of MVP.

## Welcome And Guided UI

First run:

- On a fresh install, show a short introduction before the recurring app shell.
- The introduction must explain:
  - Navigate Now as the primary route-starting flow.
  - BYOK Google API key setup and the package/SHA-1 restriction values shown in
    Setup.
  - Foreground location and notification permission impact.
  - The watch-session foreground service that runs while the watch app is using
    the companion.
  - Status and Diagnostics as recovery surfaces.
- The introduction must be dismissible and must persist a local "seen" flag.
- A debug/replay action must let testers and support view the introduction
  again without clearing app data.

Guided tour:

- After welcome completion, a contextual UI tour may highlight the Navigate
  destination/search controls. Readiness and watch recovery controls belong on
  Status, not in the recurring Navigate surface.
- The tour must use maintained Flutter onboarding/showcase components rather
  than a bespoke overlay unless those packages are replaced by an explicit
  design decision.
- Any UI change that moves, renames, removes, or changes the meaning of guided
  controls must update the introduction and showcase steps in the same PR.
- Showcase copy must not expose secrets, precise locations, or provider tokens.

## Status Screen

Required status sections:

- Watch connection: disconnected, connected waiting for app, watch ready.
- Watch-session foreground service: waiting, starting, active, or failed with
  safe recovery detail.
- Notification permission: not required, request available, granted, denied, or
  system settings required.
- Setup: missing key, validating, valid, invalid/provider issue.
- Location: not requested, denied, granted waiting for fix, fresh fix, stale fix.
- Provider: Map Tiles, Places, Geocoding, Routes validation status.
- Current watch state: waiting, setup required, map loading, map ready, routing,
  route error, navigating.
- Last safe error: category, short text, timestamp.

Primary actions:

- Add or fix API key.
- Grant location permission.
- Allow notification permission when required by Android.
- Open/start the Mappy watch app.
- Edit saved locations.
- Export diagnostics.

The status screen must not attempt map, route, or geocode network work by being
opened. It may call native status methods and display cached validation state.

## Navigate Screen

The Navigate screen is the primary route-starting surface.

Screen boundary:

- The Navigate screen must not show the `Ready to Navigate` readiness checklist
  or setup/watch recovery action group. Those controls belong on Status so the
  recurring navigation surface can prioritize destination entry, map preview,
  origin selection, travel mode, and active-route controls.

Origin behavior:

- The screen must show a `From` control.
- Default `From` value is current location.
- Current-location origin uses the phone's fresh GPS fix for routing.
- User can switch `From` to a specific place/address.
- Specific-origin search must use the same Android native Google Places
  Autocomplete/Place Details provider path as destination search.
- Free-form origin text may be used only after native geocoding resolves
  coordinates.
- A specific-origin route is allowed to render even if the phone's live current
  location is not at that origin, but route progress must be shown as degraded
  until live GPS aligns with the route.

Search behavior:

- User can type a destination place name or address into one prominent search
  field.
- The destination field must be paired with an embedded Google map preview using
  `google_maps_flutter`. The map must be rendered in a bounded viewport near the
  destination input, center on the selected/resolved destination, and show a
  destination marker when coordinates are available.
- Before a destination is selected, the map should center on the latest phone
  location fix when one is available, even if the fix arrived after the map was
  first rendered. If no phone fix is available, the map may use a safe default.
- Selecting a Places prediction must resolve Place Details for preview before
  route start when possible. The preview resolution must use the same Android
  native Place Details path as route resolution; Flutter must not read the full
  stored BYOK key.
- Tapping or long-pressing the embedded map must select a destination coordinate
  as a dropped pin, update the destination field/detail state, and allow the
  normal Navigate Now action to route there without creating a saved location.
- Embedded map selection must not automatically start navigation. Route start
  still occurs through the explicit Navigate Now action or destination-field
  submit behavior.
- The Google map is a visual/picker surface only. Places, Geocoding, Routes, and
  watch route dispatch remain owned by the existing native provider/route worker
  paths.
- Android builds that render the embedded Google map must supply the Maps SDK
  manifest key required by `google_maps_flutter`; development builds may source
  it from `mappy.devGoogleApiKey`. Builds without a usable Maps SDK key must
  keep the screen nonblank and preserve text search/navigation.
- Search must offer Google Places Autocomplete predictions as the user types.
- Autocomplete calls must be made by Android native provider code using the
  stored key and Android package/cert headers; Flutter must not call Google
  Places directly and must not read the full key.
- Suggestions should be biased to the current phone location when a fresh fix is
  available. If only a stale/latest-known phone fix is available, it may still
  be sent as Places `origin` and `locationBias` so nearby predictions are
  preferred while search continues to work without a location bias.
- The UI must show Google attribution when displaying Places predictions
  outside a Google map.
- Selecting a prediction must resolve Place Details needed for routing:
  display label, formatted address, place ID, latitude, and longitude.
- After successful destination resolution, the app must keep the selected
  destination preview visible and make the explicit Navigate Now action route to
  that destination from the selected origin using the selected/default travel
  mode.
- The user must not be required to save the destination before navigation
  starts.
- The screen may expose a secondary `Save location` action after a destination
  is selected or after navigation starts.
- Free-form destination text may start navigation only after native geocoding
  resolves coordinates.

Navigation state:

- Show route loading, watch-send confirmation, active route summary, no-route,
  and provider-safe error states.
- Active route summary must include destination, distance/duration when known,
  first instruction when available, and clear/reroute actions.
- Show current travel mode and allow changing it before starting navigation.
- Walk and bike modes must display the provider warning required by
  `../shared/ROUTING_MVP.md`.
- Clear route must stop the active route on the phone and watch.
- Reroute repeats the active route using its active origin policy. Current
  location origins use fresh GPS; specific origins reuse the resolved origin
  unless the user changes it.

## API Key Screen

Input rules:

- Accept only text entered by the user.
- Trim surrounding whitespace.
- Reject empty input.
- Reject input that does not match the expected Google API key shape, including
  URLs, bearer tokens, and copied configuration blobs.
- Do not log the full input.

Validation workflow:

1. User enters a key and taps validate/save.
2. Flutter sends the plaintext key once through `storeApiKey`.
3. Native stores it in secure storage and runs provider validation.
4. Flutter receives validation status and redacted key preview.
5. If validation fails, the key may remain stored only when native marks it as
   stored-but-invalid and the user can clear or replace it.

Displayed key state:

- Never show the full key after submission.
- Show a redacted preview such as first 6 characters plus length.
- Show package name and signing SHA-1 needed for Android-restricted keys.
- Show required APIs: Google Map Tiles API, Places API, Geocoding API, and
  Routes API.

Validation statuses:

- Not configured.
- Validating.
- Valid.
- Invalid key.
- API disabled.
- Quota or billing issue.
- Provider permission denied.
- Network unavailable.
- Unsupported restricted-key behavior.

The UI must not recommend unrestricted keys. If Android-restricted REST behavior
is unsupported for an endpoint class, show setup blocked.

## Permissions Screen

Foreground location permission states:

- Not requested.
- Request available.
- Granted precise.
- Granted approximate only.
- Denied.
- Permanently denied or system settings required.

Behavior:

- Flutter asks native for permission state.
- Native performs permission requests or returns a platform intent when settings
  must be opened.
- Denial is visible on this screen, on Status, and on the watch through
  `CMD_ERROR_STATE` category 3.
- Background location is not requested in MVP.

Notification permission:

- The app declares `POST_NOTIFICATIONS` only to support the user-visible
  watch-session foreground-service notification on Android versions that gate
  notification display.
- Flutter must show notification permission state on Welcome/Status.
- Flutter must expose an explicit request action when native reports request
  available or denied.
- Notification denial must not crash foreground-service startup; the status UI
  must tell the user what to fix.
- This permission is not a Google Maps notification-listener feature.

## Saved Locations Screen

Saved locations are secondary shortcuts for repeated destinations and
watch-only route starts. They must not be presented as a prerequisite for normal
navigation.

Saved-location records:

- Stable saved-location ID for the watch protocol.
- Display name, capped to the watch protocol name limit.
- Address text.
- Optional resolved lat/lng.
- Optional Google place ID/provider ID.
- Geocode status.
- Last updated timestamp.

Editing behavior:

- The screen shows existing saved locations and an Add Location action.
- A fresh install shows an empty saved-location list, not placeholder rows.
- User can enter name and destination search text.
- Destination search must offer Google Places Autocomplete predictions as the
  user types.
- Autocomplete calls must be made by Android native provider code using the
  stored key and Android package/cert headers; Flutter must not call Google
  Places directly and must not read the full key.
- Selecting an autocomplete prediction must resolve place details needed for
  routing: display label, formatted address, place ID, latitude, and longitude.
- Free-form destination text may be saved only after native geocoding resolves
  coordinates.
- The UI must show Google attribution when displaying Places predictions outside
  a Google map.
- User can clear a saved location.
- Address geocoding occurs only after explicit save/validate or when a route
  request requires unresolved coordinates.
- Saved-location edits persist locally through native or a repository layer and
  push a v1 `CMD_DESTINATIONS` payload when the watch is ready.
- Empty placeholder rows are not rendered in Flutter or on the watch.
- A saved location can be used to start navigation, but this route path is a
  shortcut over the same route worker used by the Navigate screen.

## Settings Screen

MVP controls:

| Setting | Values | Owner |
| --- | --- | --- |
| Units | Imperial, metric | Phone UI pushed to watch |
| Default travel mode | Drive, walk, bike | Phone and watch reconciled |
| Theme | Auto/day, day, night | Phone and watch reconciled |
| Backlight | System/default, keep on during app where supported | Watch/phone reconciled |
| Centered map orientation | North up, face forward | Phone UI pushed to watch |
| Tile animation | No animation, fade in, fade + zoom | Phone UI pushed to watch |
| Map source | Road, satellite, hybrid, terrain | Phone UI/native provider |
| Rendered tile size | Supported watch tile crop presets | Phone UI/native provider |

Rules:

- Settings must persist locally.
- Watch startup settings from `CMD_INIT` may initialize empty phone settings.
- Explicit phone UI changes override and push to the watch.
- Theme changes must invalidate affected tile caches.
- Centered map orientation changes must call the normal display settings path
  and send `CMD_MAP_ORIENTATION`; they must not call `setMapTileSettings`,
  clear provider caches, or refresh the active route.
- Tile animation changes must call the normal display settings path and send
  `CMD_TILE_ANIMATION`; they must not call `setMapTileSettings`, clear provider
  caches, re-request tiles, or refresh the active route.
- Map source and rendered tile size changes must call native
  `setMapTileSettings`, clear affected tile caches, and send `CMD_MAP_SETTINGS`
  to the watch through the native bridge.
- Walk and bike modes must display the provider warning required by
  `../shared/ROUTING_MVP.md`.

Centered map orientation UI:

- Use a segmented control or compact selector labeled `Centered map`.
- Values are `North up` and `Face forward`.
- Default to `North up`.
- Do not present this as a global orientation that remains active after manual
  panning. It controls the GPS-follow camera only.
- Face-forward behavior, unsupported-state handling, manual-pan suspension,
  recenter behavior, and watch projection rules are defined by
  `../shared/MAP_ORIENTATION_SETTING_SPEC.md`.

Map tile setting UI:

- Use segmented controls or menus for map source and rendered tile size.
- Default to Road and compact `54x63` rendered tiles.
- Show a short status when the selected source or rendered tile size is being
  validated or when tiles are refreshing.
- Satellite and hybrid controls must use the word "satellite"; do not expose
  provider-only names such as `layerRoadmap` in primary UI copy.
- Terrain must explain only provider setup impact when validation fails; it must
  not describe internal Map Tiles request fields in normal use.
- The UI must not expose provider scale, response format, or palette-detail
  controls.

Not MVP:

- Automatic off-route reroute setting.
- Undocumented developer-only options.
- Notification-listener companion mode.

## Diagnostics Screen

Required controls:

- Show latest redacted diagnostic events.
- Export diagnostics by explicit user action.
- Clear diagnostic log.
- Clear map tile cache.
- Clear route cache.
- Clear provider validation cache/status.
- Show provider validation status.
- Show watch transport status and last command summaries.

Export behavior:

- Export uses `exportDiagnostics`.
- Exported data must match `../shared/DIAGNOSTICS_SPEC.md`.
- No automatic upload is allowed.
- Full API keys, access tokens, session tokens, and credential-like strings must
  be redacted.

## Copy Requirements

Watch-facing error text is defined in protocol/diagnostics specs and capped to
watch limits. Flutter copy may be longer but must stay direct.

Required concepts:

- The user supplies their own Google API key.
- Route, geocode, and map work is performed locally by the installed phone app
  using that key.
- There is no application account setup.
- Android key restrictions require the active package name and signing SHA-1.
- The installed app is labeled for users as Mappy.
- Watch-session notifications are for Android foreground-service visibility,
  not Google Maps notification reading.
- Explicit Google Maps shares are parsed by Mappy and rerouted with the user's
  configured provider settings.

Forbidden concepts:

- Any application-specific credential prompt.
- Any account or subscription upsell.
- Any unrelated application launcher.
- "Enable Google Maps notifications".
- "Use an unrestricted key".

## Empty And Failure States

Every screen must have a nonblank state for:

- Fresh install with no key.
- No watch connected.
- Watch connected but app not ready.
- Missing location permission.
- Network unavailable.
- Invalid/provider-blocked key.
- No destinations configured.
- No diagnostics yet.

The app must not crash or show a blank screen when native bridge status is
unavailable. It should show an actionable setup state and record a diagnostic
event.

## Accessibility And Layout

- All controls must have accessible labels.
- Important statuses must not rely on color alone.
- Text must wrap within phone width without clipping.
- Key input must support paste but must not expose the stored full value after
  submission.
- Diagnostic export and destructive clear controls require explicit user taps.

## Test Requirements

Widget tests:

- First launch shows the welcome flow when the welcome-seen flag is absent.
- Fresh install status shows missing-key and no-watch states.
- API key form rejects empty and incorrectly shaped input before native calls.
- Valid-looking key submission calls `storeApiKey` once.
- Navigate search shows autocomplete suggestions, resolves selected origin and
  destination predictions, and starts navigation without saving a
  saved-location record.
- Successful navigation leaves a visible active-route summary on the phone.
- Status shows foreground-service and notification permission readiness.
- Saved-location editing persists a variable-length list and caps watch names.
- Settings screen emits expected method channel payloads.
- Settings screen emits the display-settings payload for centered map
  orientation changes.
- Settings screen emits `setMapTileSettings` for map source and rendered tile
  size changes.
- Diagnostics screen renders redacted events and calls export/clear methods.

Integration/fake-native tests:

- Provider invalid state routes user to API Key screen.
- Permission denied state routes user to Permissions screen.
- Navigate-now search uses native provider autocomplete/details/geocode methods
  for both destination and optional specific origin, and invokes the route
  worker without mutating saved-location records.
- Full destination-list save pushes native `setDestinations`; single-slot
  patching may use `setDestination` but must receive the same
  v1 `CMD_DESTINATIONS` payload afterward.
- Map tile setting changes invalidate caches and produce a watch
  `CMD_MAP_SETTINGS` notification in fake-native tests.
- Diagnostic export contains no full key in test fixtures.

Static gates:

- Flutter code contains no application-service URL.
- Flutter code contains no notification listener, share target, Timeline, or
  unrelated credential flow.
- Flutter code never receives full stored API key from native status methods.

## Acceptance Criteria

- App starts to a useful welcome and Navigate/Status shell on a fresh install.
- First fresh launch shows the welcome flow; later launches go directly to the
  recurring app shell with Navigate as the primary tab.
- User can enter, validate, replace, and clear a Google API key without exposing
  the stored full value.
- User can understand and resolve Android package/SHA-1 restriction setup.
- User can grant or troubleshoot foreground location permission.
- User can grant or troubleshoot notification permission when required for the
  watch-session foreground service.
- User can explicitly open/start the watch app from the phone UI.
- User can search for a destination, optionally choose a specific origin, pick
  autocomplete results, and immediately start navigation without saving them.
- User can optionally grow the saved-location list and push it to the watch.
- User can change MVP settings and see watch/provider consequences.
- User can choose road, satellite, hybrid, or terrain map source and rendered
  tile size with visible validation/fallback states.
- User can export redacted local diagnostics.
- No MVP UI path depends on an application backend, share intents,
  notification-listener access, or PKJS runtime ownership.
