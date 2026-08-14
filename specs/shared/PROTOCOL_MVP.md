# Shared Protocol MVP Spec

This spec defines the MVP AppMessage contract between the Pebble watch app and
the phone-side worker. For MVP, the phone-side worker is the Android native
integration inside the Flutter companion app. The bundled PebbleKit JS entrypoint
is a comment-only no-op and must not independently respond to watch messages.

Mappy has no project-hosted application backend. The protocol assumes the phone
already owns location, navigation search, optional saved-location configuration,
Google API key access, map tile generation, route fetching, route
simplification, and diagnostics storage.

## Protocol Goals

- Keep the watch protocol small enough for Pebble AppMessage.
- Use compact, bounded data shapes and an owned, grouped command/key namespace.
- Use clear domain names while keeping each AppMessage dictionary compact.
- Make every network-dependent failure explicit to the watch.
- Avoid commands for non-MVP features such as Timeline pins, voice dictation,
  and companion notification mode.

## Protocol Peer Ownership

The Android companion is the single watch-facing AppMessage peer for MVP:

- It owns the AppMessage send queue and inbound command dispatcher.
- It reads the locally stored Google API key at runtime.
- It performs all Google Map Tiles, Places, Geocoding, and Routes API calls
  directly from the phone.
- It generates map tiles, routes, destinations, nav steps, settings updates, and
  diagnostic exports.
- It redacts credentials before logging.

PKJS must not contain an API key, perform Google network calls, or keep a second
copy of runtime state. Any future PKJS ownership change requires a spec update
that defines the local no-server bridge between Flutter and PKJS.

## AppMessage Keys

The Mappy Pebble project must define these message keys. Numeric IDs are grouped
by domain so additions remain predictable and reviewable.

| Key | ID | Direction | MVP use |
| --- | ---: | --- | --- |
| `cmd` | 50 | both | Command ID. Required on every message. |
| `width` | 51 | phone -> watch | Active rendered tile width in pixels for `CMD_TILE` and `CMD_MAP_SETTINGS`. |
| `height` | 52 | phone -> watch | Active rendered tile height in pixels for `CMD_TILE` and `CMD_MAP_SETTINGS`. |
| `bytes_per_row` | 53 | reserved | Reserved for future negotiated bitmap formats. |
| `is_color` | 54 | both | Overloaded command-specific scalar: theme/display context for tile/button paths or travel mode for route request/route response paths. |
| `compression_format` | 55 | reserved | Reserved; MVP tile format is implied by command. |
| `total_bytes` | 56 | both | Byte count or small scalar by command. |
| `chunk_index` | 57 | both | Chunk index or requested step index by command. |
| `chunk_offset` | 58 | both | Offset/distance scalar by command. |
| `chunk_data` | 59 | phone -> watch | Binary tile, destination, route, or nav-step payload. |
| `button_id` | 60 | both | Small command-specific integer. |
| `instruction` | 61 | both | Short UI/error text from phone, or optional diagnostic text from watch. |
| `destination` | 62 | phone -> watch | Destination/display text. |
| `world_x` | 63 | both | World-pixel x for map, route, and GPS messages. |
| `world_y` | 64 | both | World-pixel y for map, route, and GPS messages. |
| `tile_zoom` | 65 | both | Map zoom, route zoom, or startup theme sync by command. |
| `gps_sequence` | 66 | phone -> watch | Optional monotonic `CMD_GPS` ordering sequence. |
| `gps_elapsed_ms` | 67 | phone -> watch | Optional platform monotonic fix timestamp for diagnostics/reconciliation. |
| `gps_accuracy_cm` | 68 | phone -> watch | Optional horizontal accuracy in centimeters, or `-1` if unavailable. |
| `gps_provider` | 69 | phone -> watch | Optional short provider label, for example `gps` or `network`. |
| `request_id` | 70 | both | Positive request identity for tile and route delivery; responses must echo it. |
| `protocol_version` | 71 | both | Mandatory protocol version; current phone and watch require version 3. |

Phone and watch code use the same `world_x`, `world_y`, and `tile_zoom` names so
wire data and internal geometry remain unambiguous.

## Command IDs

MVP commands:

| ID | Name | Direction | MVP responsibility |
| ---: | --- | --- | --- |
| 101 | `CMD_INIT` | watch -> phone | Watch ready; sends persisted settings. |
| 102 | `CMD_ERROR_STATE` | phone -> watch | Recoverable error/status message. |
| 103 | `CMD_LOG_EVENT` | watch -> phone | Structured diagnostic event. |
| 104 | `CMD_PHONE_READY` | phone -> watch | Confirms protocol version 3 and completes the startup handshake. |
| 201 | `CMD_GPS` | phone -> watch | Current location as zoom-16 world pixels plus heading. |
| 202 | `CMD_TILE_REQUEST` | watch -> phone | Request one map tile crop using the current negotiated rendered tile size. |
| 203 | `CMD_TILE` | phone -> watch | Packed map tile crop with explicit width/height; may arrive in multiple chunks. |
| 204 | `CMD_MAP_SETTINGS` | phone -> watch | Phone-side map source, rendered tile size, or tile-generation settings changed; invalidate tile cache. |
| 205 | `CMD_MAP_ORIENTATION` | both | North-up or facing-up centered-map orientation preference. |
| 206 | `CMD_TILE_ANIMATION` | both | Watch tile load animation setting. |
| 207 | `CMD_BUTTON` | watch -> phone | Zoom/button event if not handled purely on watch. |
| 301 | `CMD_DESTINATIONS` | phone -> watch | Packed saved-location menu data. |
| 302 | `CMD_ROUTE_REQUEST` | watch -> phone | Request route to a saved-location ID or reroute the active target. |
| 303 | `CMD_ROUTE_POINTS` | phone -> watch | Packed route polyline. |
| 304 | `CMD_ROUTE_CLEAR` | both | Clear active route state. |
| 305 | `CMD_NAV_STEPS` | both | Phone sends nav-step chunks; watch requests next chunk. |
| 306 | `CMD_ROUTE_WINDOW_REQUEST` | watch -> phone | Request a high-detail route window around the current viewport. |
| 307 | `CMD_ROUTE_WINDOW_POINTS` | phone -> watch | Packed high-detail route window for the active route generation. |
| 308 | `CMD_ROUTE_APPLIED` | watch -> phone | Confirms route geometry and the first required navigation-step chunk were applied. |
| 309 | `CMD_ROUTE_COMPLETE` | watch -> phone | Reports arrival and clears the matching persisted route request. |
| 401 | `CMD_THEME` | both | Theme change or sync. |
| 402 | `CMD_TRAVEL_MODE` | both | Travel mode setting. |
| 403 | `CMD_UNITS` | phone -> watch | Display units. |
| 404 | `CMD_BACKLIGHT` | phone -> watch | Backlight setting, if supported. |
| 405 | `CMD_DECLINATION` | phone -> watch | Optional magnetic declination correction in centidegrees. |
| 406 | `CMD_HAPTIC_MODE` | both | Navigation haptic feedback preset. |
| 407 | `CMD_GLANCE_MODE` | both | Navigation backlight-glance feedback preset. |

Debug-only emulator/test commands:

| ID | Name | Direction | Debug responsibility |
| ---: | --- | --- | --- |
| 901 | `CMD_DEBUG_COMPASS` | tool/phone -> watch | Inject or clear a watch-side compass heading in emulator/debug builds. |
| 902 | `CMD_DEBUG_TILE` | tool/phone -> watch | Synthesize a decoded visible tile on the watch for emulator/debug builds. |
| 903 | `CMD_DEBUG_ROUTE_PROGRESS` | tool/phone -> watch | Move the watch GPS fix to a permille position on the active overview route for consumed-route overlay debugging. |

Debug commands are not production phone-worker features and must not be required
for normal routing.

Post-MVP features continue the grouped command ranges defined here.

## Lifecycle

Protocol version 3 is mandatory. `CMD_INIT` and `CMD_PHONE_READY` both carry
`protocol_version = 3`. A missing or different value is a terminal
synchronization error for that session: the phone records a diagnostic and the
watch displays an update-required state. There is no legacy fallback or payload
downgrade.

Startup:

1. Watch initializes AppMessage and sends `CMD_INIT` with protocol version 3.
2. `CMD_INIT` includes persisted settings:
   - `tile_zoom`: theme mode, `0` auto, `1` day, `2` night.
   - `button_id`: travel mode, `0` walk, `1` bike, `2` drive.
   - `total_bytes`: backlight mode, `0` auto, `1` always on.
   - `chunk_offset`: centered-map orientation, `0` north up, `1` facing up.
3. Phone sends `CMD_PHONE_READY` with protocol version 3. Only this reply
   completes watch initialization.
