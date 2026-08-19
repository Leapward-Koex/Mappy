# Watch Touch Input Spec

This spec defines production touch behavior for the real Pebble Time 2 /
`emery` watch app. It complements `WATCH_APP_MVP.md` and
`WATCH_UI_LAYOUT_SPEC.md`; the watch remains the owner of immediate viewport and
zoom state, while the phone remains the owner of map tile generation.

## Goals

- Support direct map panning on real touch-capable watches.
- Give qualifying fast pans a short watch-local kinetic coast without adding
  heap allocation, another animation timer, or per-frame phone work.
- Support pinch-to-zoom and pinch-to-zoom-out when the watch SDK and hardware
  expose reliable multi-touch or pinch-distance data.
- Prefer smooth visual zoom while a pinch gesture is active.
- Allow a discrete level-change implementation when the available touch API only
  supports coarse gesture state.
- Preserve hardware-button zoom on all builds.
- Avoid any new phone-side touch command or provider path.
- Follow familiar map-camera behavior: panning away from the centered current
  location exits follow mode, suspends automatic facing-up rotation, and leaves
  recenter as the explicit way back.

## Platform Gating

Touch input is optional at build and runtime:

- Compile all touch references behind `#ifdef PBL_TOUCH`.
- Treat `touch_service_is_enabled() == false` as no-touch mode.
- Subscribe to touch input only while the map or navigation surface is active
  and no modal/menu owns input.
- Unsubscribe when leaving map/navigation surfaces and during teardown.
- Non-touch builds and disabled-touch runtime states must keep GPS follow,
  hardware button zoom, menus, routes, and recenter behavior fully usable.

The implementation must verify the exact RePebble/Pebble touch API available on
real `emery` hardware before shipping pinch support. If the production SDK only
reports one contact point and no pinch/second-contact data, pinch is not
considered implementable for that build; do not infer a fake pinch from unrelated
single-finger events.

## Current Implementation Decision

The current production watch build uses the documented no-pinch fallback. Touch
references are compiled only behind `PBL_TOUCH`; when touch is available, the
watch supports single-finger panning with a qualifying kinetic coast and sends
ordinary tile requests for the settled viewport. The touch event shape currently
used by the build exposes one contact point and no reliable second-contact,
pinch-distance, or scale data, so pinch zoom is not advertised as supported for
this build.

Until a real `emery` SDK/hardware probe proves reliable pinch or multi-touch
data, zoom remains available through the hardware Up/Down buttons. The watch
records local `CMD_LOG_EVENT` diagnostics for `pinch_unavailable`,
`touch_disabled`, and `zoom_clamped` without sending raw touch coordinate traces
or any touch-specific AppMessage command.

## Gesture Ownership

The watch owns these touch gestures:

| Gesture | Watch behavior | Phone behavior |
| --- | --- | --- |
| Single-finger drag | Pan viewport locally; a qualifying fast liftoff coasts briefly before settlement. | Receives only normal `CMD_TILE_REQUEST` messages for missing crops after settlement. |
| Two-finger pinch in | Zoom out locally. | Receives existing `CMD_BUTTON` zoom notification and later tile requests. |
| Two-finger pinch out | Zoom in locally. | Receives existing `CMD_BUTTON` zoom notification and later tile requests. |
| Tap or ambiguous touch | No MVP map action. | No command. |

Touch gestures must not send a touch-specific AppMessage command. Pinch zoom uses
the same local zoom path as Up/Down hardware-button zoom and reports committed
level changes through `CMD_BUTTON` with `button_id = 1` for zoom in and
`button_id = -1` for zoom out.

## Shared Viewport Model

Touch panning and pinch zoom both operate on the same viewport state:

```text
viewport_world_x
viewport_world_y
viewport_zoom
transient_zoom_scale
map_orientation
camera_mode
manual_pan
pan_inertia
```

Rules:

- GPS-follow mode is the default.
- Starting an accepted drag that changes the viewport sets
  `camera_mode = manual_browse` and `manual_pan = true`.
- Fresh GPS continues to update the current-location puck and navigation
  progress, but it must not recenter the viewport while a gesture is active or
  manual pan is set.
- The watch must provide a compact recenter action that clears manual pan and
  recenters on the latest GPS fix.
- If the stored orientation preference is facing-up, manual browse suspends
  heading-driven map rotation and renders north-up until recenter.
