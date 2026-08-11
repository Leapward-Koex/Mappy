# Map Orientation And Follow Camera Spec

This spec defines the watch map orientation preference and the camera-mode
behavior around GPS follow, manual panning, and recentering. The intent is to
mirror the Google Maps interaction model: heading-up rotation is an automatic
follow-camera behavior, not a global orientation applied while the user is
manually browsing the map.

## User Goal

The user can choose the orientation used while the watch camera is centered on
the current GPS position:

| Setting value | User-facing label | Behavior |
| --- | --- | --- |
| `north_up` | North up | The watch map is aligned to true north in both follow and manual-browse modes. The current-location puck/view cone uses the wearer-facing watch compass heading in screen space. |
| `forward_up` | Face forward | While GPS-follow is active and a valid facing bearing is available, the watch rotates geographic map content so the wearer-facing compass direction points toward the top of the screen. Manual panning exits GPS-follow and suspends this automatic rotation until the user recenters. |

Default: `north_up`.

The default preserves the current specified behavior. `forward_up` is an
explicit opt-in because it costs more watch-side rendering work, may require
more visible tile coverage while following, and depends on a valid facing
heading.

Do not present `forward_up` as a promise that the whole map remains
heading-up after the user pans away. It is a centered/follow-camera preference.

## Ownership

| Component | Responsibility |
| --- | --- |
| Flutter companion | Presents and persists the centered-orientation preference. |
| Android native bridge | Stores the normalized setting, reconciles startup state, and sends watch sync commands. |
| Phone tile worker | No orientation-specific provider path. It still answers ordinary `CMD_TILE_REQUEST` messages. |
| Pebble watch | Applies the preference during follow-mode geographic projection, drawing, tile coverage calculation, and heading fallback; owns follow/manual-browse state and recenter behavior. |

The Google provider, source tile cache, encoded tile cache, route worker, and
saved-location model do not branch on map orientation. Orientation is a
watch-display preference, not a map-source setting.

## Protocol

Add:

```text
CMD_MAP_ORIENTATION = 205
```

Direction:

- Phone -> watch is required.
- Watch -> phone is optional and used only if a watch-side settings control is
  implemented later.

Payload:

| Key | Meaning |
| --- | --- |
| `button_id` | `0` north up, `1` facing up |
| `total_bytes` | optional monotonically increasing phone-local settings generation |

Startup:

- `CMD_INIT.chunk_offset` may carry the watch-persisted orientation preference:
  `0` north up, `1` facing up.
- If `chunk_offset` is missing, out of range, or not understood, the receiver
  must use `north_up`.
- After `CMD_INIT`, the phone sends its current `CMD_MAP_ORIENTATION` value
  during normal settings reconciliation.
- An explicit phone UI change wins over watch startup state and is pushed to
  the watch.

Cache behavior:

- `CMD_MAP_ORIENTATION` must not clear phone provider sessions, source tile
  cache, or encoded watch tile cache.
- The watch may keep decoded tile entries whose x/y/zoom still match requested
  world crops.
- If GPS-follow is active, the watch must recalculate visible tile coverage and
  queue any newly needed `CMD_TILE_REQUEST` messages.
- If manual-browse mode is active, the watch records the new preference but does
  not rotate or recenter the current browsed viewport. The preference takes
  effect the next time the user recenters into GPS-follow.
- This command must not be represented as `CMD_MAP_SETTINGS`; `CMD_MAP_SETTINGS`
  remains reserved for phone-side map source and rendered tile size changes.

## Map Facing Direction Source

The watch computes an active facing bearing for map rotation in degrees
clockwise from true north:

1. Production Pebble builds with `PBL_COMPASS` use the corrected Pebble
   `CompassService` heading from the watch. This is the same heading source used
   by the current-location cone.
2. Non-compass builds or tests that cannot provide watch compass samples may use
   the latest valid heading carried in `CMD_GPS.button_id` as a facing-heading
   stand-in.
3. Otherwise the facing bearing is unavailable.

Invalid or stale heading rules:

- `CompassStatusUnavailable`, `CompassStatusDataInvalid`, or an uninitialized
  compass heading means the production facing bearing is unavailable.
- On startup, set the Pebble heading callback threshold to 5 degrees, subscribe,
  and immediately call `compass_service_peek()`.
- A calibrated sample is usable immediately. Calibrating data becomes usable
  only after at least three consistent samples spanning 250 ms with no more
  than 20 degrees of circular spread.
