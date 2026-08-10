# Mappy Product Spec

This spec defines Mappy from the user's point of view. The product is
bring-your-own-key and operates without a project-hosted application backend.

## Product Goal

Build a Pebble navigation app that shows a live map and route on the watch while
the phone performs all provider, location, routing, and setup work locally under
the user's control.

The core watch loop is: launch, see current location, start navigation from the
phone, receive a
route on the watch, view turn instructions, and request a reroute. Saved
destinations remain useful as optional watch shortcuts, but they are not the
primary route-starting workflow.

## Users

Primary user:

- Owns a Pebble-compatible watch and an Android phone.
- Is willing to configure a personal Google API key.
- Wants a compact watch navigation display without creating an application account,
  subscription, or proxy server.

Secondary user:

- Developer or tester using the Pebble emulator and local fake providers to
  verify protocol, tile, and route behavior.

## Core Workflows

### First Run Setup

1. User installs the mobile companion and watch app.
2. Mobile companion shows a dismissible welcome flow that explains Navigate
   Now, BYOK Google setup, foreground location, watch-session notification
   permission, and the active-watch foreground service.
3. User lands on the Navigate shell with Status available for readiness and
   recovery.
4. User grants location permission.
5. User grants notification permission when Android requires it for the
   user-visible watch-session foreground-service notification.
6. User enters a Google API key.
7. App validates that required APIs and Android restrictions are configured.
8. User can explicitly open/start the watch app from the phone if the watch is
   not active.
9. Watch shows either a setup-required state or the live map once prerequisites
   are ready.

The app must not make map, route, or geocode network calls before a key is
stored and the relevant operation is requested.

### Live Map

1. User opens the watch app.
2. Watch sends startup state to phone.
3. Phone sends current GPS world pixels and heading status.
4. Watch requests visible map tiles.
5. Phone fetches provider source tiles, creates 54x63 watch crops, encodes them,
   and sends them to the watch.
6. Watch renders a nonblank map with current location and heading when valid.

### Navigate Now Search

1. User opens the mobile companion's navigation search.
2. User keeps `From: Current location` or searches for a specific origin.
3. User types a destination place or address.
4. Mobile companion shows Google Places Autocomplete predictions from the
   Android native provider.
5. User selects the destination prediction, and selects an origin prediction
   only when not using current location.
6. Phone resolves Place Details needed for routing and immediately starts a
   route from the selected origin to that destination.
7. Phone sends route points and nav-step chunks to the watch.
8. Phone shows an active-route summary with distance/duration when known, first
   instruction when available, and reroute/clear controls.
9. Watch draws the route and displays turn guidance.

This flow must not require the user to save a saved location first. It is the
primary route-starting workflow.

Navigate Now origin behavior:

- Default origin is current phone location.
- Current-location origin requires a fresh enough phone GPS fix.
- User may choose a specific origin by searching a place or address with Google
  Places Autocomplete/Place Details through the native provider.
- Free-form origin text may be used only after native geocoding resolves
  coordinates.
- When a route uses a specific origin, the watch still displays the phone's live
  current-location marker normally. Route progress may be degraded until the
  phone location reaches or aligns with the planned route.

### Saved Locations

1. User may save frequently used destinations such as home, work, or custom
   places.
2. Phone resolves saved-location coordinates and pushes watch-visible
   saved-location records.
3. User may select a saved location on the watch as a quick route shortcut.
4. Phone fetches a route from current GPS to the saved location.

Saved locations are secondary convenience shortcuts. The app must not force a
save step before ordinary navigation.

### Reroute

1. User chooses reroute on the watch during active navigation.
2. Phone repeats the route request using the active origin policy and active
   destination. Current-location origins use fresh GPS; specific origins reuse
   the resolved origin unless the user changes it.
3. Watch updates route and steps on success or shows a recoverable route error.

Automatic off-route reroute is not MVP.

### Diagnostics

1. Watch and phone produce structured local diagnostic events.
2. Mobile app shows setup, key, permission, watch, tile, and route status.
3. User can export redacted diagnostics.
4. No diagnostic data is uploaded automatically.

## Product Requirements

### Setup And Key

- User supplies a Google API key.
- App explains required APIs: Google Map Tiles API, Places API, Geocoding API,
  and Routes API.
- App shows the active Android package name and SHA-1 signing fingerprint needed
  for key restrictions.
- App uses a user-facing label, `Mappy`, in Android launch surfaces and
  foreground-service notification surfaces.
- Key storage is local and secure.
- Key status is visible without exposing the full key.
- Input that is not shaped like a Google Maps Platform API key is rejected
  locally before any provider request.
- There is no application account setup.
- Setup and Status show actionable fix text for invalid key, disabled API,
  quota/billing, Android package/SHA mismatch, network failure, missing
  location, missing notification permission, and missing watch bridge.

### Provider Policy

- MVP provider is direct phone-side Google APIs only.
- There is no OSM/Nominatim fallback in MVP.
- No alternate provider may be wired until a provider-specific spec defines
  attribution, rate limits, cache policy, errors, and privacy rules.
- The watch never receives an API key, provider token, route proxy token, or
  account credential.

### Watch Experience

- Watch must boot to a stable state without the phone.
- Watch must show setup-required states for missing key, invalid key, or missing
  location permission.
- Watch map must remain usable when one tile fails.
- Watch must avoid stale heading display when heading is unavailable.
- Watch centered-map orientation defaults to north-up and may be changed to
  face-forward, where geographic layers rotate while GPS-follow is active so the
  wearer-facing compass direction points toward the top of the screen. Manual
  panning exits follow mode, suspends auto-rotation, and leaves recenter as the
  way back.
- Watch route errors must not crash or blank the map.
- Watch route display for walking or bicycling must include a compact provider
  warning that safe path detail may be incomplete.

### Mobile Experience

- Mobile app is the authority for setup, primary destination search/navigation,
  optional saved locations, settings, diagnostics, and provider calls.
- Mobile app shows active watch connection and setup readiness.
- Mobile app exposes local cache clear controls.
- Mobile app must be usable without an application account.
- Android is required for MVP; iOS remains scaffold until Pebble transport is
  specified.

### Privacy

- Location, destinations, routes, logs, and API keys remain local except for
  user-initiated direct calls to configured map/routing providers.
- Logs and diagnostics redact API keys and credential-like text.
- There is no server-side log collection in MVP.

## Non-Goals

MVP does not include:

- A project-hosted API, account, or request proxy.
- Google Maps notification listener companion mode.
- Network declination lookup; an already-known correction may be sent to the watch.
- Automatic off-route reroute.
- OSM/Nominatim fallback.
- Background navigation.

## Success Criteria

- A fresh install without a key reaches visible setup states on phone and watch.
- A valid restricted Google API key enables map tiles and route requests without
  any project-hosted endpoint.
- Watch renders a nonblank live map on the target Pebble Time 2 geometry.
- Autocomplete-backed destination search can immediately start navigation and
  produce a route and first instruction without saving the destination.
- Navigate Now can route from current location by default or from a specific
  Google-resolved origin selected by the user.
- Saved-location route selection remains available as a secondary shortcut.
- User-triggered reroute works or reports a recoverable error.
- Diagnostics can be exported without secrets.