4. Phone worker verifies that MVP prerequisites are available:
   - phone location permission,
   - configured Google API key,
   - network reachability when route/tile requests arrive.
5. Phone sends settings, including the active rendered tile width/height via
  `CMD_MAP_SETTINGS`, and destinations, then starts GPS updates.
6. Watch requests visible map tiles after it has enough viewport state.

Reconnect:

- Watch may send `CMD_INIT` more than once.
- Phone must treat repeated init as idempotent.
- Phone should resend current settings, destinations, latest GPS, and active
  route summary after reconnect.
- Phone must not push stale theme/backlight values over watch-owned startup
  values unless the user changed them in the mobile UI after reconnect.
- Until matching phone-ready arrives, the watch retries INIT after 1, 2, 4, and
  8 seconds, then every 8 seconds while the app remains open. Message-begin and
  outbox failures use the same single pending retry timer.
- Repeated INIT is idempotent. Provider setup and active-route recovery remain
  single-flight.

## Transport Rules

- On the watch, reserve the 4096-byte AppMessage inbox and 512-byte outbox
  before allocating the opportunistic decoded-tile cache. If memory pressure
  prevents the full cache allocation, reduce cache capacity down to its
  specified minimum; never sacrifice AppMessage startup buffers. A failed
  `app_message_open` is a visible connection error and must not enter the INIT
  retry loop.
- Use one AppMessage send in flight per logical phone worker.
- GPS and control messages may be prioritized ahead of queued tile sends.
- The watch may have at most two logical tile responses awaiting completion.
  A successful `CMD_TILE_REQUEST` outbox callback only frees the watch outbox;
  it does not complete that logical response. Only the matching final tile
  chunk, terminal error, cancellation, or response timeout opens the response
  window for another request.
- AppMessage attempts time out after two seconds. Control, route, destination,
  navigation, and tile messages get three total attempts, delayed by 150 ms then
  400 ms. GPS gets two total attempts and supersedes older queued GPS. Logs get
  one attempt.
- Disconnecting requeues an in-flight message without consuming an attempt;
  sending resumes after successful version-2 synchronization.
- The phone queue is capped at 64 entries and evicts the oldest queued tile
  first under pressure.
- Binary payloads are little-endian.
- Text payloads are UTF-8 unless a command explicitly says ASCII-safe.
- Watch-side fixed buffers must always reserve space for a null terminator after
  copying variable text.

## Map And GPS Commands

### `CMD_GPS = 201`

Direction: phone -> watch.

Payload:

| Key | Meaning |
| --- | --- |
| `world_x` | zoom-16 world x |
| `world_y` | zoom-16 world y |
| `tile_zoom` | `16` |
| `button_id` | heading degrees rounded to integer, or sentinel `-1` for invalid |
| `gps_sequence` | optional monotonic GPS message sequence |
| `gps_elapsed_ms` | optional platform monotonic fix timestamp in milliseconds |
| `gps_accuracy_cm` | optional horizontal accuracy in centimeters, or `-1` |
| `gps_provider` | optional provider label capped by the phone bridge |

The phone may send GPS before all tiles are ready. The watch should update
viewport and marker state independently from map tile availability.

Ordering requirements:

- Phone must reject stale fixes, monotonic timestamp regressions, recent network
  fixes that would override a fresher GPS fix, implausible non-GPS jumps, and
  large accuracy regressions before enqueueing `CMD_GPS`.
- Phone should include `gps_sequence` on every `CMD_GPS` it sends.
- Watch must ignore a `CMD_GPS` with `gps_sequence` less than or equal to the
  last accepted GPS sequence. Messages without `gps_sequence` remain accepted
  so deterministic emulator injections can use a minimal payload.

### `CMD_BUTTON = 207`

Direction: watch -> phone.

Payload:

| Key | Meaning |
| --- | --- |
| `button_id` | `1` zoom in, `-1` zoom out, other values reserved |
| `is_color` | optional current theme mode |

MVP decision:

- The watch owns immediate zoom state changes so the UI responds without waiting
  for the phone.
- The phone uses this command as notification to cancel stale queued tile work
  for the prior zoom and expect fresh `CMD_TILE_REQUEST` messages.
- The phone must advance its internal tile-work generation and discard queued
  prior-generation tile transfers before acknowledging this command. Provider
  work already running may finish, but its result must fail the generation
  check before it enters the watch send queue. The watch therefore treats the
  `CMD_BUTTON` ACK as the cancellation barrier and does not send target-zoom
  tile requests before that ACK.