- Ignore accepted-heading changes of at most 3 degrees. A change greater than
  60 degrees is provisional until another sample at least 200 ms later is
  within 15 degrees of it; reject an unconfirmed candidate after 750 ms.
- While GPS state makes the watch compass relevant, peek every two seconds and
  invalidate the heading after five seconds without a callback or successful
  peek. Pause this monitor while the app is obscured and peek immediately when
  focus returns.
- For non-compass fallback paths, `CMD_GPS.button_id = -1` means the stand-in
  heading is unavailable.
- A fallback heading must not be used after the local heading freshness timeout
  or when location is stale.
- `forward_up` falls back to north-up projection while the facing bearing is
  unavailable.
- The watch must not keep rotating the map from a stale or invalid facing
  bearing.
- Phone GPS/course heading must not drive production map orientation on
  `PBL_COMPASS` builds.
- Until a declination correction is received, diagnostics and exports identify
  the watch bearing reference as magnetic rather than true north.

This section defines map rotation and intentionally shares the same production
heading source as the current-location view cone, as specified in
`../watch/CURRENT_LOCATION_VIEW_CONE_SPEC.md`.

## Motion-Assisted Bearing Reacquisition

Face-forward navigation uses watch-local accelerometer data to recognize when
the wearer transitions from walking with the watch lowered to raising and
looking at the watch. The detector is automatic and has no user setting or
phone dependency.

Sensor lifecycle:

- Subscribe to `AccelData` at 25 Hz in batches of five only while a confirmed
  walking route is active, the stored orientation is `forward_up`, GPS-follow
  is active, and the map is not obscured by a menu.
- Unsubscribe and reset the detector on manual pan, menu entry, north-up
  selection, route clear/arrival, or app teardown.
- Ignore samples whose `did_vibrate` flag is set. Raw accelerometer axes and
  timestamps must not be sent to the phone or retained after classification.

The fixed-memory detector uses these initial responsive thresholds:

1. Estimate gravity per axis with a 1/8 low-pass filter. Dynamic motion is the
   sum of the absolute raw-minus-gravity residuals.
2. Confirm walking after three step-like peaks of at least 180 mg, separated by
   250–900 ms and contained within two seconds. A peak must remain aligned with
   gravity so a wrist rotation alone cannot complete the walking cadence.
3. Maintain a 1/16 filtered arm-down gravity baseline while walking.
4. Start a raise candidate when filtered gravity moves at least 35 degrees from
   that baseline during walking or within two seconds of the last walking peak.
5. Confirm looking when the raised orientation remains at least 30 degrees from
   baseline and within 12 degrees of a stable reference for 300 ms. Expire an
   unconfirmed candidate after 1.5 seconds.
6. Emit at most one watch-look event per walking episode. Another three-peak
   walking cadence is required before a subsequent watch look can trigger.

A confirmed watch look enables the fast bearing profile for 1.5 seconds. Route
start also enables that profile for every travel mode; if heading is initially
invalid, route start may wait up to three seconds for the first valid heading
and then receives the full 1.5-second fast window.

Bearing animation remains shortest-path and uses the shared 30 ms scheduler:

| Profile | Base step per tick | Tail rule |
| --- | --- | --- |
| Normal | `clamp(abs_delta / 4, 4 deg, 12 deg)` | Complete when the remaining delta fits in one step. |
| Fast reacquire | `clamp(abs_delta / 3, 8 deg, 24 deg)` | Split the final 24–48 degrees across two frames and complete the final at-most-24 degrees in one frame. |

The fast profile therefore remains animated and settles a worst-case
180-degree change within eight ticks/240 ms. Every accepted compass update in
the window replaces the target. Invalid heading still falls back to north-up;
it must never cause a stale or synthetic bearing to be animated.

## Watch Projection

The watch keeps the same viewport center model:

```text
viewport_world_x
viewport_world_y
viewport_zoom
```

The watch also tracks a camera mode:

```text
camera_mode = gps_follow | manual_browse
manual_pan = false | true
```

Google Maps-style camera rules:

- GPS-follow mode is the default after startup once a fresh GPS fix exists.
- In GPS-follow mode, the viewport center follows the latest current-location
  world position.
- In GPS-follow mode with `forward_up` and a valid facing bearing, heading
  updates may rotate the map around the current-location/viewport center.
- Any accepted single-finger pan changes `camera_mode` to `manual_browse`, sets
  `manual_pan = true`, and suspends heading-driven map rotation.
