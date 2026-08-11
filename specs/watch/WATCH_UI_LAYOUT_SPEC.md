# Watch UI Layout Spec

This spec defines Mappy's watch UI layout for Pebble Time 2 / `emery`.
It prioritizes a readable map, glanceable navigation status, and bounded-memory
menus while deriving all screen geometry from the active Pebble platform.

## Design Rationale

Core surfaces:

- A full-screen map with route and current-location overlays.
- Top and bottom bands for compact navigation and status text.
- Destination/travel menus plus loading, no-route, off-route, and arrival states.
- Up to three local nav-step records per chunk to keep watch memory bounded.

Layout decisions:

- Target platform is `emery`.
- Code must query screen bounds from the SDK rather than assuming a fixed
  platform size.
- Initial `emery` visible tile grid is 5x5 as defined by
  `../shared/MAP_TILE_PIPELINE_MVP.md`.
- Tiles use the shared pipeline's 54x63 decoded crop geometry.
- Watch UI must be screenshot-verifiable in the Pebble emulator.

## Screen Model

The app uses one root window with layered drawing:

```text
root window
  map layer
  route overlay layer
  heading/current-location layer
  top status layer
  bottom instruction/status layer
  modal/menu layer when active
```

Layer order:

1. Map tiles.
2. Route polyline.
3. Current-location puck and heading view cone.
4. Top status band.
5. Bottom instruction/status band.
6. Menu/modal overlay.

No screen may be fully blank after native init. If no phone data is available,
show `WAITING_FOR_PHONE`.

## Geometry Rules

Use runtime bounds:

```text
screen = layer_get_bounds(window_get_root_layer(window))
screen_w = screen.size.w
screen_h = screen.size.h
```

Expected `emery` geometry is wider and taller than Basalt, but implementation
must not depend on a literal size except in emulator assertions.

Bands:

- Top status band height: 24 px minimum, up to 28 px if emulator text clipping
  requires it.
- Bottom band height: 42 px minimum, up to 52 px for two-line instructions.
- Map drawing area: full screen behind translucent or solid bands.
- Menu overlay: centered or full-height list, never nested inside another card.

Tile grid:

- The visible grid is 5 columns by 5 rows of 54x63 crops.
- The grid is computed from viewport world pixels, not screen pixel positions.
- Cached tiles may draw behind status bands, but must match current x/y/zoom.
- Blank/missing tiles must not draw full-cell boxes or outline strokes.
- Missing coverage leaves the base map background visible. Only the boundary
  where a missing cell touches a valid current/stale tile may show a narrow,
  deterministic dither transition a few pixels deep into the missing side.
- Missing coverage does not erase valid stale tiles with matching coordinates.

## Map View

Map-ready view shows:

- Top band: short state or destination/context text.
- Map tiles.
- Current-location puck near screen center.
- Current-location view cone only when heading is valid.
- Bottom band: loading, setup, error, or route instruction text when there is a
  useful message. Normal map-ready and manual-pan states may omit the bottom
  band entirely.
- Active centered-map orientation: north-up by default, or face-forward while
  GPS-follow is active as specified in
  `../shared/MAP_ORIENTATION_SETTING_SPEC.md`.

Current-location puck and view cone:

- Must follow `CURRENT_LOCATION_VIEW_CONE_SPEC.md`.
- Must be visible over both day and night tile palettes.
- Must not cover the entire route line.
- Should remain centered during normal GPS-follow mode.
- Must ignore `CMD_GPS` updates whose `gps_sequence` is not newer than the last
  accepted GPS sequence. Sequence-less messages remain valid because the field
  is optional and the emulator fixture intentionally omits it in some tests.
- In face-forward GPS-follow, plausible short GPS movements animate the map
  smoothly under the centered current-location puck.
- In north-up display, plausible short GPS movements animate the
  current-location puck/cone smoothly to the new fix.
- Movements larger than the adaptive travel-mode and elapsed-time threshold in
  `../shared/MAP_ORIENTATION_SETTING_SPEC.md` snap with no smoothing.
- Once the circular white puck halo is fully outside the display, replace the
  puck and cone with the clamped, rounded perimeter line defined by
  `CURRENT_LOCATION_VIEW_CONE_SPEC.md`. The line remains eligible outside
  manual browse and follows every viewport redraw.

Heading indicator:

- Rendered as the view cone defined by `CURRENT_LOCATION_VIEW_CONE_SPEC.md`.
- Hidden when heading is unavailable.
- Uses the Pebble watch compass heading for production watch builds.
- Magnetic declination UI is not MVP; declination correction may be supplied by
  the companion without adding watch UI.

Centered map orientation:

