# Watch Tile Load Animation Spec

This spec defines how map tiles visually enter the Pebble watch UI after they
have been received, validated, decoded, and committed to the watch tile cache.
It is a watch-rendering behavior only. It does not change `CMD_TILE_REQUEST`,
`CMD_TILE`, tile crop dimensions, RLE format, provider selection, or phone-side
map generation.

## Goals

- Make late-arriving map tiles feel intentional instead of popping in.
- Keep the map usable immediately after each tile decodes.
- Provide a no-motion option for performance, battery, and user preference.
- Keep route lines, current-location marker, heading cone, destination marker,
  status bands, and menus stable while map tiles animate underneath them.

## User Setting

The user-visible setting is `Tile animation`.

| Value | Label | Behavior |
| ---: | --- | --- |
| `0` | No animation | Decoded tiles draw at full opacity and final geometry on the first frame after decode. |
| `1` | Fade in | Decoded tiles draw in their final geometry and fade from the current background or stale-tile context to full visibility. |
| `2` | Fade + zoom | Decoded tiles fade in while scaling from slightly smaller than their final tile footprint into their final position. |

Default value: `1` fade in.

Unknown or unsupported values normalize to `0` no animation. This gives the
watch a deterministic low-cost fallback if a future phone app sends a value the
watch does not understand.

Changing the setting:

- Does not invalidate map tiles.
- Does not re-request visible tiles.
- Applies to future tile arrivals.
- Leaves already completed tiles unchanged.
- Completes any active animation immediately when the new value is `0`.
- Lets active animations finish with the mode they started with when switching
  between `1` and `2`.

## Ownership And Sync

The watch owns animation execution because it owns decoded tile buffers and
render timing. The phone may own the user-facing settings UI and persistence.

The setting sync command is `CMD_TILE_ANIMATION = 206`.

Payload:

| Key | Meaning |
| --- | --- |
| `button_id` | `0` no animation, `1` fade in, `2` fade + zoom |

The phone sends this command after startup and after user-facing settings
changes. The watch may send the same command when a watch-side settings control
changes the value. Do not overload:

- `CMD_TILE_REQUEST`, because animation is not part of provider tile generation.
- `CMD_TILE`, because the same tile payload must render correctly under all
  animation settings.
- `CMD_MAP_SETTINGS`, because that command invalidates provider/source tile
  caches, while tile animation is display-only.

The watch may persist the last applied animation value for fast startup. If no
phone value has been synced yet, the watch uses the default `1` fade in.

## Animation Trigger

A tile animation may start only after all of these are true:

1. A `CMD_TILE` payload has passed tuple, size, coordinate, zoom, and RLE
   validation.
2. The payload has decoded into the cache entry's 54x63 nibble buffer.
3. The cache entry's `world_x`, `world_y`, and `zoom` match the current tile
   request generation for the active viewport/theme.
4. The tile is visible in the current north-up or active facing-up GPS-follow
   tile coverage.
5. The map or navigation surface is visible and no modal/menu fully owns the
   screen.

Do not animate:

- Cache hits that become visible because the user pans back over already decoded
  tiles.
- Tiles that arrive after the viewport, zoom, theme, orientation, or map-source
  generation made them stale.
- Tiles that arrive while the app is backgrounded.
- Tiles decoded while an active touch drag or pinch gesture is in progress. Draw
  those at final state, then let newly requested tiles animate after liftoff.

A decoded tile counts as valid immediately, even while its visual animation is
still running. Tile animation must not keep the app in `MAP_LOADING` longer than
the tile pipeline otherwise would.

## Rendering Model

The map layer render order is:

1. Base map background, plus any allowed narrow edge dithering where a missing
  cell touches a current/stale tile.
2. Valid cached map tiles, with per-tile animation applied when active.
3. Route polyline.
4. Destination marker.
5. Current-location puck and heading cone.
6. Top/bottom status bands.
7. Modal/menu overlay.

Tile animation affects only the tile pixels. It must not move, scale, fade, or
otherwise alter geographic overlays or UI chrome.

The renderer must clip every animated tile to the screen and to the tile's final
geographic footprint. In facing-up GPS-follow mode, the final footprint is the
rotated tile quadrilateral produced by the same centered-map orientation
transform used for ordinary tile drawing.

## Fade In

Fade timing:

```text
duration_ms = 180
progress = clamp((now_ms - started_ms) / duration_ms, 0, 1)
eased = 1 - (1 - progress)^3
```

The tile remains in its final screen position for the whole animation.

