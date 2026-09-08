# Mappy

Mappy is a free and open-source map and navigation system for Pebble watches.
The watch app is intentionally network-blind; a dedicated mobile companion owns
location, provider access, routing, tile generation, settings, and diagnostics.

## Layout

- `apps/pebble-watch` - Pebble SDK watch app targeting Pebble Time 2.
- `apps/mobile-companion` - dedicated Flutter Android companion app pinned to
  Flutter 3.44.1.
- `specs` - product, architecture, MVP, provider, protocol, and
  layer behavior specifications.
- `tooling` - local setup helpers for development environments.
- `.agents/skills/pebble-emulator` - repository-scoped Codex workflow for
  building and testing the watch app in the Pebble emulator.

## Current Scope

The app is backend-free: the user supplies a Google Maps Platform API key, and
the Android companion performs map, route, tile, location, and diagnostic work
locally. The current implementation includes the native Android bridge, BYOK
provider path, a three-tab Flutter interface (Navigate, Saved, and Settings),
focused setup and permission recovery, active-route restoration, watch
transport, a one-time first-run setup checklist, map tile/routing workers,
diagnostics, and local tests. Final
release signing and hardware/device acceptance remain release gates.

## API usage controls

Settings > API usage shows local estimates for 2D Map Tiles, Geocoding, Places
Autocomplete Requests, Place Details Pro, and Compute Routes Essentials.
Google API requests are enabled by default, with global Block
mode at the editable free allowances; Warn mode continues requests and warns at
80% and 100%. A master switch pauses new phone/watch requests and embedded map
previews. Cached or offline work does not consume usage.

Counters and settings persist locally, independent of the API key. Monthly
rollover defaults to day 1 at device-local midnight; days 29–31 clamp to the last
day in shorter months. Changing the day preserves counters and moves the next
reset to the first matching date on or after the previously scheduled reset.
There is no manual reset or historical usage report.

These estimates do not guarantee free usage: previous usage, other apps/devices,
Google's session billing rules, and pricing changes may differ. Failed dispatched
requests count conservatively. Google normally resets free caps on the first at
midnight Pacific US time. Defaults use the [global Google pricing list](https://developers.google.com/maps/billing-and-pricing/pricing),
reviewed 2026-09-08; confirm allowances and billing dates in Google Cloud.

The native `ApiUsageTracker` serializes reservations and saves before HTTP
dispatch, including setup validation and retry attempts. Storage failures block
new requests. Tile session creation is guarded but consumes zero tile units;
autocomplete session discounts are not deducted. Place Details uses Pro because
the current field mask includes `displayName`. Maps SDK uses the developer-managed
embedded SDK key and is excluded from user usage tracking and allowances. The
master switch still pauses embedded previews. Revisit the fixed catalog when
changing provider endpoints or field masks.
