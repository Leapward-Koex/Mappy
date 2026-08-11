# Watch App MVP Spec

This spec defines the Pebble Time 2 watch app behavior for the backend-free
Mappy MVP. The watch app is a native C Pebble app targeting
`emery`. It is the display and input surface; the Android phone companion owns
Google API access, map generation, GPS, routing, primary phone-side navigation
search, optional saved-location storage, and diagnostics persistence.

## MVP Responsibilities

The watch app must:

- Start quickly and show a setup/error state if the phone is not ready.
- Send `CMD_INIT` with watch-persisted settings.
- Receive GPS world-pixel updates, keep GPS-follow mode centered on the user,
  and keep marker/navigation state fresh while manually panned.
- Request visible map tile crops.
- On touch-capable builds, support watch-local map panning without adding a
  phone-side touch command.
- On real touch hardware that exposes reliable multi-touch or pinch-distance
  data, support pinch-to-zoom-in and pinch-to-zoom-out as defined by
  `WATCH_TOUCH_INPUT_SPEC.md`.
- Decode and cache map tile payloads.
- Draw the map, route line, current-location puck/view cone, and
  compact navigation/status UI.
- Apply the selected centered-map orientation: north-up by default, or
  face-forward while GPS-follow is active as defined by
  `../shared/MAP_ORIENTATION_SETTING_SPEC.md`.
- Let the user select an optional saved location as a watch quick-route
  shortcut.
- Let the user request a reroute for the active destination.
- Persist small watch-owned settings needed for startup.
- Emit bounded diagnostic events to the phone.

The watch app must not:

- Store or display the Google API key.
- Call external network services.
- Depend on a project-hosted application backend.
- Accept commands or implement features outside the published Mappy MVP
  protocol.

## Target Geometry

Target platform:

- Pebble Time 2 / `emery`.
- RePebble SDK 4.9+ touch builds may expose `PBL_TOUCH` on `emery` and
  `gabbro`; all touch-service code must compile out when `PBL_TOUCH` is absent.
- Compile-time code must query or use SDK constants for screen bounds.
- Do not hard-code a 144x168 screen size except in platform-geometry tests.

MVP map tile geometry:

| Item | Value |
| --- | ---: |
| Tile crop width | 54 px |
| Tile crop height | 63 px |
| Decoded bytes per tile | 1,701 |
| Visible grid target | 5 x 5 |
| Visible cache entries | 25 |
| Tile request queue | 25 entries, or refill scheduler with equivalent coverage |
| Compressed tile arena | 32,768 bytes |
| Shared decode scratch | 6,804 bytes |

The implementation must confirm heap usage on target hardware before shipping.
If 5x5 is not viable, the spec must be revised with measured memory and a
different measured coverage strategy, such as dynamically positioned crop
origins; do not fall back to a smaller fixed grid without proving full-screen
coverage.

The 5x5 cache target is the north-up baseline. Direction-up GPS-follow
orientation can require expanded rotated-footprint coverage as defined by
`../shared/MAP_ORIENTATION_SETTING_SPEC.md`; that mode must be heap-tested with
the larger coverage or implemented with an equivalent refill/streaming strategy
before it is enabled. Manual-browse mode uses north-up coverage.

Heap acceptance must include the compressed arena, shared scratch, cache
metadata, a 4,096-byte
AppMessage inbox, outbound queue storage, route buffers for 128 points, nav-step
buffers, saved-location records, layers, fonts, and menu/UI allocations.

## App State Model

Watch top-level states:

| State | Meaning |
| --- | --- |
| `BOOTING` | Native init is running; AppMessage not ready. |
| `WAITING_FOR_PHONE` | Watch sent `CMD_INIT`; no usable phone state yet. |
| `SETUP_REQUIRED` | Phone reports missing key, missing permission, or invalid setup. |
| `MAP_LOADING` | GPS exists; visible tile grid is not filled enough yet. |
| `MAP_READY` | Map can render with current/stale tiles. |
| `ROUTE_LOADING` | User requested route; waiting for route/steps/error. |
| `NAVIGATING` | Active route and at least one nav step exist. |
| `ROUTE_ERROR` | Route request failed but map remains usable. |

State transitions must be recoverable. A phone reconnect or new GPS/tile/route
message may move the watch out of setup/loading/error states without requiring a
watch app restart.

