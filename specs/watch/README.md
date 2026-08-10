# Watch Specs

## Specs

- `WATCH_APP_MVP.md`: Pebble Time 2 native watch behavior for the backend-free
  MVP.
- `WATCH_UI_LAYOUT_SPEC.md`: `emery` layout, map/menu/state rendering, text
  clipping, and screenshot verification rules.
- `CURRENT_LOCATION_VIEW_CONE_SPEC.md`: Google Maps-style blue current-location
  puck and heading cone rendering requirements.
- `ROUTE_CONSUMED_OVERLAY_SPEC.md`: Google Maps-style route consumption where
  dots/line behind the current on-route GPS position are hidden and can reappear
  when the wearer retraces the route.
- `TURN_HAPTIC_ALERT_SPEC.md`: Google Maps-style two-stage turn vibration cues
  before and at upcoming maneuvers.
- `WATCH_TOUCH_INPUT_SPEC.md`: real-watch touch panning, no-pinch fallback, and
  future pinch zoom behavior for `PBL_TOUCH` platforms.
- `WATCH_TILE_LOAD_ANIMATION_SPEC.md`: no-animation, fade-in, and fade + zoom
  tile arrival behavior after decoded map tiles load on the watch.
- `PEBBLE_EMULATOR_FIXTURE_MODE_SPEC.md`: opt-in emulator fixture build mode
  that bundles generated map/route payloads instead of using the real phone
  runtime.