- If the watch handles a button purely as local menu navigation, it should not
  send `CMD_BUTTON`.
- Touch panning on `PBL_TOUCH` platforms is not represented by `CMD_BUTTON` or
  any new AppMessage command. The watch updates viewport state locally and sends
  ordinary `CMD_TILE_REQUEST` messages for missing crops.
- Pinch zoom on real touch hardware is also not represented by a new AppMessage
  command. The watch commits supported integer zoom changes locally, then sends
  the same `CMD_BUTTON` `button_id = 1` or `-1` notifications used by hardware
  button zoom.

### `CMD_TILE_REQUEST = 202`

Direction: watch -> phone.

Payload:

| Key | Meaning |
| --- | --- |
| `world_x` | requested crop top-left world x |
| `world_y` | requested crop top-left world y |
| `tile_zoom` | requested zoom |
| `is_color` | optional current theme/display mode |
| `request_id` | positive monotonic request identity |

The request geometry is the current `width` and `height` most recently supplied
by `CMD_MAP_SETTINGS`.

The phone responds with one `CMD_TILE` or a recoverable `CMD_ERROR_STATE` if map
tile generation cannot proceed because the API key, network, or provider is not
available.

### `CMD_TILE = 203`

Direction: phone -> watch.

Payload:

| Key | Meaning |
| --- | --- |
| `world_x` | crop top-left world x |
| `world_y` | crop top-left world y |
| `tile_zoom` | crop zoom |
| `width` | rendered tile width in pixels |
| `height` | rendered tile height in pixels |
| `total_bytes` | full packed tile byte length across all chunks |
| `chunk_index` | zero-based tile chunk index |
| `chunk_offset` | byte offset of `chunk_data` within the full packed tile |
| `chunk_data` | tile RLE payload bytes for this chunk |
| `request_id` | exact request identity echoed from `CMD_TILE_REQUEST` |

Tile format is specified in `MAP_TILE_PIPELINE_MVP.md`.

Watch assembly rules:

- A default `54x63` tile may arrive as a single message with `chunk_index = 0`
  and `chunk_offset = 0`.
- Larger rendered tiles may arrive as multiple `CMD_TILE` messages sharing the
  same world x/y/zoom/width/height.
- The watch must buffer chunks until `total_bytes` are assembled for that tile
  key, then decode exactly one complete RLE payload.
- The watch rejects chunks and errors whose request ID does not match the newest
  outstanding request for that coordinate.
- A tile error without a positive `request_id` is not a matching terminal
  response and must not retire or retry a newer flight.
- The phone enqueues all chunks for one logical response atomically. Chunks for
  different tile responses must not interleave; higher-priority non-tile
  messages may be delivered between chunks.
- A logical response is keyed by x/y/zoom, request ID, dimensions, and
  `total_bytes`. Its chunks use that key plus `chunk_index` and `chunk_offset`.
  A newer request ID supersedes the complete older queued response, never an
  individual sibling chunk.
- Chunk indices and offsets start at zero, remain contiguous, and cover exactly
  `total_bytes`. Queue overflow or terminal delivery failure removes all
  remaining chunks belonging to that logical response.

Oversized tile rule:

- The implementation must define the negotiated AppMessage inbox/outbox byte
  limit before tile code lands.
- Each individual `CMD_TILE` chunk must fit that limit.
- If a packed tile exceeds one-message capacity, the phone must split it into
  ordered chunks instead of partially truncating it.
- If a packed tile cannot be chunked within the implementation's bounded
  reassembly policy, the phone must send `CMD_ERROR_STATE` category 5 with the
  tile coordinates echoed.

## Destination Commands

### `CMD_DESTINATIONS = 301`

Direction: phone -> watch.

Payload: `chunk_data`.

MVP versioned binary format:

```text
1 byte   format_and_count
         bit 7 = 1 for the Mappy v1 destination format
         bits 6:0 = destination_count, max 127
repeat destination_count:
  1 byte   saved_location_id, 0..253; 254 and 255 are reserved
  1 byte   kind, 0 home, 1 work, 2 custom
  1 byte   travel_mode_default, 0 walk, 1 bike, 2 drive
  4 bytes  latitude * 1e7, int32 little-endian
  4 bytes  longitude * 1e7, int32 little-endian
  1 byte   label_length, max 30
  N bytes  UTF-8 label, no terminator
```

