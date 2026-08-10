# Turn Haptic Alert Spec

## Purpose

The watch must provide Google Maps-style haptic cues around upcoming navigation
maneuvers. The wearer should get a subtle advance cue before a maneuver and a
stronger cue when the maneuver is due, without adding phone round-trips or
vibrating repeatedly because of GPS jitter. The same local route-projection
model also owns destination-arrival feedback so the trip can finish without a
phone round-trip.

## Inputs

This feature uses existing route and nav-step data:

- `CMD_ROUTE_POINTS` route point order is the forward route direction.
- `CMD_NAV_STEPS` provides up to three local step records with:
  - `global_idx`
  - `start_world_x`
  - `start_world_y`
  - `remaining_m`
  - `remaining_s`
  - `instruction`
- GPS progress is computed by projecting the current fix onto the overview route.

No new protocol fields are required for MVP turn haptics or arrival feedback.

## Alert Stages

The watch supports two haptic stages per maneuver, plus one route-completion
stage:

| Stage | Intent | Pattern |
| --- | --- | --- |
| Preview | The next maneuver is close enough that the wearer should prepare. | Two short pulses. |
| Now | The maneuver is due now or within the final approach window. | Stronger multi-pulse pattern. |
| Arrival | The wearer is at or very close to the destination. | Distinct multi-pulse completion pattern. |

The patterns must be short and nonblocking. They must not prevent rendering,
AppMessage handling, or route progress updates.

## Thresholds

Thresholds are travel-mode specific because useful warning distance depends on
expected speed:

| Mode | Preview distance | Now distance |
| --- | ---: | ---: |
| Walk | 50 m | 12 m |
| Bike | 80 m | 25 m |
| Drive | 250 m | 60 m |

If reliable step-meter scaling is unavailable, the watch may use conservative
route-pixel fallbacks. The fallback must prefer missed/late haptics over noisy
early haptics.

## Maneuver Selection

The alert target is the first non-final nav step whose projected start position
is ahead of the current route progress or within the final "now" window behind
the current progress.

Rules:

- Do not alert for the route-start step.
- Do not fire preview/now turn alerts for the final arrival step; destination
  arrival is handled by the arrival flow below.
- Do not alert when there is no active route, no nav-step chunk, stale GPS, or an
  off-route projection.
- Do not alert from a route-detail window; use the overview route and overview
  nav-step starts so alert timing is stable.
- If the next maneuver is unavailable because the phone has not delivered the
  next nav-step chunk yet, do not guess. Requesting later chunks remains governed
  by `WATCH_APP_MVP.md`.

## Repeat Suppression

Each haptic stage is one-shot per nav-step `global_idx`:

- Once preview has fired for a maneuver, it must not fire again for that
  maneuver.
- Once now has fired for a maneuver, preview is considered satisfied and must not
  fire later for that maneuver.
- Walking backward or GPS jitter must not repeat either stage.
- Starting a new route, clearing the route, or replacing route points resets all
  turn-alert state.

The watch already maintains monotonic nav progress for instruction progression;
turn haptics must respect that same monotonicity for repeat suppression.

## User Experience

The cue should feel useful but quiet:

- The preview cue should be noticeable without feeling urgent.
- The now cue should be clearly stronger than preview.
- Cues should be suppressed while off-route rather than vibrating with low
  confidence.
- The current instruction text remains unchanged by the vibration.
- Route-start walking vibration remains separate from turn haptics.

## Destination Arrival

The watch must detect destination arrival locally from the active overview route
and fresh GPS projection. Arrival is satisfied when the projected remaining
route distance or direct destination distance is within 20 meters, with a
conservative route-pixel fallback when meter scaling is unavailable.

On arrival:

- Fire one distinct arrival vibration.
- Finish the active trip locally by clearing route geometry, nav steps, route
  progress, route-detail windows, and pending nav-step requests.
- Queue or send `CMD_ROUTE_CLEAR` to the phone so the companion clears its active
  route cache.
- Show a modal watch dialog with `Arrived` and `You arrived`.
- Any hardware button press dismisses the dialog and returns to the normal map.

Arrival must not fire while the GPS projection is stale or off-route. Clearing
or replacing the route resets arrival state. The arrival dialog is local UI; it
does not require a new protocol command.

## Debug Verification

Debug tooling should expose observable counts for preview and now vibrations.
Moving debug GPS along a route must be enough to test:

- preview fires once before a turn,
- now fires once near the turn,
- moving backward does not repeat either alert,
- moving forward to the next maneuver allows alerts for the next `global_idx`.
- moving debug GPS to the destination fires one arrival vibration, clears the
  active route, and shows the arrival dialog until any button press.

## Acceptance

- Given a walking route with a maneuver 100 m ahead, moving simulated GPS to
  50 m before the maneuver fires one preview cue.
- Moving simulated GPS to 12 m before the same maneuver fires one now cue.
- Repeating the same GPS positions or moving backward across the thresholds does
  not add more cues.
- Clearing/replacing the route resets alert state for the new route.
- Moving GPS within 20 m of the destination fires one arrival cue, clears the
  trip, sends or queues `CMD_ROUTE_CLEAR`, and shows an `Arrived` dialog.
- Pressing any hardware button dismisses the arrival dialog and leaves the map
  visible.
- Pebble build succeeds with the custom haptic patterns.