- Route lines, destination markers, current-location puck/view cone or
  off-screen edge line, and map tiles must all project from the same viewport
  state and active map orientation.

## Single-Finger Pan

Pan behavior follows `WATCH_APP_MVP.md`:

1. Touchdown records `x/y` and the current viewport center.
2. Once movement passes the pan threshold, the watch exits GPS-follow, sets
   `manual_pan = true`, suspends heading-driven rotation, and treats the browsed
   map as north-up.
3. Position updates adjust the viewport center by the drag delta in current
   screen/world scale and record timestamped viewport samples.
4. Liftoff applies its newest coordinates, then starts kinetic panning only when
   recent samples show a qualifying fast release.
5. A slow drag, tap, held release, or stale release settles immediately.
6. A qualifying release coasts locally, then settles and queues visible missing
   tile crops once.

Dragging map content right/down moves the viewport center left/up in world-pixel
space. If the drag began from facing-up follow mode, the first accepted drag
also transitions the map to north-up manual browse; subsequent drag deltas use
ordinary north-up mapping. One-finger rotate is not supported or inferred.
Each accepted position update redraws the current-location overlay. Once its
white puck halo is completely outside the screen, the edge line defined by
`CURRENT_LOCATION_VIEW_CONE_SPEC.md` must move directly with the clamped GPS
projection and wrap continuously around corners.

## Kinetic Pan And Settlement

Kinetic panning is a small fixed-point extension of single-finger pan. It does
not change the phone protocol, persisted settings, or user-visible controls.
Its internal math API provides reset, sample observation, conditional start,
active-state query, elapsed-time advance, and cancellation operations using only
standard C types, so it remains independent of Pebble types for host tests.

Release sampling and velocity rules:

- Timestamp viewport samples with `time_ms()` because touch events do not carry
  timestamps.
- Coalesce samples less than 8 ms apart and discard history older than 120 ms.
- Reject inertia when the last movement is more than 80 ms before liftoff.
- Estimate velocity in Q8 world pixels per 30 ms logical tick, weighting the
  newest sample 75 percent.
- Start at approximately 2 px per logical tick, and cap the direction-preserving
  velocity vector at 14 px per tick.

Coast rules:

- Add kinetic pan as the fifth source in the shared 30 ms visual scheduler; do
  not register a second animation timer for inertia.
- Apply fractional fixed-point displacement and decay velocity by `208/256`
  after each logical tick.
- Stop below 0.5 px per tick or after 12 logical ticks (360 ms), with total
  displacement bounded to approximately 70 px for a capped release.
- When a scheduler callback is delayed, consume the elapsed logical ticks in
  one callback and dirty the map only once.
- Add displacement to signed viewport coordinates with saturation. Kinetic pan
  does not introduce geographic wrapping or new viewport clamping.
- Coast frames stay in north-up manual-browse mode and use the same cached map,
  route, destination, and current-location rendering path as drag frames.

The pan settle operation is idempotent. Tile request dispatch, request-queue
coverage rebuilding, and new tile-response decoding remain paused from accepted
drag until settlement. Kinetic scheduler frames do not initiate route-detail
requests; unrelated route activity is not globally paused. Settlement updates
map/route state once, starts the existing 100 ms tile-resume grace period,
rebuilds the visible request queue once, refreshes motion-service state, and
issues one final redraw.

A new touchdown stops an active coast at its current viewport without briefly
resuming tile requests; the new gesture inherits the paused state. Opening a
menu/modal, zooming, recentering, losing touch input, or another button action
settles kinetic pan before performing that action. App teardown cancels kinetic
pan without resuming work. Failure to register the shared scheduler callback
falls back to immediate settlement.

## Pinch Zoom

Pinch recognition requires either:

- two simultaneous contacts with stable `x/y` coordinates, or
- a SDK-provided pinch gesture with scale or distance deltas.

When pinch recognition is available:

1. Pinch start records the two-contact midpoint, initial contact distance,
   viewport center, committed zoom, and tile grid state.
2. Pinch updates compute a scale factor from current distance divided by initial
   distance.
3. The point under the pinch midpoint should remain visually anchored when
   practical; at minimum the viewport must not jump away from the gesture center.
4. Pinch out increases apparent scale and eventually commits zoom in.
5. Pinch in decreases apparent scale and eventually commits zoom out.
6. Pinch end commits the final supported zoom level, clears the transient scale,
   invalidates mismatched visible tiles, and queues the normal visible tile grid.