Destination arrival is a modal UI condition rather than a durable top-level
state. When local route projection determines the wearer is at or very close to
the destination, the watch finishes the trip, clears active route state, and
shows an arrival dialog over the map until any hardware button is pressed.

## Startup

On init:

1. Initialize windows/layers.
2. Initialize AppMessage with inbox size at least 4,096 bytes.
3. Load persisted settings:
   - theme mode,
   - travel mode,
   - backlight mode,
   - centered map orientation,
   - tile animation if stored watch-side,
   - units if stored watch-side,
   - last zoom if implemented.
4. Send `CMD_INIT`:

```text
cmd         = CMD_INIT (101)
tile_zoom   = theme mode
button_id   = travel mode
total_bytes = backlight mode
chunk_offset = centered map orientation
```

5. Enter `WAITING_FOR_PHONE`.

Repeated startup syncs are allowed. The watch must handle duplicate settings,
saved-location lists, and GPS updates idempotently.

The watch persists the selected travel mode and records the pending mode when it
sends `CMD_ROUTE_REQUEST`. A later nonzero `CMD_ROUTE_POINTS` response activates
the explicit response mode from `is_color` when present. If the optional field
is absent, the watch uses the mode stored with its outstanding request. The
phone is responsible for dropping stale responses after a newer route request.

## AppMessage Receiver

The watch must handle these MVP inbound commands:

| Command | Required behavior |
| --- | --- |
| `CMD_GPS` | Update current world x/y, heading, recenter viewport, queue visible tiles. |
| `CMD_TILE` | Decode tile, update/replace cache entry, schedule map redraw. |
| `CMD_DESTINATIONS` | Replace saved-location menu model. |
| `CMD_ROUTE_POINTS` | Replace active route polyline or clear route on zero points. |
| `CMD_NAV_STEPS` | Store nav-step chunk and update current instruction cache. |
| `CMD_ROUTE_CLEAR` | Clear route, steps, route status, and route error. |
| `CMD_THEME` | Store theme, clear/re-request visible tile cache. |
| `CMD_TRAVEL_MODE` | Store selected/default travel mode. |
| `CMD_UNITS` | Store display units. |
| `CMD_MAP_SETTINGS` | Clear/re-request visible tile cache after phone-side map source or rendered tile size changes. |
| `CMD_BACKLIGHT` | Store/apply backlight setting if SDK support permits. |
| `CMD_MAP_ORIENTATION` | Store centered map orientation; if GPS-follow is active, recalculate visible tile coverage, queue missing tiles, and redraw. If manual browse is active, defer facing-up projection until recenter. |
| `CMD_TILE_ANIMATION` | Store tile animation mode; apply it to future tile arrivals without invalidating map tiles. |
| `CMD_ERROR_STATE` | Show recoverable setup/tile/route/location error. |

Inbound handlers must validate tuple presence, length, ranges, and binary payload
size before copying into fixed buffers.

Any command not listed in the Mappy MVP receiver table must be dropped after a
bounded diagnostic log. The watch must never forward, persist, or display data
from an unrecognized command, including arbitrary `instruction` text.

## AppMessage Sender

The watch sends:

| Command | Trigger |
| --- | --- |
| `CMD_INIT` | Startup/reconnect. |
| `CMD_TILE_REQUEST` | Visible tile missing from cache/queue. |
| `CMD_BUTTON` | Zoom changed on the watch; `button_id` is `1` or `-1`. |
| `CMD_ROUTE_REQUEST` | User selects saved-location shortcut or reroute. |
| `CMD_NAV_STEPS` | Watch needs next nav-step chunk. |
| `CMD_ROUTE_CLEAR` | User exits active navigation, or the watch finishes a trip after local destination arrival. |
| `CMD_THEME` | User changes theme on watch, if watch UI exposes it. |
| `CMD_TRAVEL_MODE` | User changes travel mode on watch. If an active route uses a different mode, queue an active-route reroute using the new mode. |
| `CMD_MAP_ORIENTATION` | User changes centered map orientation on watch, if watch UI exposes it. |
| `CMD_TILE_ANIMATION` | User changes tile animation on watch, if watch UI exposes it. |
| `CMD_LOG_EVENT` | Diagnostic event. |

Outbound tile requests must be deduplicated against valid cache entries and the
pending request queue. The watch may serialize requests to avoid AppMessage
backpressure.

Zoom changes are applied locally first, then reported with `CMD_BUTTON` so the
phone can cancel stale tile work for the prior zoom. Menu-only button actions
remain local and do not send `CMD_BUTTON`.

