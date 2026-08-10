# System Architecture

This spec defines Mappy layers, ownership, lifecycle, and data boundaries. The
watch stays network-blind while Android owns provider and session work. PKJS is
packaged only as a no-op compatibility entrypoint for MVP.

## Layer Overview

| Layer | MVP responsibility |
| --- | --- |
| Pebble native watch app | UI, input, viewport, tile requests, RLE decode, map/route rendering, small settings persistence, diagnostic events. |
| Android native bridge | Pebble transport, send queue, ACK/NACK handling, secure key access, Android identity headers, location, providers, tile worker, route worker. |
| Flutter mobile UI | Setup, key entry, primary navigation search, optional saved-location editing, settings, status dashboard, diagnostics export. |
| PebbleKit JS | Packaged no-op only for MVP. |
| External providers | Google Map Tiles, Places, Geocoding, and Routes, called directly by Android native code with the user's key. |

There is no project-hosted application backend layer in the MVP.

## Ownership Rules

| Data or behavior | Owner | Notes |
| --- | --- | --- |
| API key | Android native secure storage | Flutter can submit a new key once; watch and PKJS never receive it. |
| Provider calls | Android native bridge | Direct Google API calls only for MVP. |
| Phone GPS | Android native bridge | Converted to zoom-16 world pixels before watch send. |
| Map tile source and size settings | Flutter UI plus Android native persistence | Phone-owned; watch receives only cache invalidation. |
| Map source tiles | Android native tile worker | Cached locally within provider policy and keyed by map source. |
| Watch tile crops | Android native tile worker | 54x63 palette/RLE payloads. |
| Watch tile cache | Watch | Target grid is sized for `emery`, initially 5x5. |
| Active route target | Android native route worker | May come from mobile autocomplete search or a saved-location record. |
| Saved locations | Flutter repository and Android bridge copy | Optional shortcuts; watch receives only compact display records. |
| Route fetch and simplification | Android native route worker | Output capped for watch protocol. |
| Nav-step full list | Android native route cache | Watch receives chunks and requests more. |
| Theme/travel/backlight startup values | Watch plus phone reconciliation | Watch reports persisted values in `CMD_INIT`; phone pushes user changes. |
| Centered map orientation | Phone UI plus watch startup reconciliation | Phone persists the user preference; watch applies north-up or facing-up projection locally only while GPS-follow is active. Manual pan uses north-up browse mode until recenter. |
| Units | Phone UI | Pushed to watch. |
| Diagnostics | Phone local repository | Watch emits events; export is user-initiated and redacted. |

## Runtime Topology

```text
Pebble watch app
  <AppMessage>
Android native bridge
  <method/event channels>
Flutter companion UI

Android native bridge
  -> PebbleKit Android 2 listener service
  -> watch-session foreground service
  -> Android location APIs
  -> Google Map Tiles API
  -> Google Places API
  -> Google Geocoding API
  -> Google Routes API
  -> local secure storage
  -> local diagnostics/cache storage
```

Runtime network access is limited to the provider endpoints named by the shared
provider specifications.

## Startup Lifecycle

1. Watch loads persisted theme, travel mode, backlight, centered map
   orientation, and optional zoom.
2. Watch opens AppMessage and sends `CMD_INIT`.
3. PebbleKit Android 2 binds to the Android listener service and wakes the
   companion process if needed.
4. Android starts the watch-session foreground service for the active watch app.
5. Android bridge marks the watch connected.
6. Bridge reconciles watch startup settings with phone-side settings.
7. Bridge sends current setup state:
   - missing key,
   - invalid key/provider setup issue,
   - missing location permission,
   - waiting for GPS,
   - ready.
8. When ready, bridge sends saved locations and latest GPS.
9. Watch requests visible tiles.

