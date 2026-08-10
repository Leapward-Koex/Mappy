# Feature Scope

This map records the current status and ownership of Mappy capabilities. It is a
product-scope index rather than a second implementation contract; linked specs
remain authoritative.

Status labels:

- `MVP`: required for the first release.
- `MVP design`: required with Mappy-specific behavior described in its spec.
- `MVP optional`: supported by the protocol but valid to omit when the phone has
  no value to supply.
- `Post-MVP`: not in the first release; requires the linked spec or an amendment.
- `Out of scope`: intentionally excluded.

## Core Features

| Capability | Status | Authoritative spec | Notes |
| --- | --- | --- | --- |
| Startup sync | MVP | `shared/PROTOCOL_MVP.md`, `watch/WATCH_APP_MVP.md` | Watch sends readiness and persisted settings through `CMD_INIT`. |
| GPS display | MVP | `shared/PROTOCOL_MVP.md`, `mobile-companion/MOBILE_COMPANION_MVP.md` | Phone sends zoom-16 world pixels and heading or invalid-heading sentinel. |
| Map tiles | MVP | `shared/MAP_TILE_PIPELINE_MVP.md` | Use 54x63 crops, palette indexes, RLE payloads, and watch-side decode. |
| Centered map orientation | MVP design | `shared/MAP_ORIENTATION_SETTING_SPEC.md` | Phone owns north-up/face-forward preference; manual browsing is north-up. |
| Tile cache | MVP design | `watch/WATCH_APP_MVP.md` | Target a 5x5 visible grid on `emery`, subject to measured memory limits. |
| Theme | MVP | `watch/WATCH_APP_MVP.md` | Theme changes clear tile cache and request fresh tiles. |
| Backlight | MVP | `watch/WATCH_APP_MVP.md` | Watch reports startup value; phone can push user setting. |
| Units | MVP | `shared/PROTOCOL_MVP.md` | Phone pushes imperial/metric mode. |
| Saved locations | MVP | `shared/PROTOCOL_MVP.md`, `mobile-companion/MOBILE_COMPANION_MVP.md` | Use a dynamic watch-visible list with 30-byte labels and a versioned payload marker. |
| Missing saved-location ID | MVP design | `watch/WATCH_APP_MVP.md`, `shared/PROTOCOL_MVP.md` | A stale or missing ID returns category 8. |
| Route request | MVP | `shared/ROUTING_MVP.md` | Phone autocomplete is primary; saved-location watch shortcuts are secondary. |
| Route payload | MVP | `shared/PROTOCOL_MVP.md` | Use zoom-16 route points and a 128-point cap. |
| No-route state | MVP | `shared/PROTOCOL_MVP.md`, `shared/ROUTING_MVP.md` | Zero-point payload clears the route, followed by a visible error. |
| Route compaction and detail windows | MVP | `shared/ROUTING_MVP.md` | Deterministic overview simplification plus generation-correlated high-detail windows. |
| Navigation steps | MVP | `shared/PROTOCOL_MVP.md`, `watch/WATCH_APP_MVP.md` | Phone sends up to three records; watch requests later chunks. |
| Route progress | MVP design | `watch/WATCH_APP_MVP.md` | Explicit thresholds are covered by deterministic tests. |
| Manual reroute | MVP | `shared/ROUTING_MVP.md` | User-triggered reroute uses the active destination. |
| Diagnostics | MVP | `mobile-companion/MOBILE_COMPANION_MVP.md`, `ACCEPTANCE_GATES.md` | Local, bounded, redacted diagnostics only. |

## Phone Runtime and Setup

| Capability | Status | Authoritative spec | Notes |
| --- | --- | --- | --- |
| Android native watch runtime | MVP | `SYSTEM_ARCHITECTURE.md`, `mobile-companion/ANDROID_PEBBLE_BRIDGE_SPEC.md` | Android owns transport and background session work. |
| Flutter setup UI | MVP | `PRODUCT_SPEC.md`, `mobile-companion/FLUTTER_UI_SPEC.md` | Native Flutter screens own configuration and status. |
| Google API key setup | MVP | `shared/BYOK_PROVIDER_POLICY.md` | Validate and store a user-supplied key securely. |
| Project-hosted application backend | Out of scope | `shared/BYOK_PROVIDER_POLICY.md` | Provider requests are made directly from the phone. |
| Google Map Tiles provider | MVP | `shared/MAP_TILE_PIPELINE_MVP.md` | Use documented Google Maps Platform APIs. |
| Google Geocoding/Routes provider | MVP | `shared/ROUTING_MVP.md` | Direct phone-side calls with the user's key and Android restrictions. |
| Additional map providers | Post-MVP | `shared/BYOK_PROVIDER_POLICY.md` | Requires a provider-specific attribution, privacy, and rate-limit spec. |

## Companion And External Integrations

| Capability | Status | Authoritative spec | Notes |
| --- | --- | --- | --- |
| Google Maps share parsing | MVP | `shared/COMPANION_SHARE_MODE_SPEC.md` | Mappy recomputes routes from shared destinations. |
| Google Maps notification live HUD | Post-MVP | `SPEC_MAP.md` | Requires notification-listener permission spec and user consent. |
| Share-originated route start | MVP | `shared/COMPANION_SHARE_MODE_SPEC.md` | Reuses the existing phone-originated route outputs; no new watch command is required. |
| Compass declination input | MVP optional | `watch/CURRENT_LOCATION_VIEW_CONE_SPEC.md`, `shared/PROTOCOL_MVP.md` | The phone may supply a signed correction; raw magnetic heading remains valid when unavailable. |