The phone keeps the full editable saved-location record, including address text
and place/provider metadata. The watch needs only display label, coordinates,
kind, saved-location ID, and default travel mode. Payload order is the watch
menu order; absent records are not rendered as empty slots. A zero-count payload
clears the watch-visible saved-location menu.

The high bit on the first byte is a required format discriminator. It leaves
room for future layouts and prevents an unversioned parser from silently
misreading records. MVP watch code rejects destination payloads where bit 7 is
not set.

### `CMD_ROUTE_REQUEST = 302`

Direction: watch -> phone.

Payload:

| Key | Meaning |
| --- | --- |
| `button_id` | saved-location ID 0..253, omitted for active-route reroute without a saved target |
| `is_color` | requested travel mode, 0 walk, 1 bike, 2 drive |
| `request_id` | positive stable route request identity when supplied by the watch |

Behavior:

- Phone maps the saved-location ID to its local saved-location config.
- If the ID is missing, disabled, reserved, or outside 0..253, phone sends
  `CMD_ERROR_STATE` category 8 and makes no geocode or route provider call.
- Phone geocodes only when local coordinates are missing or stale.
- Phone fetches a route directly from Google using the user's API key.
- Phone sends `CMD_ROUTE_POINTS` and `CMD_NAV_STEPS` on success.
- Phone sends `CMD_ERROR_STATE` on missing key, missing destination, API
  authorization/permission failure, provider failure, or network failure.
- If no route exists, phone sends `CMD_ROUTE_POINTS` with point count 0 to clear
  stale route display, then sends `CMD_ERROR_STATE` category 7 with visible text.
- Watch records the pending route travel mode from `CMD_ROUTE_REQUEST`.
- Phone includes the active route travel mode on `CMD_ROUTE_POINTS.is_color`
  (`0` walk, `1` bike, `2` drive). On a nonzero route response the watch uses
  that explicit mode when present; a watch-originated request can fall back to
  its pending route mode if the optional field is absent. Phone must cancel
  stale route/nav replies after a newer route request. Route and navigation
  responses carry both the stable request ID and a newly computed generation.
- If the active route mode is walk or bike, the watch route display must include
  the required provider warning for beta pedestrian/bicycling routes.
- If the active route mode is walk and the successful route response is
  fresh/user-visible, the watch consumes one route-start feedback event and
  moves the viewport to its maximum supported map zoom before requesting tiles
  for the walking route. Only an All feedback preset produces output for that
  event. Silent route refreshes and route-detail windows do not trigger it.

Phone-initiated Navigate Now search is not represented by a watch-originated
`CMD_ROUTE_REQUEST`, because no watch button event occurred. Flutter asks the
native bridge to start navigation from the selected origin policy to a resolved
ad-hoc route target, and the watch receives the same phone-originated route
outputs: `CMD_ROUTE_POINTS`, `CMD_NAV_STEPS`, `CMD_ERROR_STATE`, and
`CMD_ROUTE_CLEAR`. Because there is no prior watch-originated route request,
phone-initiated `CMD_ROUTE_POINTS` must include `is_color` with the selected
travel mode so the watch can render the correct route style and reroute using
the same mode. The origin may be current phone GPS or a phone-resolved specific
place; it is not represented by a new watch-originated command.

## Route Polyline Command

### `CMD_ROUTE_POINTS = 303`

Direction: phone -> watch.

Payload:

| Key | Meaning |
| --- | --- |
| `chunk_data` | packed route polyline |
| `button_id` | `1` fresh/user-visible route, `0` silent refresh |
| `total_bytes` | active route generation for matching route-detail windows |
| `is_color` | active route travel mode, `0` walk, `1` bike, `2` drive |
| `request_id` | stable route request identity |
| `chunk_index` | `1` when navigation steps are expected, otherwise `0` |

Binary format:

```text
2 bytes  point_count, uint16 little-endian, max 128
1 byte   header
          bits 6:0 route point zoom, normally 16
          bit 7 reserved for post-MVP, must be 0
repeat point_count:
  4 bytes  world_x int32 little-endian
  4 bytes  world_y int32 little-endian
```

`point_count = 0` means no route found and must clear any active route display
while preserving the map. The zero-route payload is exactly `[0, 0, 16]` for
MVP: uint16 little-endian count zero plus zoom-16 header. Phone should follow it
with `CMD_ERROR_STATE` category 7 so the watch has user-visible text. Successful
routes must contain 2..128 points; one-point routes are invalid provider output.