- In manual-browse mode, fresh GPS continues to update the current-location
  marker and navigation progress, but it must not recenter or rotate the
  viewport.
- A compact recenter action clears manual pan, sets `camera_mode = gps_follow`,
  centers the viewport on the latest GPS fix, and reapplies the stored
  orientation preference.
- Panning must not be disabled merely because the map is centered.

Because the current Pebble/RePebble SDK exposes no reliable multi-touch rotate
gesture, MVP must not implement arbitrary user map rotation. Manual-browse mode
therefore renders north-up.

`north_up` projection is the existing unrotated projection:

```text
screen_x = screen_center_x + world_dx
screen_y = screen_center_y + world_dy
```

`forward_up` projection applies only while `camera_mode = gps_follow`. It
rotates all geographic content around the viewport center by the inverse of the
active facing bearing so that:

| Facing bearing | Expected screen orientation |
| ---: | --- |
| 0 degrees north | Same as north-up |
| 90 degrees east | East points up; north appears left |
| 180 degrees south | South points up |
| 270 degrees west | West points up; north appears right |

Geographic content includes:

- map tile pixels,
- route polyline,
- destination/route marker,
- current-location marker position,
- heading/current-location cursor glyph.

The current-location glyph's visual puck/cone style is defined by
`../watch/CURRENT_LOCATION_VIEW_CONE_SPEC.md`.

Top/bottom status bands, menus, text, and other UI chrome do not rotate.

In GPS-follow mode with a valid facing bearing, the current-location cursor is
centered and its cone points toward the top of the screen. In manual-browse
mode, the current-location cursor may be off center and the map is north-up
until the user recenters.

## GPS Movement Smoothing

Accepted `CMD_GPS` movement should animate only when the new fix is a plausible
incremental movement from the last accepted fix. The watch computes the movement
distance in zoom-16 world pixels between the previous accepted GPS x/y and the
new GPS x/y. It computes elapsed time from `gps_elapsed_ms` when both old and
new fixes provide a monotonic value; otherwise it uses the local receive gap, or
a 1 second default when no reliable gap exists.

The smoothing distance limit `X` is mode-aware. While an active route exists,
use the active route travel mode. Otherwise use the selected watch travel mode.
Clamp elapsed time used for `X` to 5 seconds so stale GPS gaps do not allow large
animated jumps.

| Mode | `X` before cap | Non-navigation cap | Navigation cap |
| --- | --- | ---: | ---: |
| walk | `8px + 3px/s * elapsed_s` | 48 px | 36 px |
| bike | `12px + 10px/s * elapsed_s` | 128 px | 96 px |
| drive | `20px + 45px/s * elapsed_s` | 256 px | 192 px |

If the movement distance is greater than `X`, if the GPS sequence is stale, or
if this is the first accepted fix, the watch snaps to the new fix with no
smoothing.

For `forward_up` GPS-follow with a valid facing bearing, a smooth GPS movement
animates the render viewport from the previous display center to the new
viewport center. The current-location puck remains visually centered while map
tiles, route geometry, and destination markers glide underneath it. Tile
requests, route progress, and navigation state still update against the latest
accepted GPS target immediately.

For `north_up`, `forward_up` fallback-to-north, and manual-browse north-up
projection, a smooth GPS movement animates only the render position of the
current-location puck/cone from the previous display GPS point to the new GPS
point. Existing viewport follow behavior remains unchanged: GPS-follow may
recenter immediately, while manual browse never recenters from GPS.

Manual panning, recenter, zoom changes, and orientation changes complete any
active GPS smoothing immediately before applying their own camera state.

## Tile Coverage

Rotating a rectangular viewport expands the geographic footprint that must be
covered by decoded map crops. The watch must compute tile requests from the
orientation-aware visible footprint, not only the unrotated screen bounds.

Required algorithm:

1. Compute the screen rectangle that needs geographic coverage. Exclude only UI
   chrome if the renderer can prove map pixels never draw behind that chrome;
   otherwise use the full screen bounds.
2. In `north_up`, use the current unrotated bounds.
3. In `manual_browse`, use the current unrotated bounds even if the stored
   preference is `forward_up`.
4. In `forward_up` GPS-follow mode, inverse-rotate the screen rectangle corners
   around the viewport center using the active facing bearing.
5. Build an axis-aligned world-pixel bounding box around those inverse-rotated
   corners.