When a nonzero `CMD_ROUTE_POINTS` payload starts a fresh/user-visible walking
route, the watch must give exactly one short vibration and immediately move the
viewport to the maximum supported map zoom before requesting fresh tiles.
This is a route-start behavior only: silent route refreshes, route detail window
updates, bike routes, and drive routes must not trigger the haptic or automatic
zoom jump. The zoom jump follows the normal local zoom path, including cache
invalidation, persisted zoom, a `CMD_BUTTON` zoom notification, and fresh tile
requests at the new zoom.

## Map Tile Cache

Each cache entry stores:

```text
world_x int32
world_y int32
zoom int8
valid bool
pending bool
last_used counter
storage_offset uint16
stored_length uint16
storage_format enum(indexed_rle, packed)
encoded_length uint16
storage_suppressed bool
```

All entry payloads live in a compact fixed 32 KiB arena. Indexed RLE retains
the wire bytes and adds a three-byte checkpoint every 32 source pixels. If that
representation is not smaller than the decoded 4-bit pixels, the entry stores
packed nibbles instead. One 6,804-byte scratch allocation is shared by incoming
high-entropy streaming and one-at-a-time north-up tile decode.

Cache eviction:

1. Prefer exact x/y/zoom match.
2. Else use an invalid entry.
3. Else replace the least-recently-used entry outside the current visible grid.
4. Else replace the oldest visible entry only if memory pressure requires it.

Removing an arena segment compacts later segments and updates their offsets.
An entry evicted only to satisfy the byte budget is not requested again until
it leaves the viewport. This keeps pathological imagery stable instead of
cycling continuously between request and eviction.

Theme, zoom, or `CMD_MAP_SETTINGS` changes invalidate encoded-color cache
entries because phone palette selection or source tile generation changes the
tile bytes. The watch should clear visible tile valid bits and re-request.

For a 5x5 visible grid, the default request queue is 25 entries. If an
implementation uses a smaller queue, it must rescan/refill after each send,
timeout, or NACK until every visible tile has either a valid cache entry or a
queued/in-flight request.

## Binary Payload Validation

`CMD_TILE` validation:

- Required tuples: x, y, zoom, `chunk_data`, and `total_bytes`.
- `total_bytes` is the complete RLE byte count; chunk offsets and indexes must
  form an exact contiguous stream.
- The complete RLE byte count must be 1..13,608 for supported geometry.
- RLE decode must produce exactly `watch_tile_width * watch_tile_height` pixels
  before marking a cache entry valid.
- Extra encoded pixels or payload exhaustion before the configured pixel count
  rejects the tile.

`CMD_DESTINATIONS` validation:

- First byte must have bit 7 set as the Mappy destination-format marker.
- Count is low seven bits and must be 0..127.
- Each record must fit completely within payload bounds.
- Saved-location ID must be 0..253; 254 and 255 are reserved for non-saved
  route sentinels.
- Duplicate ID policy: later valid record replaces earlier record and logs a
  diagnostic.
- Label length must be 0..30 UTF-8 bytes.
- Malformed UTF-8 is replaced with `?` or rejects that record before fixed-buffer
  copy.
- Records not present in the incoming complete payload are cleared from the
  watch menu.

`CMD_ROUTE_POINTS` validation:

- Payload length must equal `3 + point_count * 8`.
- `point_count` must be 0..128.
- Header bit 7 must be 0 in MVP.
- Header low seven bits must be a supported route zoom, initially 16.
- Zero points clears route and step state.

`CMD_NAV_STEPS` validation:

- Header must include total step count, first global index, and chunk count.
- Chunk count must be 1..3.
- Every record must fit within payload bounds.
- Instruction length must be 0..47 UTF-8 bytes before copy.

## Drawing Order

Render order:

1. Background fill.
2. Decoded map tiles.
3. Route polyline.
4. Current-location view cone if heading is valid.
5. Current-location puck.
6. Destination/route marker if available.
7. Top navigation/status banner.
8. Bottom distance/destination/settings bar.
9. Modal/menu overlays.

Map tile rendering:

- North-up rendering decodes one cached tile at a time into the shared scratch
  buffer and reuses the clipped row-copy path.
- Facing-up rendering samples packed entries directly and uses 32-pixel RLE
  checkpoints so compressed lookup work is bounded.