For successful walking routes, `button_id = 1` means this is a user-visible
walking route start and the watch performs the one-shot policy-controlled
feedback plus maximum-zoom start behavior. `button_id = 0` means a silent
refresh and must not produce feedback or force zoom.

For nonzero route payloads, `is_color` is the route mode that controls watch
route rendering and future active-route reroutes. It is required for
phone-initiated Navigate Now routes and active-route replays, and should be sent
on every successful route response. For a watch-originated request, an omitted
value uses the pending route mode captured from `CMD_ROUTE_REQUEST`.

`CMD_ROUTE_POINTS` is the whole-route overview. The phone may simplify and cap it
for watch memory, but it must remain usable at low zoom and across the whole
route. The phone also keeps the full decoded provider polyline and serves
high-detail windows via `CMD_ROUTE_WINDOW_REQUEST`/`CMD_ROUTE_WINDOW_POINTS`.
Point order is route direction from start to destination and is used by the
watch consumed-route overlay to hide only the portion at or behind the current
on-route GPS projection.

The watch sends `CMD_ROUTE_APPLIED` with the stable request ID only after route
geometry and, when expected, the first valid nav-step chunk have been applied.
Phone-originated navigation is not successful until this acknowledgement
arrives. Arrival sends `CMD_ROUTE_COMPLETE` with the same request ID; the phone
then clears the matching persisted request.

### `CMD_ROUTE_WINDOW_REQUEST = 306`

Direction: watch -> phone.

Payload:

| Key | Meaning |
| --- | --- |
| `world_x` | requested window center world x at zoom 16 |
| `world_y` | requested window center world y at zoom 16 |
| `tile_zoom` | current watch viewport zoom |
| `width` | requested window width in zoom-16 world pixels, including prefetch margin |
| `height` | requested window height in zoom-16 world pixels, including prefetch margin |
| `total_bytes` | active route generation from the latest `CMD_ROUTE_POINTS` |
| `request_id` | stable active route request identity |

Behavior:

- Watch sends this only while an overview route is active and the viewport zoom is
  high enough that overview simplification is visible.
- Watch requests a window wider/taller than the current screen so panning a few
  screenfuls can stay ahead of the user.
- Watch requests another window when the current viewport approaches or exits the
  loaded window bounds.
- Phone rejects stale generations by returning an empty `CMD_ROUTE_WINDOW_POINTS`
  for the requested generation or by letting the newer overview supersede it.

### `CMD_ROUTE_WINDOW_POINTS = 307`

Direction: phone -> watch.

Payload:

| Key | Meaning |
| --- | --- |
| `world_x` | returned window center world x at zoom 16 |
| `world_y` | returned window center world y at zoom 16 |
| `tile_zoom` | viewport zoom associated with the request |
| `width` | returned window width in zoom-16 world pixels |
| `height` | returned window height in zoom-16 world pixels |
| `total_bytes` | active route generation |
| `request_id` | stable active route request identity |
| `chunk_data` | packed route polyline using the same binary format as `CMD_ROUTE_POINTS` |

Behavior:

- Phone selects route segments intersecting the requested window from the full
  decoded provider polyline, includes adjacent endpoints for continuity, and caps
  the returned detail points to the watch route point budget.
- Watch accepts the payload only when `total_bytes` matches its current overview
  route generation.
- Watch draws detail points only when the returned window covers the current
  viewport; otherwise it falls back to the overview route.
  An empty detail payload marks the requested window as loaded but containing no
  visible route segment, preventing repeated identical requests.

## Navigation Step Command

### `CMD_NAV_STEPS = 305`

Phone -> watch payload includes `chunk_data`, `request_id` for the stable route
request, and `total_bytes` for the current route generation.

```text
1 byte   total_steps
1 byte   first_global_idx
1 byte   chunk_count, 1..3
repeat chunk_count:
  1 byte   step_global_idx
  4 bytes  start_world_x int32 little-endian
  4 bytes  start_world_y int32 little-endian
  2 bytes  remaining_m uint16 little-endian, capped at 65535
  2 bytes  remaining_s uint16 little-endian, capped at 65535
  1 byte   instruction_length, max 47 bytes for MVP watch buffer safety
  N bytes  UTF-8 instruction, no terminator
```

MVP route step cache is capped at 255 records because `total_steps`,
`first_global_idx`, and `step_global_idx` are one-byte fields.

Watch -> phone payload:

| Key | Meaning |
| --- | --- |
| `button_id` | requested first global step index |
| `request_id` | stable active route request identity |

