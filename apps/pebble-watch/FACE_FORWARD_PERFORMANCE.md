# Face-forward performance check — 2026-09-05

The normal compass animation previously snapped changes of 4 degrees or less in one tick. Mappy's compass event threshold is 2 degrees, so ordinary turns could look limited to the sensor update rate even though the visual scheduler runs every 30 ms.

## Research and implementation

The [PebbleOS weather globe](https://github.com/sjp4/PebbleOS/blob/1ad5b68a94f096cb76e080ed646402e24efe56f7/src/fw/apps/system/weather/globe_view.c#L1743-L1972) uses direct framebuffer access, fixed-point transforms, and local copies of frequently accessed state. Mappy already used direct framebuffer inverse sampling. This change keeps its exact 65535-denominator rounding and 8×8 traversal, while retaining only fractional phases alongside normalized tile cursors and keeping span state local. Immutable tile-storage validation now happens once per tile, and the sampler returns a palette index directly.

The 16-slot RLE block cache now groups neighboring source rows into eight-row banks using world Y. Full cache keys still distinguish tile, row, and block. Across 216 host cases, this reduces cache misses by 23.0% for 54×63 tiles, 15.4% for 72×84, and 22.7% for 108×126, without increasing cache capacity.

The [compass API documentation](https://developer.rebble.io/docs/c/Foundation/Event_Service/CompassService/) distinguishes its angular event threshold from filtering. The [1€ filtering research](https://gery.casiez.net/1euro/) describes the jitter/lag tradeoff and speed-adaptive filtering. Here the existing circular quarter-residual filter is retained, with its minimum step reduced from 4 degrees to 0.25 degrees. This provides intermediate frames with no added filter state or floating point. The 12-degree normal cap, shortest-path wraparound, elapsed-time catch-up, and fast reacquisition profile remain intact. A full speed-adaptive sensor filter was unnecessary for the measured bottleneck.

## Controlled replay

Toolchain: Pebble Tool 5.0.40, SDK 4.33.1, QEMU 10.1.5-pebble14, Emery. The fixture warms 54×63 tiles and a 128-point route, then injects thirty 3-degree compass changes through an independent nominal 100 ms timer. Both versions use identical compact instrumentation.

| Measurement | Original renderer and smoothing | Optimized |
| --- | ---: | ---: |
| Completed-frame cadence | 10.00 FPS | 22.96 FPS |
| Completed frames | 30 | 96 |
| First-to-last completion span | 2,900 ms | 4,138 ms |
| Mean map draw duration | 17.13 ms | 13.46 ms |
| Maximum map draw duration | 19 ms | 15 ms |
| Fixture errors | 0 | 0 |

Cadence is measured as `(frames - 1) × 1000 / completion_span_ms`, not the reciprocal of drawing time. These runs show 2.3× more visible updates and about 21% less work per draw. QEMU scheduling can delay the input timer and the final smoothing tail; these are app draw measurements, not physical-watch display FPS guarantees.

Reproduce with `tooling/pebble-wsl.ps1 test-face-forward-cadence`. This command builds optional fixture instrumentation, captures a screenshot, reports timing, and stops its emulator. The production phone build excludes that instrumentation. Preserved comparison logs are in `codex-emulator/face-forward-cadence-before.log` and `codex-emulator/face-forward-cadence-after.log`.

## Regression coverage

Host tests compare 19,337,184 coordinates and 6,740,334 framebuffer bytes against independent references. They cover all supported tile sizes, quadrants, partial blocks, tile boundaries, cardinal directions, and scaled fallback behavior. Motion tests cover a 10 Hz input stream, lag, jitter around north, settling, wraparound, and catch-up equivalence; fast reacquisition still completes in eight ticks in Emery.

A mixed-animation gate was corrected to allow scheduler ticks that do not change quantized pixels. It continues to enforce redraw coalescing, animation lifetime, clipping, decoding, and frame-time budgets.


## Final build and checks

The production phone build succeeds with a RAM footprint of 60,599 bytes (previously 60,611), leaving 70,473 bytes available to the heap before runtime allocations. Resources remain 4,092 bytes. No cache heap allocation was added.

Passed: tooling and protocol checks; motion and tile-cache host tests; exact raster and cache-locality tests; final 0/30/45/60/75/90-degree Emery gates; mixed GPS/menu/tile-animation performance gates; wrist-look reacquisition; and the fixture smoke build/install/capture. The final angle sweep's worst draw was 17 ms. The final mixed run's worst draw was 20 ms. Screenshots were inspected for map, marker, route and chrome integrity. The emulator was stopped and the final PBW rebuilt in production phone mode.

One intermediate mixed run missed its short menu animation window under emulator scheduling delays; a subsequent complete run passed without relaxing its source-advance or timing gates. All map data used for testing was offline fixture data; no live provider requests were made.
