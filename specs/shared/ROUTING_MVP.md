# Routing MVP Spec

This spec defines route fetching, route simplification, route payload creation,
and nav-step generation for the backend-free Mappy MVP.

The phone companion performs all routing work locally using the user's Google
API key. The watch never calls route services and never receives the API key.

## Provider

MVP route provider:

- Google Routes API `computeRoutes`.
- Endpoint: `https://routes.googleapis.com/directions/v2:computeRoutes`.
- Called directly from the Android phone companion with the user's API key.
- Each direct Google Geocoding and Routes REST request must include
  `X-Android-Package` and `X-Android-Cert` from the native Android HTTP adapter.
  `X-Android-Cert` is the active signing-certificate SHA-1 digest encoded as
  40 hex characters with no delimiters.

This is a backend-free design. The phone calls documented Google provider APIs
directly with the user's configured key.

Reference docs:

- Google Routes API get-route guide:
  `https://developers.google.com/maps/documentation/routes/compute_route_directions`
- Google Geocoding API:
  `https://developers.google.com/maps/documentation/geocoding`

Required Google APIs:

- Routes API.
- Geocoding API for free-form origin/destination address resolution.

No project-hosted backend or route proxy participates in MVP.

## Inputs

Route request inputs:

```text
origin:
  source = current_location | explicit_place
  route_origin_id phone-local diagnostic ID
  current phone GPS lat/lng when source = current_location
  freshness timestamp when source = current_location
  label when source = explicit_place
  formatted_address or address_text when source = explicit_place
  optional Google place_id/provider metadata when source = explicit_place
  resolved lat/lng when source = explicit_place

route_target:
  route_target_id phone-local diagnostic ID
  source = ad_hoc_search | saved_location_slot
  saved_location_id 0..253 when source = saved_location
  label
  formatted_address or address_text
  optional Google place_id/provider metadata
  optional resolved lat/lng

travel_mode:
  walk | bike | drive

settings:
  units for display text
  language/region if configured
```

Navigate Now defaults to `origin.source = current_location`. Current-location
origin must be fresh enough for navigation. If no fresh current-location origin
exists, phone sends `CMD_ERROR_STATE` category 3 with text such as
`Waiting for GPS` and preserves any prior valid route. Category 4 is reserved
for network unavailability.

User-selected specific origins use `origin.source = explicit_place`. Explicit
origins must resolve to coordinates through Google Places Place Details or
Geocoding before a route request. They do not require a fresh phone GPS fix for
route fetch, but live route progress remains degraded until the phone has a
fresh location that can be projected onto the planned route.

Primary route targets come from the mobile companion's autocomplete-backed
Navigate Now search. Selecting a destination Places prediction, and selecting an
origin prediction when not using current location, must resolve coordinates and
start routing immediately without requiring a saved location. Saved-location
saved locations are secondary shortcuts and watch menu entries.

Saved-location coordinates should be reused until the saved address changes or
the user explicitly refreshes the resolution. Ad-hoc destination and explicit
origin coordinates stay in the active route cache only as long as needed for
reroute/navigation state.

## Place Resolution

The preferred origin/destination resolution path is:

1. Google Places Autocomplete while the user types.
2. Google Place Details for the selected prediction.
3. Google Geocoding only for free-form origin/destination text or saved records
   without resolved coordinates.

The phone geocodes only when:

- explicit origin or destination has no resolved coordinates,
- explicit origin or destination address text changed,
- stored coordinates are marked invalid,
- user requests refresh.

Geocoding results stored locally:

```text
lat
lng
formatted_address if available
provider_metadata:
  provider = "google_geocoding"
  place_id = optional opaque Google Geocoding result identifier if present
last_geocoded_at
status
```

Provider metadata is phone-local, optional for MVP routing, and never sent to
the watch. Navigate Now origin/destination search and saved-location editing may
populate the same fields from Google Places Autocomplete/Place Details before
falling back to Geocoding.

Geocoding failures:

| Failure | Watch behavior |
| --- | --- |
| Missing API key | `CMD_ERROR_STATE` category 1 |
| Invalid key/API disabled/quota/billing/permission denied | `CMD_ERROR_STATE` category 2 |
| Network unavailable | `CMD_ERROR_STATE` category 4 |
| No matching geocoding result | `CMD_ERROR_STATE` category 6 with clear text |
| Missing/unconfigured saved-location ID | `CMD_ERROR_STATE` category 8 |
| Non-auth provider failure | `CMD_ERROR_STATE` category 6 |

## Route Fetch

The phone sends a Routes API request with:

- origin lat/lng,
- destination lat/lng,
- selected travel mode,
- no alternative routes for MVP,
- field mask limited to MVP data, initially:

```text
routes.duration,
routes.distanceMeters,
routes.polyline.encodedPolyline,
routes.legs.steps.startLocation,
routes.legs.steps.distanceMeters,
routes.legs.steps.staticDuration,
routes.legs.steps.navigationInstruction
```

