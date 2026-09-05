# Map Tile Pipeline MVP Spec

This spec defines Mappy's MVP map underlay pipeline: a backend-free,
user-keyed phone implementation that produces compact watch raster crops.

## MVP Decision

The watch does not fetch, decode, or style provider map data. The phone generates
small raster crops and sends compact palette-index payloads to the watch.

MVP uses these wire and rendering choices:

- 54x63 as the default watch tile crop size.
- 16-entry day palette.
- 4-bit palette indexes packed two pixels per decoded byte.
- Adaptive RLE, packed4, LZ4-packed4 and LZ4-RLE payloads.
- RLE uses high-nibble run length and low-nibble palette index.

Provider constraints:

- No project-hosted application backend is used.
- Only documented, authenticated provider URLs are part of the contract.
- The user supplies a Google API key on the phone.
- The phone-side map provider adapter must use approved Google APIs or another
  later documented provider adapter.
- The Google API key is never sent to the watch.

## Ownership

| Component | Responsibility |
| --- | --- |
| Watch | Tracks viewport/zoom/orientation, requests visible tile crops, decodes RLE, caches the visible crop grid, renders pixels. |
| Phone worker | Owns Google API key access, source map fetching/rendering, crop generation, recolor, palette quantization, RLE packing, send queue, source cache. |
| Flutter companion | Owns API-key entry/status UX, provider settings, and Android-native phone worker configuration. |
| PKJS bridge | Comment-only no-op for MVP; it must not perform credentialed map work. |

MVP phone worker ownership is the Android native integration inside the Flutter
companion. Bundled PKJS must be a comment-only no-op. Exactly one phone worker
must respond to `CMD_TILE_REQUEST` at runtime. This is the same no-responder rule
documented in `../companion-js/COMPANION_JS_MVP.md`.

## Provider Requirements

MVP uses Google Map Tiles API 2D tiles as the first provider adapter. The
default map source is roadmap, but the phone provider adapter must support
user-selectable map source settings for roadmap, satellite, hybrid, and terrain
where the user's key and the provider endpoint allow them.

Session creation must be driven by a persisted phone-side map tile settings
model:

```text
map_source = roadmap | satellite | hybrid | terrain
watch_tile_width = preset pixel width, default 54
watch_tile_height = preset pixel height, default 63
```

The Mappy companion app must expose `watch_tile_width` and
`watch_tile_height` as a single rendered tile size dropdown backed by supported
preset pairs. The default is `54x63`. Recommended larger presets are
`72x84` and `108x126` so the watch can trade fewer tile requests for more data
per tile.

Map source and rendered tile geometry remain phone-owned settings. Rendered tile
geometry must be synchronized to the watch through `CMD_MAP_SETTINGS` and echoed
on `CMD_TILE`, because it changes grid math, decode buffers, payload sizing, and
tile-cache keys. Provider requests use the fixed compact source profile
(`scaleFactor1x`, `highDpi = false`), omit `imageFormat` so Google chooses the
response format automatically, and encode watch tiles with nearest-palette
quantization. Other format changes such as RGB565, 8-bit indexed payloads, or
alternate provider source profiles still require a separate protocol update in
`PROTOCOL_MVP.md` before implementation.

Google Map Tiles `createSession` values:

```text
POST https://tile.googleapis.com/v1/createSession?key=USER_API_KEY
  headers include:
    X-Android-Package = runtime Android package name
    X-Android-Cert    = active signing cert SHA-1 as 40 hex chars, no delimiters
  body includes, by setting:
    roadmap:
      mapType = "roadmap"
    satellite:
      mapType = "satellite"
    hybrid:
      mapType = "satellite"
      layerTypes = ["layerRoadmap"]
      overlay = false
    terrain:
      mapType = "terrain"
      layerTypes = ["layerRoadmap"]

  common body fields:
    language = configured language, default "en-US"
    region = configured region, default from device locale or "US"
    scale = "scaleFactor1x"
    highDpi = false
    imageFormat is omitted

GET https://tile.googleapis.com/v1/2dtiles/{z}/{x}/{y}?session=SESSION_TOKEN&key=USER_API_KEY
  headers include the same X-Android-Package and X-Android-Cert values
```

Rendered watch tile size dropdown:

| UI value | Tile width | Tile height | Expected effect |
| --- | ---: | ---: | --- |
| `54x63` | 54 | 63 | Compact baseline; highest request count, lowest per-tile payload cost |
| `72x84` | 72 | 84 | Fewer visible-grid requests with moderately larger payloads |
| `108x126` | 108 | 126 | Significantly fewer requests; multi-chunk `CMD_TILE` delivery is expected |