6. Request every configured watch tile crop that intersects that world-pixel
  bounding box, using the active rendered tile width/height and the same
  duplicate suppression and queue/refill behavior used by normal tile
  requests.

Expected `emery` consequence:

- The existing 5x5 grid is enough for the current north-up spec.
- Facing-up can require more coverage at diagonal bearings while GPS-follow is
  active.
- For an approximately 200x228 screen and the default 54x63 tiles, the
  worst-case facing-up footprint is expected to require about 7 columns by 6
  rows before implementation-specific margins.
- Larger configured rendered tiles reduce the required crop count; smaller ones
  increase it.

Implementation must heap-test the larger decoded coverage before enabling the
setting. If the target watch cannot hold the larger decoded set, the
implementation must use an equivalent refill/streaming strategy or leave the
setting disabled with visible unsupported-state copy. It must not ship a
facing-up GPS-follow mode that leaves blank corners during normal rotation.

## Rendering

The watch may implement rotated rendering by either:

- inverse-sampling decoded tile pixels per framebuffer pixel, or
- transforming tile, route, and marker projections through a shared rotation
  helper.

Rules:

- All geographic layers must use the same orientation transform for a given
  frame.
- Nearest-neighbor sampling is acceptable for rotated map tile pixels.
- Missing rotated-corner tiles may show normal blank/stale placeholders while
  requests are in flight, but available matching tiles must remain visible.
- Changing orientation schedules a redraw immediately only in GPS-follow mode.
  In manual-browse mode, the watch may redraw settings chrome/status but must
  not rotate, recenter, or request rotated-footprint coverage until recenter.
- Changing orientation does not change route, GPS, destination, travel mode, or
  nav-step state.

Performance requirements:

- Accepted facing-heading updates in `forward_up` GPS-follow mode must schedule
  a map redraw with low latency.
- Facing-heading updates in manual-browse mode must not rotate the map or
  rebuild tile coverage.
- The watch must not rebuild the visible tile request queue for every accepted
  compass sample. It should compare the current orientation-aware tile coverage
  with the last requested coverage, and only requeue when the origin set changes
  or heading validity changes.
- The rotated tile renderer should compute trigonometry once per frame, avoid
  per-pixel fixed-point division where the platform trig ratio allows shifts,
  and skip decoded tile entries whose rotated bounds do not intersect the
  framebuffer.

## Input Behavior

Hardware zoom:

- Zoom behavior is unchanged.
- After zoom, the watch recalculates orientation-aware tile coverage.

Touch panning:

- In `north_up`, drag behavior remains as specified by
  `../watch/WATCH_TOUCH_INPUT_SPEC.md`.
- When a single-finger drag is accepted while `forward_up` GPS-follow is
  active, the watch exits GPS-follow before applying the manual pan. The browsed
  viewport is north-up, and drag deltas use the normal north-up screen/world
  mapping.
- The watch must not continue to accept compass/heading rotation while
  `manual_pan = true`.
- Recenter restores GPS-follow and, if the stored preference is `forward_up`,
  resumes heading-up rotation once a valid facing bearing is available.
- Touch panning must still use only ordinary `CMD_TILE_REQUEST` messages.

Pinch zoom:

- Current production builds do not support pinch zoom because the SDK exposes no
  reliable multi-touch/pinch data. Hardware Up/Down buttons remain the required
  zoom path.
- If a future SDK exposes reliable pinch data, pinch zoom must not introduce a
  rotate gesture. If it changes the viewport center, it follows the same
  manual-browse transition as panning.

Menus:

- Watch settings/actions may show the current orientation.
- Full editing is required in the Flutter Settings screen. Watch-side editing is
  optional; if added, it must send `CMD_MAP_ORIENTATION`.
- When the user directly selects `forward_up` from the watch while manually
  browsing, the watch recenters on the latest GPS fix and resumes GPS-follow so
  the requested orientation takes effect immediately. This does not change the
  protocol rule for phone-originated settings reconciliation, which records the
  preference without moving a manually browsed viewport.

## Mobile UI

The Flutter Settings screen may include a compact control when the connected
watch build supports facing-up follow mode:

```text
Centered map: North up | Face forward
```

Rules:

- Do not label this as a global map-orientation toggle.
- Persist locally.
- Include in normal display settings status.
- Call the native settings path, not `setMapTileSettings`.
- Do not clear provider caches.
- Do not trigger a route refresh.
- Show a short unavailable state only if the connected watch build reports that
  facing-up is unsupported.
