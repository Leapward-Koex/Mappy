# Current Location View Cone Spec

This spec defines the watch current-location glyph: a Google Maps-style blue
location puck with a directional outlined view sector when heading is valid,
plus a perimeter line that points to the location after the puck leaves the
screen.

It replaces the underspecified "heading indicator" wording in the watch MVP and
layout specs. It does not change GPS ownership, map orientation, route
rendering, or tile coverage rules.

## Scope

Applies to:

- the Pebble watch map overlay,
- visual and screenshot tests for heading/current-location state.

Does not apply to:

- destination pins,
- route polylines,
- setup/error/menu UI,
- phone-side Flutter map previews.

## Visual Target

The glyph must read as the same control pattern users expect from Google Maps:
a blue current-location dot with a forward-facing outlined view sector.

Required visual parts:

1. Outlined 90-degree view sector, only when heading is valid.
2. White puck halo.
3. Solid blue puck.
4. Rounded blue-and-white edge line when the puck halo is fully off-screen.

The sector outline is drawn below the puck so the dot remains the anchor point.
The glyph must never render as an arrow, compass needle, filled wedge, or
green/teal marker.

## Colors

Use these canonical colors unless a target platform can only approximate them:

| Part | Color |
| --- | --- |
| Puck fill | `#1A73E8` |
| Puck halo | `#FFFFFF` |
| Sector outline halo | `#FFFFFF` |
| Sector outline | `#1A73E8` |
| Edge line halo | `#FFFFFF` |
| Edge line | `#1A73E8` |

The view sector is stroke-only so map detail remains visible inside it. Render a
white under-stroke/halo below the blue sector outline when possible to keep the
outline readable over day and night map palettes. Do not use the existing teal
accent `#19706D` for the current-location puck or sector.

## Geometry

Puck:

- Center: latest projected GPS screen point.
- Outer halo radius: 8 px.
- Blue fill radius: 5 px.
- No inner white center dot; the white region is the outer halo.
- The halo must remain visible over day and night map palettes.

Cone:

- Center/apex: the puck center.
- Direction: active display heading after map-orientation compensation.
- Length from puck center: 28 px target, allowed range 24..32 px.
- Half angle: 45 degrees target for a 90-degree total sector.
- Shape: outlined section of a circle, with two radial edges from the puck
  center and a curved outer arc. The interior must not be filled. If the target
  renderer has no arc primitive, approximate the arc with short line segments.
  A hard, outlined perfect triangle is not acceptable for the final Pebble UI.
- The sector starts at the puck center and may extend under the halo. The puck
  is drawn after the sector so the center remains a crisp blue dot with white
  halo.
- All sector outline drawing is clipped to the map layer bounds.

Off-screen edge line:

- Visibility threshold: keep drawing the puck and cone while any part of the
  circular 8 px white puck halo intersects the screen rectangle. Once the halo
  is completely outside, replace the whole glyph, including any clipped cone,
  with the edge line.
- Eligibility: apply the threshold whenever a valid GPS projection is
  off-screen, regardless of GPS-follow or manual-browse state. No valid GPS
  means no puck, cone, or edge line.
- Anchor: clamp the projected GPS `x/y` to the screen perimeter. Preserve an
  in-range coordinate on a single overflow axis; when both axes overflow, use
  their shared corner.
- Length: one third of the runtime screen width, measured along the perimeter
  and centered on the anchor.
- Corners: continue excess length onto the adjacent edge. A path centered on a
  corner therefore renders as two connected arms forming a 90-degree bend.
- Stroke: use a 4 px white under-stroke and 2 px blue stroke, matching the cone.
  Round both endpoints and every corner joint. Leave a 3 px clear gap between
  the physical screen edge and the white under-stroke by insetting the
  centerline by that gap plus half the white stroke.
- Movement: derive the path directly from the current map projection on every
  redraw. Drag position updates must move it with the map without a separate
  delayed animation or stale cached position.

If antialiasing is unavailable, favor stable geometry and contrast over trying
to simulate curved edges.

## Heading And Orientation

The current-location cone represents the direction the watch wearer is facing.
On watches with compass hardware, the local compass is the authoritative source:
it reflects wrist orientation directly and keeps heading updates available
without waiting for the phone.

Heading source rules:

- Primary source: Pebble `CompassService` magnetic heading from the watch.
- If a magnetic declination value is available from the companion, the watch
  applies it before drawing the cone.
- If declination is unavailable, the watch may draw from raw magnetic heading
  rather than suppressing the cone.
- Phone GPS/course heading from `CMD_GPS.button_id` is not the production source
  for wearer-facing direction or facing-up GPS-follow map rotation. It may be
  used only by non-compass test builds that cannot provide watch compass
  samples.

- Valid heading: draw the sector outline in the active display heading direction
  derived from the watch compass.
- Invalid, unavailable, or stale compass heading: draw only the neutral blue puck
  and no cone.
- `north_up`: display heading is the watch compass heading in screen space.
- `forward_up`: when GPS-follow is active and the wearer-facing compass heading
  is valid, that same heading rotates the map and is compensated out of the cone
  direction, so the cone points toward the top of the screen.
- Manual pan: the puck may be off center, map rotation is suspended, and the
  cone uses north-up screen-space heading until the user recenters.
- The edge line indicates spatial direction to the GPS projection and does not
  depend on heading validity. Once active, it replaces both puck and cone.

The glyph must not show stale wearer-facing direction. A neutral puck is
preferable to a misleading cone.

## Layering

Overall map render order follows `WATCH_APP_MVP.md`. Within the
current-location layer, when the puck halo intersects the screen:

1. Draw the sector outline when heading is valid.
2. Draw the puck halo.
3. Draw the puck fill.

The sector outline may partially cover the route, but it must not obscure the
entire route line near the user or hide map detail inside the sector. The puck
may cover a small route segment at the exact current location.

When the halo is fully off-screen, draw the edge line in the same
current-location layer instead of the three on-screen parts. Existing status,
menu, and modal layering remains unchanged.

## Acceptance Criteria

Visual tests must cover:

- valid watch compass headings 0, 90, 180, and 270 degrees in `north_up`,
- `forward_up` GPS-follow where the watch compass heading drives and is
  compensated by the active map rotation,
- manual pan after `forward_up` GPS-follow where map rotation is suspended,
- invalid compass heading, where only the neutral puck is present,
- projected locations beyond each side and each corner,
- a near-corner position where one-third-width geometry wraps onto the adjacent
  edge,
- day and night themes.

Screenshot or pixel checks should verify:

- the puck contains `#1A73E8` or the closest Pebble palette equivalent near the
  GPS center,
- the halo contains visible white pixels around the puck,
- valid watch compass heading creates a blue 90-degree outlined sector extending
  ahead of the puck,
- map detail remains visible inside the outlined sector,
- invalid compass heading has no sector-colored outline outside the puck radius,
- no stale sector outline remains after receiving an invalid compass update,
- a tangent or partially visible white puck halo does not show an edge line,
- a fully off-screen halo shows a rounded one-third-width blue line with white
  outline at the clamped edge position with a 3 px clear outer gap,
- exact-corner placement forms a connected 90-degree bend with the same total
  path length as a straight-edge placement,
- successive manual-pan frames move the edge path with the projected GPS point.

The implementation may use renderer-specific approximations, but the visible
result must read as a Google Maps-style blue dot with a forward-facing outlined
90-degree view sector on-screen and a clear perimeter locator off-screen.