The provider may change returned dimensions. The implementation must use
`tileWidth` and `tileHeight` from the session response instead of assuming
physical 256x256 source images. Web Mercator math remains based on 256 logical
world pixels per source tile; source image sampling maps logical pixel
coordinates through:

```text
source_pixel_x = floor(logical_source_x * tileWidth / 256)
source_pixel_y = floor(logical_source_y * tileHeight / 256)
```

Omitting `imageFormat` from the session request uses the provider-selected
response format. Google Map Tiles API does not expose an arbitrary JPEG quality
number; the app must not pretend it can set one.

Provider reference docs:

- Google Map Tiles API overview:
  `https://developers.google.com/maps/documentation/tile`
- Google roadmap tile requests:
  `https://developers.google.com/maps/documentation/tile/roadmap`
- Google satellite tile requests:
  `https://developers.google.com/maps/documentation/tile/satellite`
- Google terrain tile requests:
  `https://developers.google.com/maps/documentation/tile/terrain`
- Google session tokens:
  `https://developers.google.com/maps/documentation/tile/session_tokens`

Before implementing against a Google endpoint, the implementation must verify:

- The endpoint is allowed for this use case under the user's API key and the
  provider terms.
- Correct Android package/cert headers are accepted, and intentionally wrong
  package/cert headers are rejected for the user's restricted key. If wrong
  headers are accepted, the Google Map Tiles adapter is not MVP-safe for the
  backend-free app.
- The session response reports nonzero `tileWidth` and `tileHeight`; all crop
  sampling uses those returned dimensions.
- The phone can legally and technically read pixels from the fetched/rendered
  map image for palette conversion.
- The provider's attribution requirements can be satisfied in the watch/mobile
  UX.
- Rate limits, quotas, and billing failures produce visible degraded states.

The map source adapter must expose this interface to the tile generator:

```text
loadSourceTile(zoom, source_tile_x, source_tile_y, map_source_settings)
  -> raster image or pixel buffer covering exactly one provider source tile
```

The adapter may internally use provider raster tiles, static map images, a
native map renderer, or another approved phone-local rendering path. The rest of
the watch protocol does not change as long as the tile generator can read pixels.
For MVP, any provider other than Google Map Tiles API requires a provider
specific spec before implementation.

## Coordinate Model

Mappy uses Web Mercator world pixels:

```text
world_x = round(((lng + 180) / 360) * 2^zoom * 256)
world_y = round(((1 - ln(tan(lat_rad) + sec(lat_rad)) / pi) / 2) * 2^zoom * 256)
```

Rules:

- GPS messages use zoom 16 world pixels.
- Tile requests carry the crop's top-left world pixel, not a center.
- The phone maps a requested crop to one to four provider source tiles.
- Source tile x wraps at `2^zoom`; source tile y is clamped/rejected by provider
  bounds.

## Watch Tile Grid

The watch maintains a visible grid of rendered crops using the active
`watch_tile_width` and `watch_tile_height` most recently received from
`CMD_MAP_SETTINGS`.

Grid sizing is derived from screen size and the active crop geometry:

```text
tile_width = active rendered tile width, default 54
tile_height = active rendered tile height, default 63

grid_cols = ceil(screen_width / tile_width) + 1
grid_rows = ceil(screen_height / tile_height) + 1
visible_cache_entries = grid_cols * grid_rows
packed_tile_bytes = ceil(tile_width * tile_height / 2)
compressed_arena_bytes = 47104
decode_scratch_bytes = 6804
tile_request_queue_len >= visible_cache_entries
```

For the MVP `emery` baseline at `54x63`, this evaluates to `5 x 5`, `25`
visible entries, and `1701` packed bytes for one decoded tile. Cached imagery
is not held as 25 decoded buffers. It is stored in a fixed 46 KiB compressed
arena, with one 6,804-byte scratch buffer sized for the largest supported tile.
Larger rendered tiles reduce `grid_cols` and `grid_rows`, but increase both the
packed fallback size and typical encoded bytes per response.

Each valid entry stores the smaller of:

- the existing RLE payload plus bounded random-access checkpoints every 32
  source pixels, or
- the lossless packed 4-bit palette pixels when indexed RLE is not smaller.

Arena segments are contiguous and compact after eviction. Storage pressure
prefers offscreen/LRU entries, then retained source-zoom fallback imagery
(already-covered fallback first), before considering a current visible tile.
If pressure remains, an incoming tile may replace only a current tile farther
from the viewport center; a fringe arrival cannot punch a more central hole.
A visible entry evicted only for unavoidable byte pressure is suppressed from
re-request until it leaves the viewport, preventing a request/eviction loop for
high-entropy imagery.