The phone must be able to resend a requested chunk from local route-step cache
without making another network call.

## Settings Commands

| Command | Direction | Payload |
| --- | --- | --- |
| `CMD_THEME` | both | `button_id`: `0` auto, `1` day, `2` night |
| `CMD_TRAVEL_MODE` | both | `button_id`: `0` walk, `1` bike, `2` drive |
| `CMD_UNITS` | phone -> watch | `button_id`: `0` imperial, `1` metric |
| `CMD_MAP_SETTINGS` | phone -> watch | `button_id`: invalidation reason, `width`/`height`: active rendered tile size, `total_bytes`: map settings generation |
| `CMD_BACKLIGHT` | phone -> watch | `button_id`: `0` auto, `1` always on |
| `CMD_DECLINATION` | phone -> watch | `button_id`: signed magnetic declination correction in centidegrees, `-36000..36000` |
| `CMD_MAP_ORIENTATION` | both | `button_id`: `0` north up, `1` facing up |
| `CMD_TILE_ANIMATION` | both | `button_id`: `0` no animation, `1` fade in, `2` fade + zoom |
| `CMD_HAPTIC_MODE` | both | `button_id`: `0` off, `1` turns, `2` arrival, `3` all |
| `CMD_GLANCE_MODE` | both | `button_id`: `0` off, `1` turns, `2` arrival, `3` all |

The watch may persist theme, travel mode, backlight, centered map orientation,
tile animation, haptic mode, and glance mode for fast startup. The phone
persists the user-visible settings and reconciles them after `CMD_INIT`. If the
watch changes
`CMD_TRAVEL_MODE` while an active route is displayed and the selected mode
differs from the active route mode, the watch queues a `CMD_ROUTE_REQUEST`
active-route reroute using the new mode.

### `CMD_MAP_SETTINGS = 204`

Direction: phone -> watch.

This command is a cache-invalidation notice and rendered-tile-geometry sync for
phone-owned map tile settings such as map type and watch tile width/height. The
watch must not persist or display provider details from this command. On receipt
it must:

1. Update active `width` and `height` when present.
2. Clear valid and pending tile cache entries.
3. Keep GPS, viewport, route, destination, and UI state unchanged.
4. Queue the currently visible tile grid using ordinary `CMD_TILE_REQUEST`
   messages.

Payload:

| Key | Meaning |
| --- | --- |
| `button_id` | `0` unknown/all, `1` map source changed, `2` tile geometry/quality/compression changed |
| `width` | active rendered tile width in pixels |
| `height` | active rendered tile height in pixels |
| `total_bytes` | monotonically increasing phone-local map settings generation, optional |

The phone sends this command after a Flutter/user setting change has been
persisted and after stale tile work has been cancelled or marked obsolete. The
next `CMD_TILE_REQUEST` messages still carry only world x/y/zoom/theme context;
the active rendered tile geometry is whatever `width`/`height` pair this
command most recently supplied.

### `CMD_MAP_ORIENTATION = 205`

Direction: phone -> watch required; watch -> phone optional if a watch-side
settings control is implemented.

This command syncs the display-only centered-map orientation preference. It is
specified in `MAP_ORIENTATION_SETTING_SPEC.md`. Facing-up applies to GPS-follow
mode; manual panning suspends heading-driven rotation until recenter.

Payload:

| Key | Meaning |
| --- | --- |
| `button_id` | `0` north up, `1` facing up |

### `CMD_TILE_ANIMATION = 206`

Direction: phone -> watch required; watch -> phone optional if a watch-side
settings control is implemented.

This command syncs the display-only watch tile load animation mode. It is
specified in `../watch/WATCH_TILE_LOAD_ANIMATION_SPEC.md`.

Payload:

| Key | Meaning |
| --- | --- |
| `button_id` | `0` no animation, `1` fade in, `2` fade + zoom |

Unsupported values normalize to `0` no animation. Changing this setting must not
clear tile caches, re-request visible tiles, or alter provider/source settings.

On receipt, the watch must:

1. Store the normalized animation value.
2. Complete active tile animations immediately if the normalized value is `0`.
3. Leave decoded tile cache, pending requests, route state, GPS state,
   destinations, nav-step state, provider sessions, and source/encoded tile
   caches unchanged.
4. Apply the new value only to future tile arrivals, except for the immediate
   completion behavior required when switching to `0`.

### `CMD_HAPTIC_MODE = 406` and `CMD_GLANCE_MODE = 407`

Direction: both.