- Read packed nibbles as palette indexes.
- Even source pixel index uses low nibble.
- Odd source pixel index uses high nibble.
- Map through active day/night palette to GColor8.
- Clip all writes to the layer bounds.
- Use nearest-neighbor sampling during zoom transitions.
- In facing-up GPS-follow mode, sample compressed tile pixels through
  the same rotation transform used by route and marker overlays.

Route rendering:

- Route points are zoom-16 world pixels.
- Convert route points to current screen coordinates using viewport center and
  active zoom/scale and the active centered-map orientation.
- Drive and bike routes draw clipped line segments over the map.
- Walking routes draw the same route geometry as spaced blue dots with a white
  halo instead of a continuous line, including high-detail route windows.
- A zero-point route payload clears route drawing and step state.
- Fresh/user-visible walking route start gives one short vibration and starts at
  the maximum supported map zoom.

Current location:

- Draw the current-location puck centered at the latest GPS world position.
- Smooth plausible short GPS movement as defined by
  `../shared/MAP_ORIENTATION_SETTING_SPEC.md`: face-forward GPS-follow animates
  the map under a centered puck, while north-up animates the puck/cone display
  point toward the latest fix.
- GPS smoothing is skipped for the first fix, stale sequence numbers, movement
  beyond the adaptive travel-mode threshold, and camera-changing interactions
  such as manual pan, recenter, zoom, or orientation changes.
- Use `CURRENT_LOCATION_VIEW_CONE_SPEC.md` for puck and cone geometry, colors,
  layering, heading source, and visual tests.
- If heading is valid, draw the outlined 90-degree blue view cone.
- If heading is invalid/unavailable, draw a neutral blue puck with no stale
  heading cone.
- The current-location cone represents the wearer-facing watch compass heading.
  In facing-up GPS-follow mode, the same compass heading drives the active map
  rotation and is compensated out of the cone direction. If the compass heading
  is unavailable, hide the cone and fall map projection back to north-up on
  compass-capable watch builds. In manual-browse mode, map rotation is suspended
  and the browsed map is north-up.

Centered map orientation:

- `north_up` keeps true north at the top of the watch screen.
- `forward_up` rotates geographic content around the viewport center so the
  wearer-facing compass bearing points toward the top of the screen only while
  GPS-follow is active.
- Manual panning exits GPS-follow, suspends facing-up rotation, and renders the
  browsed viewport north-up until recenter.
- Facing bearing source, fallback behavior, tile coverage, touch panning, and
  recenter rules are defined by `../shared/MAP_ORIENTATION_SETTING_SPEC.md`.
- Facing-up must request enough 54x63 crops to cover the inverse-rotated
  screen footprint while active. It must not leave blank rotated corners after
  all requested tiles arrive.
- Face-forward route start uses a bounded fast bearing animation for all travel
  modes. Active walking routes additionally use the accelerometer-only
  walking-to-watch detector and lifecycle defined by
  `../shared/MAP_ORIENTATION_SETTING_SPEC.md`.
- Motion detection is allocation-free, ignores samples collected during watch
  vibration, runs only while the face-forward walking map is visible, and does
  not send raw motion samples to the phone.

## Input Behavior

MVP buttons:

| Input | Map view behavior | Navigation behavior |
| --- | --- | --- |
| Up | Zoom in or move selection in menus. | Zoom in or move selection in menus. |
| Select | Open destination/menu or confirm selection. | Open nav actions menu. |
| Down | Zoom out or move selection in menus. | Zoom out or move selection in menus. |
| Back | Exit menu; if navigating, prompt/clear route. | Exit menu or clear route. |

When the arrival dialog is visible, any hardware button press dismisses the
dialog and returns to the normal map without also performing its usual button
action.

Touch input on `PBL_TOUCH` platforms:

- Wrap all touch-service references in `#ifdef PBL_TOUCH`; the app must still
  build for platforms that do not expose the touch API.
- Subscribe to touch events only while the map or navigation surface is active
  and no modal/menu owns input. Unsubscribe when leaving those surfaces and
  during app teardown. Touch events can trigger backlight activity, so do not
  keep the service enabled unnecessarily.
- Treat `touch_service_is_enabled() == false` as no-touch mode and fall back to
  GPS-follow plus hardware buttons.
- `TouchEvent_Touchdown` records the event `x/y` and current viewport center.
- `TouchEvent_PositionUpdate` updates the viewport center from the drag delta
  using the current zoom scale. The first accepted pan exits GPS-follow,
  suspends facing-up rotation, and uses north-up manual-browse mapping.
  Dragging the map right/down should move map content right/down, which means
  the viewport center moves left/up in world pixel space.
