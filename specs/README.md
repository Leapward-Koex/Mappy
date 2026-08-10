# Mappy Specifications

This directory is the authoritative product and engineering contract for Mappy.

Core constraints:

- Mappy is bring-your-own-key and has no project-hosted application backend.
- Credentials stay in Android secure storage and diagnostics stay local unless
  the user explicitly exports them.
- MVP uses direct phone-side Google Map Tiles, Places, Geocoding, and Routes
  APIs with the user's key.
- There is no OSM/Nominatim fallback in MVP.

## Top-Level Specs

- `SPEC_MAP.md`: spec ownership map and future spec inventory.
- `PRODUCT_SPEC.md`: product workflows, requirements, and non-goals.
- `SYSTEM_ARCHITECTURE.md`: layers, ownership, lifecycles, and data
  boundaries.
- `FEATURE_SCOPE.md`: capability status, ownership, and design rationale.
- `MVP_SCOPE.md`: first shippable backend-free MVP scope.
- `ACCEPTANCE_GATES.md`: verification gates for implementation and release.

## Layer Specs

- `watch`: Pebble watch app specs.
- `mobile-companion`: Flutter companion and Android native bridge specs.
- `companion-js`: PebbleKit JS packaging/no-op specs.
- `shared`: cross-layer protocols, providers, routing, tiles, and policy.

## Current MVP Specs

- `shared/BYOK_PROVIDER_POLICY.md`: credential, provider, privacy, attribution,
  and no-backend policy.
- `shared/PROTOCOL_MVP.md`: AppMessage command/key and payload contract.
- `shared/MAP_TILE_PIPELINE_MVP.md`: map tile generation and
  rendering contract.
- `shared/MAP_ORIENTATION_SETTING_SPEC.md`: north-up versus face-forward
  centered-map orientation preference, follow/manual-browse behavior, sync,
  projection, and tile coverage requirements.
- `shared/ROUTING_MVP.md`: phone-side navigate-now, route/geocoding flow, and
  nav-step generation.
- `shared/SECURE_STORAGE_SPEC.md`: Android native secure API-key storage and
  redaction policy.
- `shared/DIAGNOSTICS_SPEC.md`: local diagnostic event schema, redaction, export,
  and retention policy.
- `shared/PROVIDER_ADAPTER_TEST_SPEC.md`: provider fakes, golden fixtures,
  restricted-key checks, and protocol replay tests.
- `shared/COMPANION_SHARE_MODE_SPEC.md`: Android Google Maps share
  location/route intake and navigation startup.
- `watch/WATCH_APP_MVP.md`: Pebble Time 2 native watch behavior.
- `watch/WATCH_UI_LAYOUT_SPEC.md`: target watch layout, menu, state, and
  screenshot verification rules.
- `watch/CURRENT_LOCATION_VIEW_CONE_SPEC.md`: Google Maps-style current-location
  puck and view cone glyph.
- `watch/WATCH_TOUCH_INPUT_SPEC.md`: real-watch touch panning, no-pinch
  fallback, and future pinch zoom behavior for `PBL_TOUCH` platforms.
- `watch/WATCH_TILE_LOAD_ANIMATION_SPEC.md`: no-animation, fade-in, and fade +
  zoom tile arrival behavior after decoded map tiles load on the watch.
- `watch/PEBBLE_EMULATOR_FIXTURE_MODE_SPEC.md`: opt-in emulator-only watch
  fixture build mode for local tile/route rendering checks without a phone.
- `mobile-companion/MOBILE_COMPANION_MVP.md`: Android-first Flutter companion
  and native bridge behavior.
- `mobile-companion/ANDROID_PEBBLE_BRIDGE_SPEC.md`: Android Pebble transport,
  queueing, channel, lifecycle, and manifest requirements.
- `mobile-companion/FLUTTER_UI_SPEC.md`: production setup, key, navigation
  search, saved-location, settings, and diagnostics UI requirements.
- `companion-js/COMPANION_JS_MVP.md`: explicit no-op PKJS scope for MVP.
