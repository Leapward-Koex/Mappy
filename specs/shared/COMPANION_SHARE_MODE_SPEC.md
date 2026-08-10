# Companion Share Mode Spec

This spec defines Android Google Maps share handling for the Mappy companion.
It covers shared locations and shared routes received through Android
share intents, then routes on the Pebble by reusing the existing phone-side
provider and watch AppMessage pipeline.

The share target is part of MVP. It receives only an explicit user-selected
`text/plain` share and does not grant notification, account, or background
access.

## Ownership

| Responsibility | Owner |
| --- | --- |
| Android share intent filters | Android native app manifest |
| Incoming share parsing | Android native companion |
| Google Maps short-link redirect resolution | Android native companion |
| API key storage and provider calls | Existing Android native provider layer |
| Route cache, replacement, and stale-response dropping | Android native bridge |
| User-visible share status | Flutter companion UI |
| Watch route display | Existing Pebble watch protocol |

The Android native bridge remains the only production watch-facing AppMessage
runtime. PKJS must remain no-op for this feature.

## Android Manifest Surface

v1 adds only an Android `ACTION_SEND` share target for `text/plain` Google Maps
content.

Allowed:

- `android.intent.action.SEND`
- `android.intent.category.DEFAULT`
- `text/plain`

Forbidden for this feature:

- notification listener service,
- accessibility service,
- clipboard monitoring,
- background location permission,
- foreground navigation service,
- package queries beyond those needed by existing Pebble/Rebble integration,
- any API or account access that reads a user's recent Google Maps navigation
  history.

The share target must open Mappy to a share-routing status surface. It must not
silently route without making the app foreground-visible.

## Accepted Share Types

### Shared Location

A shared location is a Google Maps place, address, pin, or coordinate share that
does not contain a directions route.

Behavior:

- Resolve a destination label and coordinates from the share.
- Use the user's current/default Mappy travel mode.
- Route from current phone GPS to the destination.
- Auto-start watch navigation after a valid parse and route request.

### Shared Route

A shared route is a Google Maps directions or navigation share that contains a
destination and may contain an origin and travel mode.

Behavior:

- Resolve the destination from the share.
- If the share contains an explicit origin, use that origin for the Routes API
  request.
- If no explicit origin is present, use current phone GPS.
- Use the shared travel mode only when it maps to Mappy `drive`, `walk`, or
  `bike`.
- Auto-start watch navigation after a valid parse and route request.

Shared route geometry is always recomputed by Mappy's provider path. It may
differ from the route variant selected inside Google Maps.

## Parser Rules

The parser accepts only Google Maps shares. It must reject arbitrary web URLs
and non-Google map providers in v1.

Allowed URL hosts:

- `www.google.com`
- `google.com`
- `maps.google.com`
- `maps.app.goo.gl`
- `goo.gl` only when the redirect target resolves to an allowed Google Maps URL

Allowed schemes:

- `https`
- Android `geo:` or `google.navigation:` only when the source package is Google
  Maps or the parsed content clearly matches a Google Maps share

Redirect resolution:

- Resolve short links before parsing.
- Follow only HTTPS redirects.
- Use a bounded redirect limit, maximum 5 hops.
- Do not attach the user's Google API key, Places session tokens, cookies, or
  authorization headers.
- Reject redirects to non-allowlisted hosts.
- Reject redirects that require login or return non-redirect HTML that cannot
  be parsed safely.

Route URL parsing should recognize:

- `/maps/dir/...`
- `/maps/dir/?api=1&origin=...&destination=...`
- `destination`, `destination_place_id`, `origin`, `origin_place_id`
- `travelmode=driving|walking|bicycling`
- Android `google.navigation:q=...&mode=d|w|b`

Location URL parsing should recognize:

- `/maps/search/?api=1&query=...`
- `query_place_id`
- lat/lng coordinate pairs in query parameters or path segments,
- plain Google Maps share text that includes a place label/address and a Google
  Maps URL.

Unsupported in v1:

- transit,
- two-wheeler/motorcycle routing,
- multi-stop routes,
- avoid options,
- route alternatives,
- exact Google Maps selected route variants,
- arbitrary shared text with no Google Maps URL or supported Google Maps URI.

Unsupported travel modes must fail visibly instead of silently converting to
drive.

## Route Start Behavior

Valid incoming shares immediately replace the active route.

Route replacement sequence:

1. Increment the native route generation and clear pending route/nav step cache.
2. Send `CMD_ROUTE_CLEAR` to the watch when the previous route may still be
   visible.
3. Resolve shared origin and destination coordinates.
4. Call the existing route worker with the selected origin, destination, and
   travel mode.
