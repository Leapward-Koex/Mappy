# Route Consumed Overlay Spec

This spec defines the Google Maps-style route overlay behavior where already
covered route geometry is hidden while navigation is active.

## Scope

Applies to:

- the native Pebble watch renderer,
- emulator/debug tooling used to verify route progress visually.

The route payload itself remains immutable until a route clear or update.
This feature changes only which portion of the active route is drawn.

## Direction Model

The hidden route direction is the order of points in `CMD_ROUTE_POINTS` and
`CMD_ROUTE_WINDOW_POINTS`:

- point `0` is the route start,
- the last point is the route destination,
- increasing point indexes are forward travel direction.

The watch must not infer direction from compass heading, phone bearing, screen
orientation, or current viewport. Facing-up rotation and manual panning change
only projection; they do not change route direction.

## Visual Progress

The watch maintains a route visual progress concept separate from nav-step
progress.

- Nav-step progress is monotonic and must not move backward.
- Visual progress follows the current GPS projection and may move backward.
- Moving backward along the route reveals route dots/line that were previously
hidden at that location.
- Route geometry is not removed from memory when it is visually hidden.

To compute visual progress, project the current fresh GPS point onto the active
drawn route geometry and choose the nearest segment. The cumulative distance from
the start of that displayed route geometry to the projection is the visual
cutoff.

If there is no fresh GPS fix, no active route, fewer than two route points, or
the GPS projection is too far from the route to be considered on-route, the
renderer may draw the full route rather than guessing consumed geometry.

## Rendering

The renderer draws only geometry ahead of the visual cutoff.

Walking routes:

- Route points are rendered as spaced blue dots with a white halo.
- A dot whose route-distance position is less than or equal to the visual cutoff
  is not drawn.
- Dots after the cutoff are drawn at the same spacing they would have used on the
  full route.

Bike and drive routes:

- The continuous route line is clipped at the visual cutoff.
- Segments fully before the cutoff are not drawn.
- The segment containing the cutoff is drawn from the cutoff point to the segment
  end.
- Segments after the cutoff are drawn normally.

The destination marker is not consumed; it remains visible while an active route
exists.

## Route Detail Windows

At high zoom, the watch may draw a route-detail window instead of the overview
polyline. The consumed overlay rule applies to whichever route geometry is being
drawn:

- If a detail window covers the current viewport and has at least two points, the
  visual cutoff is computed against the detail-window geometry.
- Otherwise the cutoff is computed against the overview geometry.

The whole-route overview remains the stable route state for destination display,
nav-step matching, off-route checks, and fallback rendering.

## Debug Controls

The Pebble emulator must support a debug route-position command, matching the
existing debug compass command style.

Debug command:

```text
CMD_DEBUG_ROUTE_PROGRESS = 903
button_id = progress permille, 0..1000
```

When received, the watch projects the permille value onto the active overview
route, moves its debug GPS fix to that route position, marks the fix fresh, and
then runs the normal GPS update path. Values below 0 clamp to 0; values above
1000 clamp to 1000. If no active route exists, the command is ignored and may log
a diagnostic.

The repo emulator helper should expose:

```sh
bash tooling/pebble-emulator-codex.sh debug-route-progress 0
bash tooling/pebble-emulator-codex.sh debug-route-progress 50
bash tooling/pebble-emulator-codex.sh debug-route-progress 100
```

Development tooling may provide a route progress control that moves a debug GPS
fix along the active route without calling a provider. This control exists only
to inspect route consumption and backward revealing behavior.

## Acceptance

- Walking forward along a walking route removes dots at and behind the current
  projected GPS position.
- Moving the simulated GPS backward along the same route reveals dots that were
  previously hidden.
- Bike and drive routes hide the line behind the current projected GPS position
  and reveal it when moving backward.
- Route clears and route updates still clear or update the whole route state.
- Off-route or stale-location states must not permanently delete route geometry.
