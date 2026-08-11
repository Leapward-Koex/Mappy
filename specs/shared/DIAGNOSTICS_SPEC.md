# Diagnostics Spec

This spec defines local diagnostics for the Mappy MVP. Diagnostics are
for user-initiated troubleshooting, protocol replay, and acceptance-gate
verification. They are never uploaded automatically.

## Design Basis

- Android native owns diagnostic persistence.
- Flutter displays and exports diagnostics.
- Watch emits bounded diagnostic events through `CMD_LOG_EVENT`.
- Diagnostics must be structured, redacted, bounded, and local.

## Event Schema

Each diagnostic event is stored as:

```text
id: monotonic integer
timestamp_wall_ms: epoch milliseconds
timestamp_mono_ms: monotonic milliseconds when available
source: flutter | android_bridge | provider | location | pebble | watch | tile_worker | route_worker
level: debug | info | warn | error
event: stable snake_case event name
message: redacted short text
correlation_id: optional string
command_id: optional integer
error_category: optional integer
watch_detail: optional integer
watch_detail2: optional integer
tile_x: optional integer
tile_y: optional integer
tile_zoom: optional integer
route_origin_id: optional string
route_target_id: optional string
saved_location_slot: optional integer
route_id: optional string
http_status: optional integer
provider: optional google_map_tiles | google_places | google_geocoding | google_routes
provider_error_class: optional string
attempt: optional integer
watch_connected: optional boolean
watch_ready: optional boolean
setup_state: optional string
map_orientation: optional north_up | forward_up
camera_mode: optional gps_follow | manual_browse
auto_rotation_suspended: optional boolean
heading_source: optional watch_compass | phone_course | non_compass_fallback | none
orientation_fallback: optional string
compass_status: optional unavailable | invalid | calibrating | calibrated | stale
heading_reference: optional magnetic | true
motion_state: optional idle | walking | raise_candidate | looking
bearing_reacquire_reason: optional route_start | watch_look
bearing_reacquire_active: optional boolean
```

Implementation may add fields only if they are safe by default and documented in
this spec.

## Event Names

Required event names:

| Event | Source |
| --- | --- |
| `app_started` | flutter/android_bridge |
| `watch_connected` | android_bridge |
| `watch_disconnected` | android_bridge |
| `watch_init_received` | pebble |
| `watch_command_received` | pebble |
| `watch_send_ack` | pebble |
| `watch_send_nack` | pebble |
| `setup_state_changed` | android_bridge |
| `api_key_stored` | android_bridge |
| `api_key_cleared` | android_bridge |
| `provider_validation_started` | provider |
| `provider_validation_finished` | provider |
| `location_permission_changed` | location |
| `location_fix_updated` | location |
| `location_stale` | location |
| `map_orientation_changed` | flutter/android_bridge/watch |
| `motion_walking_detected` | watch |
| `motion_watch_look_detected` | watch |
| `bearing_reacquire_started` | watch |
| `compass_calibration_started` | watch |
| `compass_heading_acquired` | watch |
| `compass_heading_lost` | watch |
| `compass_service_unavailable` | watch |
| `compass_outlier_rejected` | watch |
| `tile_request_received` | tile_worker |
| `tile_response_sent` | tile_worker |
| `tile_response_dropped` | tile_worker |
| `route_request_received` | route_worker |
| `route_provider_result` | route_worker |
| `route_points_sent` | route_worker |
| `nav_steps_sent` | route_worker |
| `error_state_sent` | android_bridge |
| `diagnostics_exported` | flutter |
| `diagnostics_cleared` | flutter |
| `cache_cleared` | flutter/android_bridge |

Watch `CMD_LOG_EVENT` records are mapped into `source = watch` with
`command_id = CMD_LOG_EVENT` and safe numeric fields preserved according to
`PROTOCOL_MVP.md`.

Motion diagnostics record only semantic transitions and the bounded
reacquisition reason. Raw accelerometer axes, sample timestamps, and cadence
traces are prohibited from diagnostic storage and export.

## Ring Buffer

Storage rules:

- Keep a bounded local ring buffer.
- Minimum capacity: 2,000 events.
- Also enforce a serialized size cap of 2 MB.
- When limits are exceeded, drop oldest events first.
- Diagnostics survive app restart unless the user clears them.
- Diagnostics are deleted on app uninstall.

No automatic remote upload, analytics SDK, crash-report upload, or hosted log
collection is part of MVP.

## Redaction

Redact before storing and again before export.

Always redact:

- Full Google API keys.
- Strings matching the stored key exactly.
- `AIza`-shaped key-like strings beyond a short preview.
- Credential-like opaque tokens.
- Bearer tokens.
- Authorization headers.
- Provider session tokens.
- URLs containing `key=`, `token=`, `signature=`, or equivalent query values.
- Precise raw provider request/response bodies unless the test fixture marks
  them safe.

Allowed:

- Redacted key preview from secure storage.
- Safe HTTP status.
- Provider error class.
- Tile x/y/z.
- Route origin ID.
- Route target ID.
- Saved-location slot number when present.
- Command ID.
- Error category.
- Approximate event timestamps.

Location privacy:

- Do not export raw lat/lng by default.
- Export world-pixel x/y only for watch/protocol debugging when the user
  explicitly chooses detailed diagnostics.
- Route geometry is excluded from default export.
- Detailed route/tile debug export may be added later only with explicit user
  consent in the export UI.

## Export Format

Default export is UTF-8 JSON:

```text
{
  "schema_version": 1,
  "created_at": "...",
  "app_package": "...",
  "app_version": "...",
  "watch_uuid": "...",
  "redaction": {
    "full_keys": "redacted",
    "location": "default"
  },
  "status": { ... },
  "events": [ ... ]
}
```

The export filename:

```text
mappy-diagnostics-YYYYMMDD-HHMMSS.json
```

Export is initiated only from the Diagnostics screen. The app may invoke the
Android share sheet after creating the local export, but it must not choose a
remote destination automatically.

## Status Snapshot

Export must include a safe current status snapshot:

- Watch connection and ready state.
- Setup state.
- Provider validation states.
- Location permission/freshness state.
- Redacted key status.
- Saved-location count, not full addresses by default.
- Centered map orientation, camera mode, facing-up heading/fallback status, and
  whether auto-rotation is suspended by manual pan.
- Current queue sizes.
- Last safe error category/text.

Default export must not include full ad-hoc or saved-location addresses unless
the user chooses detailed diagnostics.

## Cache Controls

Diagnostics screen must expose:

- Clear diagnostics.
- Clear tile cache.
- Clear route cache.
- Clear provider validation cache/status.

Key clearing is handled by `SECURE_STORAGE_SPEC.md`, not by diagnostics clear.

Each clear action records a new diagnostic event after completion, except clear
diagnostics may leave only a single `diagnostics_cleared` event.

## Test Requirements

Unit tests:

- Ring buffer drops oldest events by count and size.
- Redactor removes full API keys, opaque credential strings, bearer tokens, and key query
  parameters.
- Export schema includes required metadata and status.
- Default export excludes raw lat/lng, route geometry, full addresses, and full
  API keys.
- Watch log event mapping preserves command ID, event type, and safe numeric
  fields.

Replay tests:

- Tile NACK sequence records attempts and final drop.
- Missing key route request records category 1 and no provider request.
- Invalid provider response records safe HTTP status and category 2.
- No-route response records zero-point route plus category 7.
- Location denied records permission state and category 3.

Static tests:

- No diagnostics code references project-hosted backend endpoints.
- No automatic upload path exists.
- No logging call formats the full key.

## Acceptance Criteria

- Diagnostics are local, bounded, structured, and redacted.
- Flutter can display recent events and export a JSON diagnostics file.
- Export contains enough context to debug protocol failures: command ID, error
  category, tile x/y/z, route origin ID, route target ID, saved-location slot
  when present, safe HTTP status, and timestamps.
- Export contains no full key, access token, session token, credential-like
  secret, or default raw route/location payload.
- User can clear diagnostics and caches separately from clearing the API key.