If Google changes field names, the provider adapter must map the current fields
into the normalized model below and update this spec before implementation.

Travel mode mapping:

| MVP | Google |
| --- | --- |
| walk | `WALK` or current equivalent |
| bike | `BICYCLE` or current equivalent |
| drive | `DRIVE` |

Transit is not MVP.

Walking and bicycling route modes require a visible provider warning wherever
the route is displayed. The warning must explain that these beta modes may miss
safe pedestrian or bicycling path detail. The watch must display a compact
warning while an active `walk` or `bike` route is shown; the mobile app must show
the same warning in route status and travel-mode setup. Drive routes do not need
this warning.

When a fresh/user-visible walking route starts on the watch, the watch gives one
short vibration and moves immediately to the maximum supported map zoom before
requesting visible tiles for the active route. This behavior does not apply to
silent route refreshes, route detail window updates, bike routes, or drive
routes.

## Route Output Model

Phone normalizes provider response into:

```text
RouteResult:
  target_source
  destination_slot optional
  destination_label
  place_id/provider_id optional
  travel_mode
  total_distance_m
  total_duration_s
  raw_polyline_lat_lng[]
  simplified_route_points_world[]
  steps[]

Step:
  global_idx
  start_lat
  start_lng
  start_world_x_zoom16
  start_world_y_zoom16
  instruction_text
  distance_m
  duration_s
  remaining_m
  remaining_s
```

All watch route points use zoom-16 world pixels.

## Simplification

The watch route cap is 128 points for MVP.

Simplification pipeline:

1. Decode provider encoded polyline to lat/lng points.
2. Preserve first and last points.
3. Apply a deterministic line simplification or downsampling algorithm.
4. If still over 128 points, downsample deterministically to 128.
5. Convert final points to zoom-16 world pixels.

Requirements:

- Same input route must produce the same output point sequence.
- Simplification must not remove both endpoints.
- Short routes should preserve more local detail than long routes.
- If simplification produces fewer than two points for a non-empty route, treat
  the route as invalid provider output and send route error category 6.

The simplification algorithm should prefer shape-preserving reduction such as
Douglas-Peucker over uniform index sampling. Uniform downsampling is acceptable
only as a deterministic final budget fallback after higher-value bend points
have been preserved.

Feathered route compaction is allowed within the MVP payload shape when it does
not require new watch protocol. For long routes, the
phone may spend more of the 128-point budget near the current position and
destination, while using a looser middle-route overview. This keeps local
navigation accuracy high without increasing watch memory use.

## Route Detail Windows

MVP uses a route level-of-detail model instead of trying to keep the entire
high-resolution provider polyline on the watch.

Target architecture:

1. The phone owns the full decoded provider polyline and assigns each active
   route a phone-local route generation.
2. The watch keeps a whole-route overview polyline suitable for zoomed-out
   display and route progress fallback.
3. The watch may also keep a high-detail route window around the current GPS
   position or manually panned viewport.
4. At zoomed-out levels, the watch draws only the overview polyline.
5. At zoomed-in levels, the watch draws the detail window when it is available
   and falls back to the overview until fresh detail arrives.
6. The phone builds route windows from the full decoded polyline using the
   requested viewport bounds, current map zoom, and a prefetch margin of several
   visible tile spans.
7. When the viewport, zoom, or GPS-follow position approaches the edge of the
   loaded detail window, the watch requests another window before the user can
   pan into missing detail.

Route-window detail must not be the watch's only route state. Destination
display, route progress, nav-step matching, and off-route checks need a stable
whole-route overview or equivalent route-progress model even when the visible
detail window is missing, stale, or still in transit.

The route point order is also the display direction for
`watch/ROUTE_CONSUMED_OVERLAY_SPEC.md`. The phone must preserve route start to
destination ordering when simplifying, downsampling, or building detail windows
so the watch can hide only the traveled portion of the route.

If the point cap is raised again, the implementation must heap-test both
persistent route storage and temporary draw/projection buffers on target
hardware. Candidate caps such as 196 points fit within the current AppMessage
inbox as a single payload, but memory and route-projection cost on the watch
remain the shipping constraints.

`PROTOCOL_MVP.md` defines the dedicated route-window request/response commands,
route generation correlation, requested world center and radius, returned
window bounds, and stale-window rejection rules. Route windows do not overload
map tile requests.

## Route Payload

Successful route:

1. Send `CMD_ROUTE_POINTS` with point count 2..128.
2. Send first `CMD_NAV_STEPS` chunk if steps exist.

No route:

1. Clear phone active route and step cache.
2. Cancel queued stale route/nav messages for the failed request.
3. Send `CMD_ROUTE_POINTS.chunk_data = [0, 0, 16]`, meaning uint16 point count
   zero plus zoom-16 header.