- `TouchEvent_Liftoff` finalizes the panned viewport and queues missing visible
  tile crops using normal `CMD_TILE_REQUEST` messages.
- Touch panning must not send a new touch-specific phone command. It may only
  produce normal tile requests and bounded diagnostics.
- Pinch zoom must not send a new touch-specific phone command. It uses the same
  local zoom path as hardware-button zoom and reports committed level changes
  with `CMD_BUTTON` `button_id` values of `1` or `-1`.
- Smooth pinch rendering is preferred: while a pinch is active, the watch should
  render already decoded map tiles with transient nearest-neighbor scaling and
  keep route/marker projections aligned. If the real watch SDK or hardware does
  not expose stable enough pinch/scale data, discrete level-change pinch zoom is
  acceptable. If no reliable multi-touch or pinch data exists, hardware-button
  zoom remains the required fallback.
- Fresh GPS updates continue to move the current-location marker and navigation
  progress, but must not immediately recenter the viewport while an active pan
  gesture or manual-pan state is in effect.
- The watch must expose a compact recenter action, such as a menu item, to clear
  manual-pan state, return the viewport center to current GPS, and reapply the
  selected centered-map orientation.
- Route overlays, destination markers, and heading/current-location markers must
  be projected from the same viewport state as map tiles while panned.

MVP menus:

- Saved-location list: variable-length optional shortcuts from the latest
  `CMD_DESTINATIONS` payload. Primary ad-hoc
  destination search happens in the phone app, not on the watch.
- Active route actions: reroute, clear route, change travel mode.
- Settings summary: theme, units, backlight, centered map orientation, tile
  animation, diagnostics status. Full editing remains in the phone app.

The watch menu renders only configured saved locations. If the incoming list
is empty, the menu shows a local "No destinations" row and does not send a route
request. If a stale or unknown saved-location ID is sent, the phone returns
`CMD_ERROR_STATE` category 8. An empty destination list is represented by a
zero-count `CMD_DESTINATIONS` payload; no separate empty-slot command is needed.

If the active route mode is walk or bike, the watch must display a compact
provider warning in navigation/map route UI indicating that pedestrian or bike
path detail may be incomplete. This warning is route status, not an error state,
and must not block route drawing.

Changing travel mode while an active route is displayed updates the selected
mode immediately and queues a reroute of the active target. The next
`CMD_ROUTE_POINTS` response then updates the active route mode and rendering
style; for example, changing a drive route to walk must replace the continuous
line with walking-route dots after the reroute response arrives.

## Consumed Route Overlay

The watch must render the active route according to
`ROUTE_CONSUMED_OVERLAY_SPEC.md`:

- the route point order is the hidden forward direction,
- walking-route dots at or behind the current on-route GPS projection are hidden,
- bike/drive route line segments behind the current on-route GPS projection are
  hidden,
- the visual cutoff may move backward so retracing steps reveals route geometry,
- route storage is not mutated by this visual hiding.

## Navigation Steps

The watch stores up to three nav-step records from the latest chunk:

```text
global_idx
start_world_x
start_world_y
remaining_m
remaining_s
instruction[48 bytes including terminator]
```

MVP progression:

- Current step starts at the first record in the current chunk.
- Progression requires fresh GPS. If location is stale, hold the current step and
  enter degraded `LOCATION_STALE` behavior without clearing the map or route.
- Project the current GPS point onto the nearest segment of the route polyline.
- Maintain a monotonic route-progress scalar; never move progress backward.
- Advance when projected progress is at least 20 meters beyond the current
  step's start point and at least 10 meters closer to the next step than the
  prior fix. These thresholds may be tuned only with tests.
- If projected distance from the route exceeds 60 meters, hold the current step
  and emit a diagnostic instead of skipping ahead.
- Request the next chunk when the current local index reaches `chunk_count - 2`
  or when only one local record remains.
- If progression cannot be computed reliably, retain the current step and emit a
  diagnostic event rather than skipping instructions aggressively.

## Turn Haptic Alerts

The watch must implement `TURN_HAPTIC_ALERT_SPEC.md`:

- Use existing route projection plus `CMD_NAV_STEPS` starts and remaining meters.
- Fire one subtle preview vibration before each non-start, non-arrival maneuver.
- Fire one stronger vibration when the same maneuver is due.
- Suppress repeats for the same `global_idx`, including GPS jitter and walking
  backward over the threshold.
