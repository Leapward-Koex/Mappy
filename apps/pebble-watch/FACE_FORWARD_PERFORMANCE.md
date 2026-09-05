# Face-forward performance checks — 2026-09-05

The normal compass animation previously snapped changes of 4 degrees or less in one tick. Mappy's compass event threshold is 2 degrees, so ordinary turns could look limited to the sensor update rate even though the visual scheduler runs every 30 ms.

## Research and implementation

The [PebbleOS weather globe](https://github.com/sjp4/PebbleOS/blob/1ad5b68a94f096cb76e080ed646402e24efe56f7/src/fw/apps/system/weather/globe_view.c#L1743-L1972) uses direct framebuffer access, fixed-point transforms, and local copies of frequently accessed state. Mappy already used direct framebuffer inverse sampling. This change keeps its exact 65535-denominator rounding and 8×8 traversal, while retaining only fractional phases alongside normalized tile cursors and keeping span state local. Immutable tile-storage validation now happens once per tile, and the sampler returns a palette index directly.

The 16-slot RLE block cache now groups neighboring source rows into eight-row banks using world Y. Full cache keys still distinguish tile, row, and block. Across 216 host cases, this reduces cache misses by 23.0% for 54×63 tiles, 15.4% for 72×84, and 22.7% for 108×126, without increasing cache capacity.

The [compass API documentation](https://developer.rebble.io/docs/c/Foundation/Event_Service/CompassService/) distinguishes its angular event threshold from filtering. The [1€ filtering research](https://gery.casiez.net/1euro/) describes the jitter/lag tradeoff and speed-adaptive filtering. Here the existing circular quarter-residual filter is retained, with its minimum step reduced from 4 degrees to 0.25 degrees. This provides intermediate frames with no added filter state or floating point. The 12-degree normal cap, shortest-path wraparound, elapsed-time catch-up, and fast reacquisition profile remain intact. This first pass addressed the sensor-bound frame cadence; the second pass below adds speed adaptation to reduce turning lag.

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


## First-pass build and checks

The production phone build succeeds with a RAM footprint of 60,599 bytes (previously 60,611), leaving 70,473 bytes available to the heap before runtime allocations. Resources remain 4,092 bytes. No cache heap allocation was added.

Passed: tooling and protocol checks; motion and tile-cache host tests; exact raster and cache-locality tests; final 0/30/45/60/75/90-degree Emery gates; mixed GPS/menu/tile-animation performance gates; wrist-look reacquisition; and the fixture smoke build/install/capture. The final angle sweep's worst draw was 17 ms. The final mixed run's worst draw was 20 ms. Screenshots were inspected for map, marker, route and chrome integrity. The emulator was stopped and the final PBW rebuilt in production phone mode.

One intermediate mixed run missed its short menu animation window under emulator scheduling delays; a subsequent complete run passed without relaxing its source-advance or timing gates. All map data used for testing was offline fixture data; no live provider requests were made.

## Second pass: independent responsiveness branch

Before these changes, the first-pass implementation above was committed as
`6d4617e` on `codex/face-forward-baseline`. The new work branches from that
checkpoint on `codex/face-forward-responsive`. The baseline phone build is
preserved locally as
`codex-emulator/mappy-face-forward-baseline-6d4617e.pbw`.

The normal display filter now follows the speed-adaptive principle from the
[original 1 Euro filter authors](https://gery.casiez.net/1euro/). It estimates
signed angular velocity from actual changed-sample timestamps, smooths that
velocity, and increases the single display filter's cutoff while turning. It
uses integer arithmetic and 16 bytes of history. Low-speed filtering, a noise
band, and aging of the last velocity reduce stationary jitter. Circular
shortest-path deltas handle north crossings. A bounded response to errors over
six degrees keeps first readings and long sensor gaps responsive. The fast
wrist-look profile, menu behavior, manual-browse cone, and compass event
threshold retain their existing contracts.

The shared visual timer now follows frame deadlines, compensating for callback
work and dispatch delays. It skips expired slots instead of scheduling catch-up
bursts, resets on idle/cadence changes, and bounds delays after wall-clock
corrections. The bearing filter still consumes elapsed virtual ticks.

Rendering retains the weather globe's applicable approach of local fixed-point
state and direct framebuffer writes. Indexed RLE spans now fill packed bytes,
with exact odd-nibble and malformed-input behavior. Proven same-tile spans
bypass repeated lookup and animation checks. Map samples covered by opaque
status-card interiors are skipped; the rounded edges, margins, menus, routes,
markers, fades, and cross-zoom fallback retain their previous pixels. No tile
cache allocation or full-scene buffer was added.

### Compass response measurements

Deterministic host traces compare the new filter against checkpoint `6d4617e`.
Lag is measured against the latest accepted sensor heading, not an extrapolated
physical heading. Both filters receive the same inputs and 30 ms render ticks.

| Measurement | Checkpoint | Responsive |
| --- | ---: | ---: |
| Mean lag at 30 degrees/second | 2.72 degrees | 1.45 degrees |
| Mean lag at +90 or -90 degrees/second | 8.15 degrees | 1.28 degrees |
| Mean output error with stationary ±1-degree noise | 0.26 degrees | 0.15 degrees |
| 90-degree step, time to 90% | 300 ms | 210 ms |
| Mean lag during irregular sampling and reversal | 7.22 degrees | 1.62 degrees |

All 81 measured steady-turn render ticks changed the displayed bearing. First
readings and readings after a long gap also reach 90% in 210 ms. These are
controlled filter tests, not measurements from the physical compass sensor.

The codec host benchmark reports 1.07–1.41× speedups for short runs and
2.18–2.47× for long/sparse runs; single-pixel runs are approximately unchanged.
These timings isolate decoding on the host and are not whole-watch FPS claims.

### Additional regression coverage

The actual shared scheduler runs against a deterministic clock/timer harness
covering dispatch delay, update work, missed frames, timer coalescing, cadence
changes, idle periods, clock wrap/correction, and registration failure.

Raster tests compare 19,337,184 coordinates and 36,473,814 framebuffer bytes,
including 630 combinations of tile geometry, bearing, card/menu/arrival state,
plain/fade/zoom-fade rendering, and cross-zoom fallback. The matrix exercises
1,005,335 settled spans, 2,585,665 general spans, and 2,478,240 skipped pixels.
Codec tests add 528 seeded geometry cases and 6,000 malformed-input/guard cases;
ASan and UBSan pass.

The diagnostic fixture initially exceeded Pebble's 65,535-byte executable
limit. Redundant signature, slot-reason, geometry, and invalidation logs were
removed from fixture builds. Production logging and every counter/marker used
by the regression helpers are retained.

### Final completed-frame replay

The final row-interval renderer avoids recalculating card geometry inside each
8-pixel span. Its 32-byte row cache fits unused space in the existing scratch
union, enforced at compile time.

| Measurement | Saved checkpoint replay | Responsive replay |
| --- | ---: | ---: |
| Completed-frame cadence | 22.96 FPS | 33.64 FPS |
| Completed frames | 96 | 116 |
| First-to-last completion span | 4,138 ms | 3,419 ms |
| Mean map draw duration | 13.46 ms | 13.19 ms |
| Maximum map draw duration | 15 ms | 15 ms |
| Fixture errors | 0 | 0 |

Both replays use the same 54×63 offline tiles, 128 route points, and thirty
3-degree compass events from an independent nominal 100 ms input timer.
The major measured improvement is display cadence and compass lag; whole-frame
CPU savings in this replay are small. QEMU timing varies, and the occasional
extra redraw can put measured completion cadence slightly above the timer's
nominal 33.3 FPS. This does not establish a physical-watch refresh rate.

Logs: checkpoint `codex-emulator/face-forward-cadence-after.log`; new branch
`codex-emulator/face-forward-responsive-cadence.log`. The latter's screenshot is
`codex-emulator/facing-responsive-cadence.png`.

### Second-pass build and verification limits

Production phone footprint is 62,147 bytes, versus 60,599 at the checkpoint
(+1,548 bytes, mostly code). Free heap before runtime allocations is 68,925
bytes; resources remain 4,092 bytes. The default fixture fits at 65,465 bytes,
and the cadence fixture at 65,363 bytes. No extra heap cache was allocated.

Tooling, protocol, motion/filter host, tile-cache/storage, scheduler, raster,
and cadence tests pass. The final mixed-animation gate passes with a worst
draw of 20 ms; manual browse remains north-up and the mixed GPS/tile/menu
sources share redraws correctly.

The Emery wrist-look gate was inconclusive: one responsive run detected the
look but exceeded the 2–8-frame fast-animation gate, and the next failed to
detect the look. The same test in an isolated checkout of checkpoint `6d4617e`
also failed to detect the look. No timing gate was relaxed. The actual motion
service and fast-response curve are unchanged; host tests verify the fast
curve still completes 180 degrees within eight virtual ticks. Host command
latency and the existing 1.5-second fast window are a possible explanation for
the first failure, not a conclusion established by the logs. Physical-watch
reacquisition remains a useful independent test.

Preserved motion logs are `codex-emulator/motion-reacquire-responsive-first.log`,
`codex-emulator/motion-reacquire-responsive-second.log`, and
`codex-emulator/motion-reacquire-baseline-comparison.log`.

The final 0/30/45/60/75/90-degree angle sweep passes with a worst draw of 14 ms.
For the navigation fixture, culling avoids 19.8% of destination samples while
keeping exact visible pixels. The final fixture smoke build/install/capture
passes, and the map, location cone, marker and status chrome were visually
inspected. The emulator was stopped. Test map data remained offline.