The grid origin is computed from the viewport:

```text
left_col = floor((viewport_world_x - screen_center_x / scale) / tile_width)
top_row  = floor((viewport_world_y - screen_center_y / scale) / tile_height)

for row in top_row..top_row + grid_rows - 1:
  for col in left_col..left_col + grid_cols - 1:
    request world_x = col * tile_width
    request world_y = row * tile_height
```

Basalt-compatible experiments may use a measured 3x3 grid, but MVP `emery`
implementation must not rely on 144x168 screen assumptions.

The extra row and column are intentional. Because `left_col` and `top_row` are
floored to active crop cells, the first visible crop can start almost one full
tile before the viewport edge. `ceil(screen_dimension / tile_dimension)` alone
therefore cannot guarantee full coverage in the worst case.

This derived north-up grid is the baseline. With the default `54x63` preset it
is `5x5`. Direction-up GPS-follow orientation computes coverage from the
inverse-rotated viewport footprint and may require more crop origins, as
specified by `MAP_ORIENTATION_SETTING_SPEC.md`. Manual-browse mode uses the
north-up grid even when the stored centered-map preference is face-forward.

The watch must suppress duplicate requests already present in:

- the valid compressed tile cache, or
- the outbound request queue, or
- the two-entry active-response window.

The request queue must either hold at least `grid_cols * grid_rows` entries, or
the watch must run a refill scheduler after each send/timeout so all visible
tiles are eventually requested. The default `54x63` preset therefore uses a
25-entry request queue; other presets must still satisfy
`tile_request_queue_len >= visible_cache_entries`.

The watch may display stale prior tiles while replacements are loading.

Queued coordinates do not reserve cache entries and do not start their response
timeout. Cache allocation happens only after a complete current response has
validated. Tile loading pauses during touch interaction and resumes after a
100 ms post-liftoff grace period; AppMessage callbacks for obsolete responses
must not decode, store, or dirty the map.

Accepted visible tiles share a non-sliding 60 ms redraw window; the first tile
on an empty map and completion of the visible grid may flush immediately. On
Emery hardware, accepted input must reach a changed frame within 100 ms at p95
with no interaction stall above 150 ms. North-up map draws must remain at or
below 50 ms, facing-up draws at or below 100 ms, and a healthy deterministic
cold load must complete within five seconds.

Zoom transitions must preserve the previously visible compressed tiles as
transient coverage instead of immediately unloading or blanking them. While the
zoom level is changing, the watch renders that prior tile set with the same
nearest-neighbor scale factor as the active zoom motion so the map appears to
grow or shrink smoothly. The watch requests replacement tiles for the committed
visible grid in parallel and swaps each replacement tile into its final
footprint as soon as that tile decodes and validates for the current x/y/zoom.

Outside this transient zoom path, the watch must not draw a cache entry whose
x/y/zoom no longer matches the visible grid.

## Phone Crop Generation

For each `CMD_TILE_REQUEST`:

1. Build a request key from `world_x,world_y,zoom,watch_tile_width,watch_tile_height`.
2. Share duplicate in-flight work using generation-aware consumer leases.
3. Compute the source tile containing the crop's top-left pixel:

```text
source_tx = floor(world_x / 256)
source_ty = floor(world_y / 256)
offset_x = world_x - source_tx * 256
offset_y = world_y - source_ty * 256
```

4. Determine whether the requested watch crop crosses source tile boundaries:

```text
crosses_x = offset_x + watch_tile_width > 256
crosses_y = offset_y + watch_tile_height > 256
```

5. Submit all required source tiles to a dedicated four-worker executor before
   waiting. Share download, one session renewal/retry, and decode jobs across
   crops using captured credential generation and map settings.
6. Composite the source tiles into a `watch_tile_width x watch_tile_height`
  pixel buffer so `(offset_x,offset_y)` maps to crop pixel `(0,0)`.
7. Resample from the returned source pixel dimensions when high-DPI tiles are
   in use.
8. Apply the fixed day preprocessing with exact lookup tables: slight darkening,
   saturation boost, gamma, Pebble 2-bit channels, and nearest day-palette entry.
9. Generate RLE and packed4 representations. Choose the watch storage layout
   first, then the smallest compatible wire encoding described below.
10. Reject output exceeding the bounded protocol limits.
11. Queue one logical `CMD_TILE` response, split into ordered chunks when the
  encoded tile does not fit in one AppMessage.

The send queue treats that logical response as an atomic group. It validates
consistent metadata and exact contiguous payload coverage before enqueueing,
keeps sibling chunks ordered, and waits 30 ms after the final chunk ACK before
starting another tile response. GPS and control delivery bypass this tile-only
cooldown.