- North-up keeps true north at the top of the screen.
- Direction-up rotates map tiles, route line, destination marker, and current
  location around the viewport center so the wearer-facing compass bearing
  points toward the top of the screen while GPS-follow is active.
- Status bands, menu overlays, and all text remain unrotated.
- If facing-up lacks a valid facing bearing, the map projection falls back
  to north-up. The current-location cone remains governed by
  `CURRENT_LOCATION_VIEW_CONE_SPEC.md`.
- Manual panning exits GPS-follow, suspends direction-up rotation, and renders
  the browsed map north-up until recenter.
- Direction-up must request enough rotated-footprint tile coverage while active
  to avoid blank corners after all requested tiles arrive.
- GPS movement smoothing is display-only. It must not delay route progress,
  tile requests, destination arrival checks, or stale GPS rejection.
- Starting navigation and a detected walking-to-watch transition temporarily
  accelerate face-forward bearing animation without snapping. This changes no
  map chrome, text, route state, or user-visible setting.
- Continuous accelerometer detection is limited to active Walk routes and is
  suspended by a menu or manual browse until eligible GPS-follow resumes.

## Startup And Setup States

`WAITING_FOR_PHONE`:

- Top band: neutral state or context text, such as `Map`; do not show app-name
  branding inside the running watch app.
- Center or bottom text: `Waiting for phone`.
- No route or tile assumptions.

`SETUP_REQUIRED`:

- Show short phone-action text, such as `Open phone setup`.
- If native receives a specific error category, show the capped error text.
- Do not show stale route instructions as if navigation is active.

`MAP_LOADING`:

- Show `Loading map`.
- Draw any valid matching stale/current tiles.
- Show current-location marker if GPS exists.

`ROUTE_LOADING`:

- Keep map usable.
- Bottom band shows `Finding route` or capped destination/status text.
- User can back out or request route clear.

`ROUTE_ERROR`:

- Keep map usable.
- Show capped error text.
- Do not clear prior valid map tiles.

## Navigation View

Active navigation shows:

- Top band: destination or travel-mode/status context.
- Route overlay over map. Drive and bike use a continuous blue polyline;
  walking uses spaced blue dots with a white halo on the same route geometry.
- Current-location marker.
- Bottom band: first available instruction, next turn distance, or route status.

Text rules:

- Watch-facing instruction text is capped to 47 UTF-8 bytes before drawing.
- Long text wraps to two lines in the bottom band.
- If text still does not fit, truncate with a simple ASCII ellipsis `...`.
- Do not draw text outside its band.

Walk/bike provider warning:

- Walking and bicycling route displays must include a compact warning that safe
  path detail may be incomplete.
- The warning may be an abbreviated second-line suffix when space is tight.
- The warning must not obscure the current turn instruction.

No-route:

- Zero-point route payload clears route and step state.
- Bottom band shows `No route found`.
- Map remains usable.

## Menus

Menus are watch-native list overlays.

Saved-location menu:

- Shows configured saved locations from the latest `CMD_DESTINATIONS` payload.
- Does not render empty placeholder slots. If the list is empty, show a local
  "No destinations" row and do not send a route request.
- Selecting a saved location sends `CMD_ROUTE_REQUEST` with its saved-location
  ID and travel mode.
- If the selected ID is stale, missing, or no longer configured, the phone
  returns `CMD_ERROR_STATE` category 8; the watch may also show an immediate
  local hint.
- Primary destination search happens in the phone app; the watch menu is a
  shortcut for saved locations only.

Travel mode menu:

- Values: drive, walk, bike.
- The selected value is persisted and sent with route requests.
- Walk/bike warning must be visible before or during active route display.

Settings/actions menu:

- Minimum actions: saved-location menu, travel mode, reroute when route active,
  clear route when route active.
- Theme/units/backlight/centered map orientation may be phone-owned UI only
  unless watch implementation adds compact controls that match
  `WATCH_APP_MVP.md`.

## Button Behavior

Default map state:

| Button | Behavior |
| --- | --- |
| Select | Open destination/actions menu. |
| Up | Zoom in or move menu selection when menu active. |
| Down | Zoom out or move menu selection when menu active. |
| Back | Exit menu, clear route confirmation, or close app according to Pebble norms. |

Active route state:

| Button | Behavior |
| --- | --- |
| Select | Open route actions menu or request reroute if route action is focused. |
| Back | First press asks/indicates route stop; second press clears route. |

Touch-capable map state:

- On `PBL_TOUCH` platforms, drag panning moves the map layer and all geographic
  overlays together while top/bottom UI bands remain anchored.
- On real touch hardware with reliable pinch or multi-touch data, pinch zoom
  scales the map layer and all geographic overlays together while top/bottom UI
  bands remain anchored. Smooth transient scaling is preferred; discrete zoom
  levels are acceptable when documented in `WATCH_TOUCH_INPUT_SPEC.md`.