5. Send normal route outputs on success:
   - `CMD_ROUTE_POINTS`,
   - first `CMD_NAV_STEPS` chunk when available.
6. Send existing watch errors on failure.

If the new route fails, do not restore the previous route. The visible state is
the failed share result.

The route worker must drop stale route and nav-step responses from older route
generations after a newer share, phone search, saved-location route, reroute, or
clear request starts.

## Watch Interaction

v1 requires no new AppMessage command.

The watch receives the same command set used by Navigate Now:

- `CMD_ROUTE_CLEAR`
- `CMD_ROUTE_POINTS`
- `CMD_NAV_STEPS`
- `CMD_ERROR_STATE`
- normal `CMD_GPS` and `CMD_TILE` updates

Phone-initiated share routing is not represented as a watch-originated
`CMD_ROUTE_REQUEST`.

If a shared route origin is not the user's current GPS location, the watch still
shows current GPS normally. Existing off-route or route-progress logic may show
the user away from the recomputed route; this is acceptable for v1 and must be
diagnosed as a shared-origin route rather than treated as a parser failure.

## Flutter Status UI

When Mappy receives a share, the app foregrounds to a share-routing status
surface.

Required states:

- parsing share,
- resolving short link,
- unsupported share,
- resolving origin or destination,
- route loading,
- active route summary,
- no route,
- provider/setup/location error.

The UI must show that Google Maps route shares are recomputed by Mappy and may
not exactly match Google Maps route alternatives.

The UI must not require confirmation before starting a valid route. It may offer
secondary actions after routing starts, such as save destination, change travel
mode, reroute, or clear route.

## Privacy And Diagnostics

Diagnostics must not store raw shared text or raw shared URLs by default.

Allowed diagnostic fields:

- event source = `google_maps_share`,
- share type = `location` or `route`,
- safe URL host,
- redirect hop count,
- whether origin was explicit,
- whether destination had coordinates,
- travel mode,
- provider/error category,
- timestamps,
- redacted labels capped for display.

Forbidden diagnostic fields:

- full raw share text,
- full raw URL,
- Google API key,
- Places session token,
- cookies or authorization headers,
- unredacted provider response bodies.

No share data may be uploaded to a project server or any other backend.

## Error Mapping

Use existing watch error categories where possible:

| Failure | Watch category |
| --- | ---: |
| Missing Google API key | 1 |
| Invalid/API disabled/quota/billing/provider permission denied | 2 |
| Missing current GPS when needed | 3 |
| Redirect/network unavailable | 4 |
| Unsupported or unparsable share | 6 |
| Origin/destination resolution failure | 6 |
| Unsupported travel mode | 6 |
| Provider route failure | 6 |
| No route found | 7 |

Unsupported shares should be visible in Flutter. The watch may receive category
6 only if a prior/active route was replaced or the watch otherwise needs a
visible state update.

## Test Requirements

Parser fixtures:

- Google Maps location share with coordinates.
- Google Maps location share requiring geocode fallback.
- Google Maps route share with explicit origin and destination.
- Google Maps route share with current-location origin.
- Google Maps short link redirecting to a valid Maps URL.
- Unsupported transit, two-wheeler, and multi-stop route shares.
- Non-Google URL and arbitrary text rejection.

Integration tests:

- Cold-start `ACTION_SEND text/plain`.
- Warm-start `ACTION_SEND text/plain` through `onNewIntent`.
- Location-only share starts with app default travel mode.
- Route share uses shared origin when present.
- New share replaces the active route and stale old responses are dropped.
- Missing key, missing location, geocode failure, no-route, network failure, and
  provider auth failure map to existing visible error categories.

Watch/protocol replay:

- Successful share route produces valid `CMD_ROUTE_POINTS`.
- Successful share route sends the first `CMD_NAV_STEPS` chunk when steps exist.
- Failed replacement clears or errors consistently and does not restore the old
  route.
- No new watch protocol command is required.

Privacy/security tests:

- Redirects are HTTPS-only, bounded, and Google-domain-only.
- No full API key, Places session token, raw share URL, or raw share text appears
  in diagnostics export.
- Manifest contains the share target and no notification listener,
  accessibility service, clipboard monitor, or background-location permission.

## Acceptance Criteria

- A Google Maps shared location auto-starts Pebble navigation through Mappy.
- A Google Maps shared route auto-starts Pebble navigation using the shared
  origin when present.
- Route geometry is recomputed by Mappy and labeled honestly.
- Incoming shares replace any active route.
- Unsupported route details fail visibly without silent mode conversion.
- The existing watch protocol remains sufficient for v1.
- The no-project-backend and local-redacted-diagnostics rules remain intact.