Because Pebble rendering does not provide full per-layer alpha, the fade may be
implemented with either:

- palette blending from the current background or stale-tile context toward the
  tile color, or
- an ordered dither reveal of tile pixels over the current background or
  stale-tile context.

The final animation frame must draw the exact decoded tile colors. Intermediate
frames must have at least four visually distinct visibility steps on color
hardware.

## Fade + Zoom Into Place

Fade + zoom timing:

```text
duration_ms = 220
progress = clamp((now_ms - started_ms) / duration_ms, 0, 1)
eased = 1 - (1 - progress)^3
scale = 0.92 + 0.08 * eased
opacity = eased
```

The tile scales around the center of its final 54x63 crop. At `progress = 0`,
the tile is 92 percent of its final size and centered within the final
footprint. At `progress = 1`, the tile is full size, fully opaque, and
pixel-identical to no-animation rendering.

The current background or stale tile remains visible behind the scaled tile so
the map never exposes blank holes around the animating tile. The zoom must be
nearest-neighbor; smoothing or interpolation is not required.

In facing-up GPS-follow mode, the scale applies in tile-local/world space before
the existing orientation transform. This keeps the tile zooming into its own
rotated footprint instead of into an unrelated screen-axis rectangle.

## Frame Scheduling

The watch schedules redraws only while at least one visible tile animation is
active.

Rules:

- Target redraw cadence is 20 to 30 frames per second.
- Skipping frames is allowed when the watch is busy.
- Extending the animation beyond 300 ms is not allowed; complete the animation
  instead.
- The map layer must be marked dirty after each animation tick.
- Timers must stop when no active animations remain or when the app leaves the
  foreground.

## Cancellation And State Changes

Complete active animations immediately when:

- The user changes zoom.
- Theme changes.
- `CMD_MAP_SETTINGS` invalidates the tile cache.
- Centered map orientation changes while GPS-follow is active.
- Recenter reapplies a facing-up centered-map orientation after manual browse.
- The tile is evicted or replaced.
- The tile is no longer part of the current visible coverage.
- A modal/menu becomes the active full-screen surface.

During normal GPS-follow movement, active animations continue and use the latest
viewport transform each frame. The tile moves with the map exactly as an
already-decoded tile would.

## Memory And Performance

The MVP implementation must not allocate a second full decoded tile buffer per
active animation. Animation state should fit in cache metadata, for example:

```text
animation_mode
animation_started_ms
animation_active
```

If fade implementation needs a background, use the existing base-background and
edge-dither draw pass, a single scratch row, or deterministic dithering. Do not
add 1,701 bytes of extra storage for every active tile unless a measured heap
budget amendment updates this spec.

If emulator or hardware profiling shows that the selected animation mode cannot
keep the map responsive, the watch may degrade for that burst:

1. Fade + zoom degrades to fade in.
2. Fade in degrades to no animation.

The persisted user setting remains unchanged. A degraded burst should emit a
bounded diagnostic event if diagnostics are enabled.

## Test Requirements

Unit tests:

- Setting values `0`, `1`, and `2` normalize to the expected modes.
- Unknown values normalize to no animation.
- Changing the setting does not invalidate or re-request tiles.
- Animation starts only after successful `CMD_TILE` decode and visible-coverage
  match.
- Stale tile payloads never start an animation.
- Fade and fade + zoom progress reach exact final state at or before their
  specified durations.
- Disabling animation completes active animations immediately.

Emulator/screenshot tests on `emery`:

- No animation: a decoded visible tile appears at final position and full
  visibility on the next draw.
- Fade in: early, middle, and final frames show increasing tile visibility with
  no route/current-location/status movement.
- Fade + zoom: early frame shows the tile smaller than its final footprint,
  middle frame shows it larger and more visible, final frame matches ordinary
  tile rendering.
- A burst of visible tile arrivals does not produce a fully blank screen.
- Direction-up GPS-follow mode keeps fade + zoom tiles aligned with rotated tile
  coverage.

## Acceptance Criteria

- All three user-visible settings exist: no animation, fade in, and fade + zoom.
- Tile animation is purely watch-side and does not change map tile payloads.
- A tile is considered loaded as soon as it decodes successfully, even if its
  animation is still running.
- Final animation frames are pixel-identical to no-animation tile rendering.
- Route, marker, heading cone, text bands, and menus remain stable over animated
  tiles.
- Active animations are cancelled or completed cleanly across zoom, theme, map
  settings, orientation, cache eviction, app backgrounding, and modal/menu state
  changes.