- Reset haptic alert state when the route is cleared or replaced.

## Destination Arrival

The watch must detect destination arrival with the same overview-route
projection used for nav-step progression:

- Use fresh GPS only.
- Suppress arrival while the projected GPS point is off-route.
- Treat arrival as reached when the projected remaining route distance or direct
  destination distance is within 20 meters, with a conservative route-pixel
  fallback if meter scaling is unavailable.
- Fire one distinct arrival vibration.
- Clear route geometry, route-detail windows, nav-step state, turn-alert state,
  route progress, and route loading/error status.
- Send or queue `CMD_ROUTE_CLEAR` so the phone clears the active route cache.
- Show a modal dialog saying `Arrived` and `You arrived`.
- Keep the map and current-location puck visible behind the dialog.
- Dismiss the dialog on any hardware button press.

## Error UI

The watch must display all phone-reported error categories:

| Category | UI behavior |
| ---: | --- |
| 1 | Setup required: missing Google API key. |
| 2 | Setup required: invalid key, API disabled, quota, billing, or provider permission issue. |
| 3 | Location unavailable: show location permission/fix status. |
| 4 | Network unavailable: keep stale map/route visible if present. |
| 5 | Tile provider failure: show compact map status with tile context if present. |
| 6 | Route provider failure: keep map usable and show route error text. |
| 7 | No route found: route should already be cleared by zero-point route payload. |
| 8 | Destination not configured: show saved-location menu hint. |

The watch also has a local `LOCATION_STALE` degraded condition when no fresh GPS
arrives within the implementation timeout. It suspends route progression and
heading updates while keeping the last valid map/route visible.

Map tile errors:

- Do not clear a previously valid map solely because one tile failed.
- Show a compact status indicator while leaving stale/blank tiles visible.

Route errors:

- Clear stale route if the phone sends zero-point `CMD_ROUTE_POINTS`.
- Show the `CMD_ERROR_STATE` instruction text.
- Keep map and saved-location menu usable.

Error text must be byte-limited and null-terminated after validation.

## Persistence

Watch persists:

- theme mode,
- travel mode,
- backlight mode,
- centered map orientation,
- tile animation if stored watch-side,
- units if needed for display before phone sync,
- last zoom if implemented.

Watch does not persist:

- Google API key,
- saved-location records beyond the current pushed menu cache unless implementation
  explicitly needs offline menu display,
- map tile images,
- route geometry,
- logs beyond short volatile diagnostics.

## Acceptance Criteria

- Watch boots with no phone and shows `WAITING_FOR_PHONE` without crashing.
- Watch boots with phone but missing API key and shows setup-required text.
- After GPS and a full tile grid arrive, map renders nonblank on `emery`.
- A golden `CMD_TILE` payload decodes to the expected nibble buffer.
- Destination payload with the Mappy format marker populates the menu.
- Selecting a destination sends `CMD_ROUTE_REQUEST` with slot and travel mode.
- A route payload draws a clipped route line over the map.
- Walk and bike route displays include the compact provider warning.
- A zero-point route payload clears route and step display.
- A nav-step chunk displays the first instruction and can request the next chunk.
- Moving GPS to the destination finishes the active trip, vibrates once, sends
  or queues `CMD_ROUTE_CLEAR`, and shows an arrival dialog that any hardware
  button dismisses.
- Invalid heading hides the current-location view cone and leaves a neutral
  blue puck.
- `CMD_MAP_ORIENTATION` switches the centered-map preference between north-up
  and facing-up without clearing route, GPS, destination, or nav-step state.
- Facing-up uses a valid facing bearing when available and falls back
  safely to north-up when heading is invalid or stale.
- Manual pan while facing-up is active suspends auto-rotation and keeps later
  heading changes from rotating the map until recenter.
- Plausible short GPS movement is visually smoothed: facing-up GPS-follow
  glides the map under the centered current-location puck, and north-up glides
  the puck/cone display point. Large or stale movements snap.
- Theme change clears visible tile cache and queues new requests.
- `CMD_MAP_SETTINGS` clears visible tile cache and queues new requests without
  changing route, GPS, destination, or UI state.
- Tile animation supports no animation, fade in, and fade + zoom as specified
  by `WATCH_TILE_LOAD_ANIMATION_SPEC.md`.
- Oversized or malformed payloads are rejected without fixed-buffer overflow.