The phone should maintain:

- a Map Tiles session cache keyed by API key hash, language, region, map source,
  layer types, overlay flag, scale, and high-DPI flag,
- a source tile cache keyed by provider, zoom, source tile x/y, and map source,
- an encoded watch tile cache keyed by world x/y/zoom, map source, and
  rendered tile width/height,
- an 8 MiB LRU of immutable decoded IntArray pixels, charged by array bytes,
- shared in-flight source and encoded jobs with cancellation leases,
- bounded cache sizes to avoid unbounded memory in the phone worker.

Changing map source or rendered tile size must:

- clear provider sessions affected by the change,
- clear source and encoded tile caches affected by the change,
- cancel or ignore stale in-flight tile work,
- notify the watch to invalidate visible tile cache entries and request fresh
  visible crops as specified in `PROTOCOL_MVP.md`.

## Fixed Day Palette

Phone and watch use one fixed 16-entry palette, with this wire ordering:

```text
FF FB EB EA E6 D5 C0 DF CB C7 EE DE FE FC F8 E9
```

Night/auto modes, theme settings and theme protocol messages do not exist in v4.
Unused stored theme values are ignored. Day conversion lookup tables reproduce
all original RGB rounding and nearest-palette tie-breaking exactly.

## Adaptive Wire Compression

Each tile chunk carries mandatory `compression_format`:

| Value | Payload |
| ---: | --- |
| 1 | Nibble RLE |
| 2 | Packed4, even pixel in low nibble |
| 3 | Raw LZ4 block of packed4 |
| 4 | Raw LZ4 block of nibble RLE |

The Android encoder uses `at.yawk.lz4:lz4-java:1.11.2`,
`LZ4Factory.safeInstance().fastCompressor()`, with no JNI or LZ4 frame wrapper.
If RLE bytes plus the current row/checkpoint index are smaller than packed4,
compare formats 1 and 4. Otherwise compare 1, 2 and 3. Choose the shortest;
prefer raw over LZ4, then packed4 over RLE on ties. This preserves cache layout
and never transmits more payload bytes than the original RLE encoding.

The watch incrementally decodes into its existing 6,804-byte maximum scratch.
LZ4 references earlier output, including overlapping copies. Format 3 must
produce exactly the geometry's packed byte count. Format 4 is bounded by
`packedBytes - indexBytes - 1`; its index builder verifies the exact pixel
count and appends the current index to the scratch buffer. No second tile
buffer, external LZ4 dictionary, or decompressed-size wire key is used.
Missing/unknown/changing formats, invalid offsets, truncated tokens and output
overflow are rejected before tile cache allocation.

## RLE Payload

For format 1 (and the decompressed body of format 4), each byte stores:

```text
packed_byte = ((run_length - 1) << 4) | palette_index
```

Rules:

- `palette_index` is 0..15.
- `run_length` is 1..16.
- Pixels are encoded row-major, `watch_tile_width` pixels per row,
  `watch_tile_height` rows.
- Payload ends after `watch_tile_width * watch_tile_height` pixels have been
  represented.
- Worst-case packed size is `watch_tile_width * watch_tile_height` bytes, one
  one-pixel run per source pixel.
- The default `54x63` tile still has a `3,402` byte worst case and typically
  fits in one `CMD_TILE` AppMessage. Larger configured tiles may require
  chunked `CMD_TILE` delivery as defined in `PROTOCOL_MVP.md`.
- Watch AppMessage inbox size must be configured to at least 4,096 bytes before
  tile implementation lands.
- The full AppMessage dictionary size, including tuple overhead and a tile
  chunk sized to fit the negotiated inbox/outbox limits, must be tested before
  shipping. Any preset whose worst-case tile payload exceeds one message must
  pass chunk reassembly tests.
- Phone-side sender should treat any tile payload larger than
  `watch_tile_width * watch_tile_height` bytes, or any mismatched chunk coverage
  against `total_bytes`, as an encoder bug and drop it with a diagnostic error.
- If Pebble transport reports three NACK callbacks for a tile or one of its
  chunks, phone marks that tile request failed, sends a smaller
  `CMD_ERROR_STATE` category 5 with echoed tile coordinates when transport
  allows, and leaves the watch to show stale/blank tile content.

Watch decode output:

```text
decoded_bytes = 1701
even pixel index -> low nibble
odd pixel index  -> high nibble
```

## AppMessage Flow

Watch request:

```text
CMD_TILE_REQUEST
  world_x = world_x
  world_y = world_y
  tile_zoom       = zoom
```

