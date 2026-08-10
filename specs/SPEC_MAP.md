# Specification Map

This document maps each Mappy subsystem to its authoritative specification and
records the additional design work required before optional features can ship.

## Non-Negotiable Constraints

- Mappy is bring-your-own-key. Users provide their own Google API key.
- The application has no project-hosted route, tile, account, or logging
  service.
- The watch remains network-blind. The phone owns GPS, providers, tile
  generation, geocoding, routing, settings, and diagnostics.
- Exactly one phone-side runtime responds to watch AppMessage commands. For
  MVP, that runtime is Android native code inside the Flutter companion.
- PebbleKit JS is a packaged no-op for MVP.
- Google Map Tiles, Places, Geocoding, and Routes are the only specified MVP
  providers. There is no OSM/Nominatim fallback in MVP.

## Current Spec Inventory

Top-level specs:

- `PRODUCT_SPEC.md`: user-facing product requirements and workflows.
- `SYSTEM_ARCHITECTURE.md`: layers, ownership, state flow, and
  extension boundaries.
- `FEATURE_SCOPE.md`: capability status, ownership, and design rationale.
- `MVP_SCOPE.md`: first shippable backend-free milestone.
- `ACCEPTANCE_GATES.md`: test and verification gates for the spec set.

Shared specs:

- `shared/BYOK_PROVIDER_POLICY.md`: credential, provider, privacy, attribution,
  and no-backend policy.
- `shared/PROTOCOL_MVP.md`: AppMessage keys, commands, payloads, and errors.
- `shared/MAP_TILE_PIPELINE_MVP.md`: phone-generated raster tile contract.
- `shared/MAP_ORIENTATION_SETTING_SPEC.md`: centered-map orientation preference
  for north-up and face-forward GPS-follow rendering, including manual-browse
  suspension and recenter behavior.
- `shared/ROUTING_MVP.md`: direct Google navigate-now, route/geocode flow, and
  nav-step generation.
- `shared/SECURE_STORAGE_SPEC.md`: Android native key storage, redaction,
  clearing, backup, and migration policy.
- `shared/DIAGNOSTICS_SPEC.md`: local structured logs, redaction, export schema,
  retention, and cache controls.
- `shared/PROVIDER_ADAPTER_TEST_SPEC.md`: fakes, fixtures, restricted-key
  validation tests, and protocol replay coverage.
- `shared/COMPANION_SHARE_MODE_SPEC.md`: Google Maps share location/route
  intake, parser, privacy, and route-start contract.

Layer specs:

- `watch/WATCH_APP_MVP.md`: native Pebble Time 2 watch behavior.
- `watch/WATCH_UI_LAYOUT_SPEC.md`: `emery` layout, menus, text clipping, route
  styling, and screenshot verification.
- `watch/CURRENT_LOCATION_VIEW_CONE_SPEC.md`: Google Maps-style blue
  current-location puck and heading cone rendering.
- `watch/ROUTE_CONSUMED_OVERLAY_SPEC.md`: Google Maps-style consumed route
  overlay where already-covered route dots/line are hidden without deleting
  route geometry.
- `watch/TURN_HAPTIC_ALERT_SPEC.md`: Google Maps-style two-stage haptic cues for
  upcoming maneuvers.
- `watch/WATCH_TOUCH_INPUT_SPEC.md`: real-watch touch panning, no-pinch
  fallback, and future pinch zoom behavior for `PBL_TOUCH` platforms.
- `watch/WATCH_TILE_LOAD_ANIMATION_SPEC.md`: watch-side tile arrival animation
  modes after decoded map tiles load.
- `watch/PEBBLE_EMULATOR_FIXTURE_MODE_SPEC.md`: opt-in emulator fixture build
  that bundles synthetic payloads for local watch rendering checks.
- `mobile-companion/MOBILE_COMPANION_MVP.md`: Android-first Flutter companion
  and native bridge behavior.
- `mobile-companion/ANDROID_PEBBLE_BRIDGE_SPEC.md`: Android-native Pebble
  AppMessage transport, queueing, channels, lifecycle, and manifest policy.
- `mobile-companion/FLUTTER_UI_SPEC.md`: production setup, key, navigation
  search, saved locations, settings, and diagnostics UI.
- `companion-js/COMPANION_JS_MVP.md`: PKJS no-op packaging contract.

## Future Specs Required Before Post-MVP Extensions

The following areas remain intentionally outside MVP. Each requires a complete
design, privacy review, and acceptance criteria before implementation.

| Future spec | Required before |
| --- | --- |
| Planned: `shared/POST_MVP_OSM_PROVIDER_SPEC.md` | Any future OSM/Nominatim or non-Google provider. Requires attribution, terms, rate limits, routing coverage, cache policy, and privacy rules. |
| Planned: `watch/BACKGROUND_NAV_AND_POWER_SPEC.md` | Any future always-on background navigation beyond the active watch-session foreground service, including background-location permission, battery behavior, and stale-location handling. |

## Delivery Phases

### Phase 0: Scaffold Integrity

- Watch app builds with shared message keys.
- Mobile app launches the Flutter welcome/Navigate/Status shell without a
  backend dependency.
- PKJS remains no-op.
- Static checks prove release code uses only the documented provider endpoints
  and declared Android integration surfaces.

### Phase 1: Backend-Free MVP

- User enters a Google API key in the phone app.
- Android native code validates and uses the key locally.
- Watch receives GPS, map tiles, saved locations, route points, nav steps,
  settings, and recoverable errors.
- All map, geocode, and route calls are direct phone-side Google API calls.
- Diagnostics remain local and redacted.

### Phase 2: Production Hardening

- Release signing identity and SHA-1 fingerprints are fixed for the declared
  package ID.
- Key setup UX displays package and SHA-1 fingerprints.
- Provider fixtures and transport replay tests cover failure modes.
- Protocol, provider, and transport tests verify payloads, map tiles, routes,
  nav steps, inputs, and failure modes before hardware-only testing.
- Watch UI is verified on `emery` hardware or emulator equivalent.

### Phase 3: Optional Extensions

Any extension must keep the no-project-backend rule. Share/notification
companion mode, always-on background navigation beyond the active watch-session
foreground service, non-Google providers, voice, declination, or Timeline-like
features each require their own spec before implementation.