Both commands use the same feedback preset encoding: `0` off, `1` turns,
`2` arrival, and `3` all. Missing or unsupported values normalize to `3` all.
`Turns` covers turn preview and turn-now events, `Arrival` covers only route
completion, and `All` additionally covers a fresh user-visible walking route
start. The haptic and glance modes are independent and changing either affects
future one-shot events only; it must not reset alert indexes or replay an event
whose threshold was already consumed.

The watch persists locally selected values and sends them to the phone. The
phone persists connected-watch updates, exposes both controls to the user, and
resends its durable values after startup reconciliation. `CMD_GLANCE_MODE`
requests a normal transient interaction backlight wake, not an always-on light
or a wrist-motion subscription.

## Error Command

### `CMD_ERROR_STATE = 102`

Direction: phone -> watch.

Payload:

| Key | Meaning |
| --- | --- |
| `button_id` | error category |
| `chunk_index` | failed command ID, or 0 if global |
| `chunk_offset` | failed saved-location ID when present, route step index, or 0 if unused/ad-hoc |
| `world_x` | failed tile world x when tile-related |
| `world_y` | failed tile world y when tile-related |
| `tile_zoom` | failed tile zoom when tile-related |
| `instruction` | short display text, max 47 UTF-8 bytes after truncation |

Error categories:

| ID | Meaning |
| ---: | --- |
| 1 | Missing Google API key |
| 2 | Invalid Google API key, API disabled, quota, billing, or provider permission denied |
| 3 | Location unavailable: permission denied, no fix, or stale origin |
| 4 | Network unavailable |
| 5 | Tile provider failure |
| 6 | Non-auth route/geocoding provider failure |
| 7 | No route found |
| 8 | Destination not configured |

The watch should show errors without clearing a valid prior map unless the error
is route-specific and the active route is now invalid.

Ad-hoc Navigate Now route targets do not add a watch-visible route target ID to
`CMD_ERROR_STATE`. The phone may record a phone-local `route_target_id` in
diagnostics, while watch payload correlation uses `chunk_offset = 0` unless a
saved-location ID is involved.

## Diagnostic Command

### `CMD_LOG_EVENT = 103`

Direction: watch -> phone.

MVP payload:

| Key | Meaning |
| --- | --- |
| `button_id` | event category |
| `chunk_offset` | optional numeric detail |
| `chunk_index` | optional second numeric detail |
| `instruction` | optional short text detail |

Informational motion diagnostics keep `button_id = 0`. `chunk_offset` values 8,
9, and 10 mean walking detected, watch look detected, and bearing reacquisition
started respectively. For reacquisition, `chunk_index` is `1` for route start
or `2` for watch look. These are semantic events only; raw accelerometer data
must never be placed in AppMessage payloads.

The phone stores logs locally in a bounded ring buffer. Logs must not be sent to
any external server by MVP code.

## Text Encoding Rules

- All text limits are byte limits after UTF-8 encoding.
- Phone truncates only on Unicode code point boundaries.
- Watch validates length before fixed-buffer copy.
- Watch should replace malformed UTF-8 with `?` or reject the field rather than
  writing malformed bytes past a terminator.

## Acceptance Criteria

- `tooling/test-protocol-consistency.py` verifies message keys, commands, and
  watch UUID across every protocol peer and emulator script.
- Watch and phone command constants include `CMD_MAP_SETTINGS = 204`,
  `CMD_MAP_ORIENTATION = 205`, `CMD_TILE_ANIMATION = 206`, and
  `CMD_DECLINATION = 405`, `CMD_HAPTIC_MODE = 406`, and
  `CMD_GLANCE_MODE = 407`.
- A unit test round-trips each binary payload type.
- A protocol replay test can feed `CMD_TILE_REQUEST`, `CMD_ROUTE_REQUEST`,
  `CMD_NAV_STEPS`, `CMD_MAP_SETTINGS`, `CMD_MAP_ORIENTATION`,
  `CMD_TILE_ANIMATION`, `CMD_HAPTIC_MODE`, and `CMD_GLANCE_MODE` messages into
  the phone/watch harness without a physical watch.
- A watch-side decode test rejects oversized destination, route, and nav-step
  payloads without writing past fixed buffers.
- A missing Google API key produces `CMD_ERROR_STATE` rather than a silent
  route/tile failure.
- A no-route provider response sends a zero-point `CMD_ROUTE_POINTS` followed by
  `CMD_ERROR_STATE` category 7.