- Changing this setting while the watch is manually panned records the
  preference but must not force the watch to recenter or rotate immediately.

## Diagnostics

Diagnostics should include:

- persisted centered-map orientation,
- last sent `CMD_MAP_ORIENTATION` value and generation,
- watch-applied orientation,
- camera mode: GPS-follow or manual-browse,
- whether heading-driven rotation is currently suspended by manual pan,
- heading source used for facing-up: watch compass, non-compass fallback, or
  none,
- watch compass status used for the current-location view cone and facing-up
  map rotation,
- fallback reason when facing-up is unavailable,
- expanded tile coverage dimensions when facing-up is active.

No API keys, route labels, or precise coordinates are required for these
diagnostics.

## Test Requirements

Protocol tests:

- Round-trip `CMD_MAP_ORIENTATION` values `0` and `1`.
- Reject or normalize unsupported values to `north_up`.
- Verify `CMD_INIT.chunk_offset` startup sync defaults safely when missing.

Watch unit tests:

- Heading 0 leaves projection equivalent to north-up.
- Heading 90 places east/up and north/left.
- Invalid map facing bearing in `forward_up` falls back to north-up projection.
- Manual pan while `forward_up` is active enters manual-browse mode, renders
  north-up, and ignores subsequent heading changes for map rotation.
- Recenter from manual-browse mode centers on the latest GPS fix and reapplies
  `forward_up` when the bearing is valid.
- Selecting `forward_up` from the watch in manual-browse mode centers on the
  latest GPS fix and resumes heading-driven rotation without requiring a
  separate recenter action.
- Current-location cone direction follows the watch compass source specified in
  `../watch/CURRENT_LOCATION_VIEW_CONE_SPEC.md`.
- Orientation changes do not clear route, GPS, destination, or nav-step state.
- Facing-up GPS-follow tile coverage includes all inverse-rotated viewport
  corners.
- Touch drag in facing-up exits follow mode and then moves north-up map content
  with the user's finger.
- Idle, short walking, closely spaced bumps, vibration-contaminated samples,
  and a stationary wrist raise do not emit a watch-look event.
- Three cadence peaks followed by a stable raised pose emit exactly one
  watch-look event; a new walking cadence rearms the detector.
- Normal bearing smoothing retains its existing 4–12 degree profile. Fast
  reacquisition is visibly animated, follows the shortest wraparound path,
  accepts a changed target, and completes 180 degrees within 240 ms.

Mobile tests:

- Settings screen persists the selected centered-map orientation preference.
- Settings screen sends the native display-settings payload, not
  `setMapTileSettings`.
- A fake connected watch receives `CMD_MAP_ORIENTATION` after settings change
  and after reconnect.

Visual/emulator tests:

- Capture north-up and facing-up GPS-follow screenshots at headings 0, 90, 180,
  and 270 degrees.
- Capture manual-browse screenshots after panning away from facing-up follow and
  verify that the browsed map remains north-up while GPS/route state continues
  to update.
- Verify the current-location cone is compensated by map rotation in
  facing-up and still represents the watch compass heading.
- Verify no blank rotated corners remain after all requested tiles arrive.
- Verify UI bands and menu text remain unrotated and within bounds.
- Replay deterministic stationary-raise and walking-to-look accelerometer
  fixtures. Only walking-to-look starts fast reacquisition, and it produces one
  look event before requiring another walking cadence.

## Acceptance Criteria

- Default installs use north-up.
- User can switch the centered/follow camera to face-forward behavior from
  Flutter Settings when the connected watch supports it.
- The connected watch applies the setting without a route restart or provider
  cache clear.
- Facing-up rotates map tiles, route, destination marker, and current
  location consistently only while GPS-follow is active.
- Manual panning suspends follow and heading-driven rotation, shows/keeps a
  compact recenter action, and does not disable panning.
- Recenter restores GPS-follow and the selected centered-map orientation.
- Invalid or stale heading falls back without showing stale direction.
- Starting face-forward navigation in any travel mode accelerates initial
  bearing acquisition. During a walking route, walking-to-look detection starts
  one 1.5-second fast-animation window and settles the latest target within
  240 ms without snapping.
- Facing-up requests enough tile coverage for the rotated viewport while
  GPS-follow is active.
- The feature works without adding a project backend, a Google Maps notification
  listener, or a new tile provider path. Watch compass support is owned by the
  current-location view cone behavior, not by the map tile provider.