- Touch panning must not resize or reposition text, buttons, or modal/menu
  chrome. Only viewport-dependent map, route, marker, and destination projection
  changes.
- When panning carries the complete current-location halo off-screen, its edge
  line must track the projected location smoothly and wrap around corners
  without moving anchored chrome.
- While manually panned away from GPS-follow, avoid transient `pan`/`panning`
  status text in the bottom band. Recenter remains available through the compact
  actions menu without covering the current instruction text.
- While manually panned away after face-forward follow, map content is north-up
  and subsequent heading changes must not rotate it.
- Modal/menu overlays must either unsubscribe from touch or ignore touch-map
  gestures so button/menu behavior remains deterministic.
- Non-touch builds and disabled-touch runtime states use the button behavior
  above with no dead touch affordances.

Shake/tap reroute is not required for MVP. If implemented later, it requires
the background/navigation power spec.

## Color And Theme

Themes:

- Day.
- Night.
- Auto/day, where phone or watch setting chooses day/night state.

Rules:

- Theme changes clear visible tile cache and queue new tile requests.
- Phone-side map source or rendered tile size changes clear visible tile cache
  through `CMD_MAP_SETTINGS` and queue new tile requests.
- UI bands and text must remain legible over map colors.
- Route line and marker colors must be visible in both day and night modes.
- Do not rely on a single hue for all UI states.

## Error Text

Watch error text sources:

- `CMD_ERROR_STATE.instruction`.
- Setup state from bridge startup.
- Local malformed-payload guards.

Error copy must:

- Fit 47 UTF-8 bytes for watch payloads.
- Be drawn within top or bottom band.
- Prefer actionable short copy:
  - `Open phone setup`
  - `Waiting for GPS`
  - `Network unavailable`
  - `No route found`
  - `Tile unavailable`

## Layout Verification

Required screenshots on `emery`:

- Waiting for phone.
- Setup required.
- Map loading with marker.
- Map ready with full 5x5-backed visible coverage.
- Direction-up GPS-follow map ready at a nonzero heading with rotated-footprint
  tile coverage.
- Manual-browse map after panning away from direction-up GPS-follow, showing
  north-up content and a compact recenter path.
- Current location beyond each screen edge, near a corner, and beyond each exact
  corner, including the wrapped 90-degree edge-line geometry.
- Saved-location menu.
- Route loading.
- Active route with instruction.
- No route found.
- Route/provider error.
- Night theme.

Pixel/layout checks:

- Screen is nonblank.
- Top and bottom text stays within bands.
- Current marker is visible.
- A fully off-screen current marker is replaced by the blue/white edge line at
  the clamped projected position, with a 3 px clear gap outside its white
  outline.
- Route line is visible when route data exists.
- No menu text overlaps adjacent rows.
- Missing tiles do not produce full-screen blank output when other valid tiles
  exist.

## Test Requirements

Unit tests:

- Text truncation is byte-safe.
- Menu rendering handles zero records, more than seven records, and the current
  payload order without empty placeholder rows.
- Theme change invalidates tile cache.
- `CMD_MAP_SETTINGS` invalidates tile cache without changing route or viewport.
- `CMD_MAP_ORIENTATION` changes geographic projection without changing route,
  GPS, destination, or nav-step state.
- Invalid heading hides the current-location view cone and leaves a neutral
  blue puck.
- Edge-indicator geometry covers halo intersection, four sides, four corners,
  fixed perimeter length, runtime bounds, and incremental movement.
- Zero-point route clears active route display state.

Emulator tests:

- Build/install on `emery`.
- Capture screenshots for required states.
- Use deterministic fixture screen positions to capture straight-edge,
  near-corner, exact-corner, and recentered current-location states in day and
  night themes.
- Replay mock phone messages for GPS, tiles, destinations, route, nav steps, and
  errors.
- Verify 5x5 tile requests cover the target viewport.

## Acceptance Criteria

- Watch boots with no phone and shows `WAITING_FOR_PHONE`.
- Watch shows setup-required state when the bridge reports missing setup.
- After GPS and visible tiles arrive, the map is nonblank and fully covered on
  `emery`.
- Direction-up GPS-follow mode keeps geographic layers aligned and avoids blank
  rotated corners after requested tiles arrive.
- Destination and travel menus fit on the target screen.
- Route, nav-step, no-route, and error states draw without text overlap.
- UI code derives its geometry at runtime and does not assume a 144x168 screen.
- A fully off-screen current-location halo produces the specified rounded edge
  line, including a connected 90-degree bend when its centered length crosses a
  corner.