Repeated `CMD_INIT` messages are idempotent. Reconnect should resend current
settings, saved locations, latest GPS, and active route summary when available.
When PebbleKit reports the watch app has closed, or active-app reconciliation
confirms another watch app is active, Android stops the watch-session foreground
service after the specified grace period and when no required work remains.

## Setup Lifecycle

1. Flutter collects the user-entered Google API key.
2. Flutter passes the raw key to Android native using `storeApiKey`.
3. Native stores the key securely.
4. Native validates provider access and Android restriction behavior.
5. Native emits redacted status to Flutter.
6. Native emits watch setup errors until route/tile prerequisites are ready.

The key is never compiled into the app and never written to logs.

## Tile Lifecycle

1. Watch computes visible 54x63 crop origins.
2. Watch sends `CMD_TILE_REQUEST` for missing crops.
3. Bridge deduplicates in-flight requests.
4. Tile worker loads Google source tiles through a session token created for the
   current map source setting.
5. Tile worker samples the returned source dimensions into 54x63 logical watch
   crops, applies palette mapping, and RLE-encodes.
6. Bridge sends one complete `CMD_TILE` payload.
7. Watch validates, decodes, caches, and renders.

When Flutter changes map source or rendered tile size settings, Android native
clears affected sessions/caches and sends `CMD_MAP_SETTINGS` so the watch drops
stale visible tile crops and requests the same world x/y/zoom grid again.

Tile failures produce `CMD_ERROR_STATE` and must not clear a valid prior map.

## Route Lifecycle

Primary phone-started route:

1. User keeps `From: Current location` or searches for a specific origin in
   Flutter.
2. User searches for a destination place/address in Flutter.
3. Bridge returns Google Places Autocomplete predictions through native provider
   code.
4. User selects the destination prediction, and selects an origin prediction
   when not using current location.
5. Bridge resolves Place Details and starts navigation immediately without
   saving a saved-location record.
6. Route worker calls Google Routes API directly with current phone GPS or the
   resolved explicit origin.
7. Route worker decodes and simplifies route geometry to the watch cap.
8. Bridge sends `CMD_ROUTE_POINTS`.
9. Bridge sends the first `CMD_NAV_STEPS` chunk.
10. Watch renders route and advances local steps as GPS progresses.
11. Watch requests additional step chunks from phone cache.

Saved-location route shortcut:

1. Watch sends `CMD_ROUTE_REQUEST` with saved-location ID and travel mode.
2. Bridge validates key, location freshness, and saved-location configuration.
3. Bridge resolves/geocodes the saved location if coordinates are missing or
   stale.
4. Route worker follows the same route fetch/output path as phone-started
   navigation.

No-route responses use the zero-point route payload, then an error state.

## Error Flow

The phone reports recoverable errors with `CMD_ERROR_STATE`. The watch preserves
valid stale state where possible:

- Missing/invalid key blocks new provider work but does not erase existing UI.
- Location errors pause route progression.
- Tile errors leave stale or blank tile slots.
- Route provider errors keep prior route unless a no-route payload explicitly
  clears it.

## PKJS Boundary

The MVP PKJS bundle exists only to satisfy Pebble packaging. It must not:

- read or store credentials,
- register a watch AppMessage responder,
- make network calls,
- access localStorage,
- implement config pages,
- parse shares or notifications,
- relay credentials or trip data to unrelated applications.

If PKJS becomes necessary for a future platform, a new bridge spec must define
local-only communication, secret handling, and duplicate-worker prevention.

## Extension Boundaries

Future features are allowed only through spec updates:

- Always-on background navigation beyond the active watch-session foreground
  service requires background-location permission, notification, stale GPS,
  user controls, and battery policy.
- Notification-listener companion mode requires an explicit Android permission
  and privacy spec. The current share target is governed by
  `shared/COMPANION_SHARE_MODE_SPEC.md`.
- OSM/Nominatim or another provider requires a provider-specific spec.
- New sensor sources and external integrations require separate feature specs.

The no-project-backend rule applies to every future phase.
