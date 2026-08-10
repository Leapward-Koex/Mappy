# Current Location View Cone Spec

This spec defines the watch current-location glyph: a Google Maps-style blue
location puck with a directional outlined view sector when heading is valid.

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

The glyph must not show stale wearer-facing direction. A neutral puck is
preferable to a misleading cone.

## Layering

Overall map render order follows `WATCH_APP_MVP.md`. Within the
current-location layer:

1. Draw the sector outline when heading is valid.
2. Draw the puck halo.
3. Draw the puck fill.

The sector outline may partially cover the route, but it must not obscure the
entire route line near the user or hide map detail inside the sector. The puck
may cover a small route segment at the exact current location.

## Acceptance Criteria

Visual tests must cover:

- valid watch compass headings 0, 90, 180, and 270 degrees in `north_up`,
- `forward_up` GPS-follow where the watch compass heading drives and is
  compensated by the active map rotation,
- manual pan after `forward_up` GPS-follow where map rotation is suspended,
- invalid compass heading, where only the neutral puck is present,
- day and night themes.

Screenshot or pixel checks should verify:

- the puck contains `#1A73E8` or the closest Pebble palette equivalent near the
  GPS center,
- the halo contains visible white pixels around the puck,
- valid watch compass heading creates a blue 90-degree outlined sector extending
  ahead of the puck,
- map detail remains visible inside the outlined sector,
- invalid compass heading has no sector-colored outline outside the puck radius,
- no stale sector outline remains after receiving an invalid compass update.

The implementation may use renderer-specific approximations, but the visible
result must read as a Google Maps-style blue dot with a forward-facing outlined
90-degree view sector.