Viewport changes may come from GPS-follow, button zoom, touch panning, pinch
zoom on future `PBL_TOUCH` platforms with reliable pinch data, or facing-up
GPS-follow orientation as defined by `MAP_ORIENTATION_SETTING_SPEC.md`. The
phone treats all resulting
`CMD_TILE_REQUEST` messages identically and must not add a touch-specific or
orientation-specific tile/provider path.

Phone response:

```text
CMD_TILE
  world_x = world_x
  world_y = world_y
  tile_zoom       = zoom
  compression_format = 1 | 2 | 3 | 4
  total_bytes     = full transmitted payload byte count
  chunk_data      = contiguous payload chunk
  chunk_index     = zero-based chunk number
  chunk_offset    = byte offset in transmitted payload
  request_id      = echoed positive request ID
```

Failure response:

```text
CMD_ERROR_STATE
  button_id    = 1 missing key,
                 2 invalid key/API disabled/quota/billing/permission denied,
                 4 network unavailable, or 5 tile provider failure
  chunk_index  = CMD_TILE_REQUEST
  world_x = failed world_x
  world_y = failed world_y
  tile_zoom       = failed zoom
  instruction  = short user-facing status
```

The phone should not send repeated identical tile error messages more than once
per visible-grid refresh unless the error category changes.

## Watch Rendering

The watch renderer:

1. Uses the fixed day palette.
2. Iterates valid cache entries.
3. Computes screen-space bounds from cache x/y/zoom and viewport state.
4. Clips rows/columns to SDK layer/framebuffer bounds.
5. For north-up drawing, decodes one tile at a time into the shared scratch
   buffer and reads palette indexes from its nibbles. For rotated drawing,
   samples packed storage directly or uses the RLE checkpoints to bound each
   compressed lookup.
6. Writes GColor8 values into the framebuffer row.
7. Draws route, marker, heading, and UI overlays after the map underlay.

When facing-up GPS-follow orientation is active, the watch computes tile
coverage from the inverse-rotated viewport footprint and renders geographic
layers through the shared orientation transform. When manual-browse mode is
active, the watch returns to north-up coverage until recenter. The phone still
receives only ordinary world x/y/zoom `CMD_TILE_REQUEST` messages.

The watch must support:

- non-scaled 1:1 drawing for normal map motion,
- nearest-neighbor scaled drawing of the previously visible tile set during
  zoom transitions until committed-zoom replacements arrive,
- blank/stale placeholders when a requested tile is not yet available.

## API Key And Privacy

- The watch never receives the Google API key.
- The phone must not log the full API key.
- Exported diagnostics must redact any API key-like value.
- Tile caches should contain map imagery only. They must be clearable from the
  mobile diagnostics/settings UI.
- Location and tile caches remain local to the phone in MVP.

## Acceptance Criteria

- A golden 54x63 palette-index grid RLE-encodes and decodes without loss, and
  the same RLE, indexed-RLE, and packed paths pass for every supported watch
  tile size.
- Compressed arena usage never exceeds 46 KiB; compaction preserves remaining
  segments and byte-pressure eviction cannot cause an immediate visible-tile
  re-request loop.
- A crop crossing a 256x256 logical source-tile boundary composites from the
  correct two or four provider source tiles for each supported watch tile size.
- Missing API key produces a visible watch error and no network request.
- Android-restricted key validation succeeds with correct package/cert headers
  and fails with intentionally wrong package/cert headers.
- Tile provider failure does not crash the phone worker or watch.
- A full visible `emery` tile grid, derived from the active rendered tile size,
  can be requested, delivered, decoded, and drawn after valid setup. The
  default `54x63` preset still yields an initial `5x5` grid.
- The phone operates with no project-hosted backend endpoints configured.

## Cancellation and measurement

Each crop captures credentials, credential generation, identity and settings.
Shared jobs are removed by identity; old completions cannot remove replacement
jobs or publish into a new generation. Consumers cancel independently. Only the
last consumer cancels a shared HTTP request; credential changes cancel all.
Cancellation is checked before scheduling, between stages, per crop row and
before publication, and never changes provider validation into a failure.

The native runtime retains at most 512 performance records without requiring
Flutter to be open. Diagnostic export includes worker/source waits, fetch,
decode, crop, colour/encode time, queue wait, transport ACK time, cache counts,
codec/bytes and cancellations. These are phone timings, not watch display time.
Watch performance builds log decode/receive and first-frame timings separately.
The 30 ms tile-to-tile pause remains the production default until real-device
0/10/30 ms trials demonstrate improvement without reliability or p95 input
latency regression. Chunk capacity remains 3,072 bytes.