Zoom bounds:

- Initial MVP supported map zoom range is 14..18 unless the tile pipeline spec is
  revised with measured provider, memory, and UI results.
- Pinch updates beyond the bounds must clamp visually and must not emit extra
  `CMD_BUTTON` notifications.

## Smooth Zoom Preference

Preferred implementation:

- During an active pinch, render already decoded map tiles with
  nearest-neighbor scaling using `transient_zoom_scale`.
- Update route, marker, and destination projections with the same transient
  scale so overlays stay attached to the map.
- Do not request new phone tiles for every intermediate pinch update.
- Commit a new integer zoom level only when the scale crosses a stable threshold
  or when the gesture ends.
- After commit, send the existing `CMD_BUTTON` notification once per committed
  level delta and request the visible tiles for the committed zoom.

Suggested thresholds:

```text
zoom_in_threshold  = 1.35x from the last committed level
zoom_out_threshold = 0.74x from the last committed level
```

The exact thresholds may be tuned with real-watch testing. Threshold changes must
avoid oscillating between adjacent zoom levels during small finger tremor.

## Discrete Pinch Fallback

If the SDK exposes pinch direction or coarse scale but smooth per-frame scaling
is not stable enough on real hardware, the app may implement discrete pinch
levels:

- Pinch out crossing the implementation threshold commits one zoom-in level.
- Pinch in crossing the implementation threshold commits one zoom-out level.
- The watch may repeat another level change only after the pinch distance moves
  past the next threshold or after a new pinch starts.
- Each committed level sends the same `CMD_BUTTON` payload as button zoom.
- Visible tile cache invalidation and tile requests match normal zoom behavior.

If the SDK exposes no reliable multi-touch or pinch gesture data, the fallback is
hardware-button zoom plus touch panning. That limitation must be documented in
release notes or the implementation notes for the affected build.

The current production SDK path is this no-pinch fallback. Do not advertise or
test pinch as supported until a real `emery` SDK/hardware probe exposes
reliable multi-touch, pinch-distance, or SDK-provided scale data.

## Interaction With Menus And Navigation

- Menus, modals, and confirmation prompts own input while visible; map touch
  gestures must be unsubscribed or ignored during those states. Opening one
  settles an active kinetic pan before transferring input ownership.
- Pinch zoom is allowed during normal map view and active navigation.
- Pinch zoom must not resize or move top/bottom UI bands, menu rows, or modal
  chrome.
- Single-finger panning is allowed during normal map view and active navigation.
  It exits GPS-follow and suspends facing-up auto-rotation until the user
  recenters, matching Google Maps navigation behavior.
- Navigation instruction text remains anchored in the bottom band while the map,
  route, marker, and destination projections zoom underneath it.
- Back, Up, and Down keep their existing behavior. A sub-700 ms Select press
  retains the existing short-click action; a Select hold of at least 700 ms
  settles any active pan and recenters through the normal GPS-follow path.
- Long Select must not open Actions on release or repeat while held. It is inert
  while a menu owns input, and it only dismisses an arrival modal. With no GPS
  fix it reports the existing `Waiting for GPS` state.
- Zoom, recenter, touch-service loss, and other button actions settle active
  kinetic pan before acting. Teardown cancels it without queueing new work.

## Protocol And Tile Flow

Pinch zoom uses existing MVP protocol:

1. Watch applies zoom locally.
2. Watch sends `CMD_BUTTON` with `button_id = 1` or `-1` for each committed
   integer zoom change.
3. Phone cancels or ignores stale tile work for the prior zoom.
4. Watch queues ordinary `CMD_TILE_REQUEST` messages for the new viewport and
   zoom.
5. Phone returns ordinary `CMD_TILE` payloads or `CMD_ERROR_STATE`.

No phone code may branch on whether the viewport change came from buttons, GPS
follow, pan, pinch, or orientation except for diagnostics labels.

Pan drag and kinetic coast remain entirely watch-local. The watch keeps tile
requests paused across both phases, then rebuilds request coverage once after
settlement and resumes ordinary `CMD_TILE_REQUEST` traffic after the existing
100 ms grace period. An interrupting touchdown continues the pause rather than
producing an intermediate request burst.

## Diagnostics

Watch diagnostics may record bounded local events for:

- touch disabled at runtime,
- pinch unavailable because no multi-touch/pinch data exists,
- pinch rejected because the gesture was ambiguous,
- zoom clamped at min/max,
- excessive dropped frames during smooth pinch rendering.

Diagnostics must not include raw touch coordinate traces beyond short numeric
summaries needed to debug gesture handling.

The opt-in real-watch performance build emits one aggregate
`MAPPY_HW_COAST` summary per release (qualification, logical ticks, rendered
frames, first-frame latency, total/max draw time, settlement time, and
cancellation), not a log line for every coast frame.

## Verification

Real-watch verification on `emery` is required before pinch is called supported:

- Build with `PBL_TOUCH` enabled.
- Confirm runtime touch service availability.
- Confirm single-finger pan changes viewport and produces only normal tile
  requests.
- Confirm a qualifying recent fast liftoff coasts in the release direction for
  1..12 logical ticks, settles within 450 ms, and travels no more than the
  approximately 70 px bound. Confirm slow, tap, held, and stale releases settle
  immediately.
- Confirm tile request dispatch and new tile-response decoding stay paused
  during drag and coast, request coverage rebuilds once at settlement, and the
  visible grid completes within the existing 5-second fill gate without
  transfer errors.
- Confirm a new touchdown interrupts coast without resuming requests, and menu,
  modal, zoom, recenter, touch loss, and button actions settle deterministically.
- Confirm single-finger pan from facing-up GPS-follow enters manual-browse
  north-up mode, ignores later heading changes for map rotation, and keeps route
  progress/current-location updates active.
- Confirm recenter returns to GPS-follow and reapplies facing-up when selected
  and the facing bearing is valid.
- If the capability probe reports reliable pinch or two-contact data, confirm
  pinch out zooms in and pinch in zooms out.
- If the capability probe reports no reliable pinch data, confirm pinch is not
  advertised or interpreted and hardware-button zoom remains available.
- Confirm button zoom still works after touch gestures.
- Collect repeated slow and fast `MAPPY_HW_COAST` summaries; calculate latency
  percentiles from those aggregates without enabling per-frame coast logging.
- Confirm no touch gesture works while a menu/modal is active.
- Confirm map, route, current marker, heading, and destination projections stay
  aligned during pan and zoom.
- Confirm the off-screen current-location edge line follows manual drag frames
  along every side, bends around corners, and disappears after recenter.
- Confirm smooth zoom rendering is nonblank and does not corrupt UI bands; if
  smooth zoom is not shipped, record the discrete-level fallback decision.
- Confirm non-touch or disabled-touch builds pass the same map, zoom, route, and
  menu workflows with hardware buttons.

Simulator verification may cover protocol and renderer behavior, but it does not
replace the real-watch pinch availability check.

## Acceptance Criteria

- Real `emery` hardware can pan the map with one finger when touch is enabled.
- A recent fast release produces a subtle watch-local coast of at most 12
  logical 30 ms ticks and approximately 70 px; slow, tap, held, and stale
  releases settle immediately.
- Kinetic pan produces no phone command, setting, persistence, heap allocation,
  or protocol change. Its production data+BSS increase is at most 64 bytes and
  its binary-size increase is at most 3 KiB against an identical-mode baseline.
- Tile requests remain paused through drag and coast, then request coverage is
  rebuilt and resumed once after settlement; a new touchdown interrupts without
  an intermediate resume.
- On real `emery`, p95 input-to-first-changed-frame latency is at most 100 ms,
  p95 north-up coast draw time is at most 50 ms, no coast draw exceeds 100 ms,
  and kinetic settlement completes within 450 ms.
- Panning away from the centered current location suspends auto-follow and
  facing-up rotation instead of disabling panning.
- Panning the complete puck halo off-screen shows the specified blue/white edge
  line at the clamped GPS position and moves it without visible lag.
- Real `emery` hardware can pinch to zoom in/out when the SDK exposes reliable
  pinch or two-contact data.
- Pinch zoom sends only existing `CMD_BUTTON` zoom notifications plus normal
  tile requests.
- Smooth pinch zoom is implemented with transient nearest-neighbor scaling, or a
  documented discrete-level fallback is used because real-watch API or
  performance limits prevent smooth zoom.
- Non-touch and disabled-touch modes retain hardware-button zoom with no dead
  touch-only dependency.