4. Send no `CMD_NAV_STEPS`.
5. Send `CMD_ERROR_STATE` category 7 with short text.

Route provider failure:

- Send `CMD_ERROR_STATE` category 6.
- If the provider returns a non-empty route that simplifies to one point, treat
  it as invalid provider output: send category 6 and do not clear a valid prior
  route.
- Do not clear a valid prior route unless provider explicitly returned no route
  for the current request and the zero-point payload has been sent.

Payload byte formats are defined in `PROTOCOL_MVP.md`.

## Nav-Step Generation

Step generation:

1. Read provider step list.
2. Strip or normalize HTML/markup from instructions.
3. Convert instruction to compact display text where unambiguous.
4. Truncate to 47 UTF-8 bytes on code point boundaries.
5. Compute each step start world pixel at zoom 16.
6. Compute remaining distance/time from step start to route end.
7. Store full step list in phone route cache.
8. Send up to three records per `CMD_NAV_STEPS` payload.

The watch uses step start pixels and remaining distance/time to derive local
turn-haptic timing; no separate haptic payload is sent by the phone for MVP.

MVP supports at most 255 nav steps per route because total, first index, and
step index are one-byte fields in the watch protocol. If a provider returns more
than 255 usable steps, the phone must coalesce or truncate deterministically
before caching/packing, preserving the first and final arrival-relevant steps.

The watch may request later chunks with `CMD_NAV_STEPS.button_id`.
The phone must answer from local route-step cache without another Routes API
call.

If provider response has route geometry but no usable steps:

- Send route polyline.
- Send `CMD_ERROR_STATE` category 6 with text indicating instruction data is
  unavailable.
- Watch may display route-only navigation.

## Destination Arrival

The watch owns MVP destination-arrival detection from fresh GPS and the active
overview route. No provider callback or new AppMessage command is required.

Arrival rules:

- The watch projects fresh GPS onto the active route and suppresses arrival while
  the projection is stale or off-route.
- The watch treats the trip as arrived when projected remaining route distance
  or direct destination distance is within 20 meters, using a conservative
  route-pixel fallback when meter scaling cannot be derived from nav-step
  distances.
- The watch fires one destination-arrival vibration.
- The watch finishes the trip locally by clearing route geometry, route-detail
  windows, nav steps, progress, and haptic suppression state.
- The watch sends or queues `CMD_ROUTE_CLEAR` so the phone clears
  `active_route`, `active_route_origin`, `active_route_target`, step cache, and
  route diagnostics state.
- The watch shows an `Arrived` dialog with `You arrived`; any hardware button
  dismisses it and returns to the map.

Phone handling of `CMD_ROUTE_CLEAR` is identical whether it came from an
explicit user clear action or watch-side arrival completion.

## Reroute

MVP reroute is user-triggered:

- Watch or phone UI requests reroute for the active route target.
- If the route origin policy is current location, phone repeats the route fetch
  from fresh GPS to the cached active target.
- If the route origin policy is explicit place, phone repeats the route fetch
  from the cached explicit origin to the cached active target.
- On success, phone replaces route and first nav-step chunk.
- On no-route, phone clears route with zero-point payload and sends category 7.

Automatic off-route detection and companion Google Maps notification rerouting
are not MVP.

## Caching

Phone keeps only local route cache:

```text
active_route
active_route_origin
active_route_target
active_destination_slot when target came from saved location
raw provider route summary needed for diagnostics
full normalized step list
last route request timestamp
last route error
```

No route data is uploaded to a project-hosted server.

## Acceptance Criteria

- Missing key produces category 1 without a network request.
- Invalid/disabled key, quota, billing, or permission-denied response produces
  category 2.
- Android-restricted key validation passes with the current package/cert headers
  and fails with intentionally wrong package/cert headers before direct routing
  is considered supported.
- Navigate Now search can resolve an autocomplete prediction and start routing
  without saving a saved-location record.
- Navigate Now can use current location as the default origin or a resolved
  explicit origin selected with Google Places Autocomplete/Place Details.
- Missing saved-location ID produces category 8.
- No-route provider result clears phone route cache, sends `[0, 0, 16]` as
  `CMD_ROUTE_POINTS`, sends no nav steps, then sends category 7.
- Successful provider result produces 2..128 route points with endpoints
  preserved.
- One-point provider/simplification output maps to category 6 without clearing a
  prior valid route.
- First nav-step chunk contains at most three records and byte-safe
  instructions.
- Watch request for next nav-step chunk is answered from local cache.
- Watch-side arrival within 20 m of the destination finishes the route, vibrates
  once, sends or queues `CMD_ROUTE_CLEAR`, and shows a dismissible arrival
  dialog without requiring a new protocol field.
- Routes with more than 255 provider steps are deterministically coalesced or
  truncated before packing.
- Walk and bike route displays include the provider warning on phone and watch.
- User-triggered reroute replaces the active route or reports a recoverable
  error without crashing.
