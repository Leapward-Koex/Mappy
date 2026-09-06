This document records the earlier 8-degree controller. See [Adaptive compass rotation](ADAPTIVE_COMPASS.md) for the current implementation and physical-recording results.

# Continuous compass rotation

Comparison branch: `codex/continuous-bearing`, based on the merged
`codex/face-forward-responsive` at `cb165b2`. The original merged PBW is saved
locally as `codex-emulator/mappy-bearing-before-cb165b2.pbw`.

## Behavior and implementation

New readings change one continuous controller's destination while preserving
its displayed position and angular velocity. The old per-reading chase, tail
snaps, and 1.5-second fast window have been removed. Wrist-look and route-start
request acquisition once. The existing map renderer and shared 30 ms scheduler
remain in place.

`bearing_smoothing.c` is a Pebble-independent fixed-point controller with
millidegree integration and centidegree input/output. It uses a critically
damped follower at omega 20/s during motion or large acquisition errors, blending
to 10/s over 120 ms after motion becomes stale and error/velocity are small.
Integration steps are at most 10 ms, speed is capped at 720°/s, and frames delayed
by more than 120 ms discard excess backlog. Tiny residuals settle at 0.25° and
1°/s so an idle watch does not keep rendering forever.

Sensor velocity uses real callback intervals and an 80 ms smoothing time
constant. Two agreeing directional deltas above 15°/s qualify prediction.
Prediction uses at most 100 ms of sample age and is capped at ±8°. It remains
bounded between normal readings, then fades for 100 ms after
`max(300 ms, 1.5 * estimated_period)`. An opposing observation immediately
revokes it. Prediction qualification is separate from responsive controller
gain. Position and velocity remain continuous while braking.

The period starts at 200 ms, adapts by one quarter of each interval difference,
and stays within 50–300 ms. A gap over one second resets derivative history;
same-millisecond readings coalesce without division by zero. North crossings
use the shortest signed angle. Prediction is disabled for calibrating compass
data and the phone-course fallback.

`map_geometry.c` separates fresh observation, camera synchronization,
acquisition, frame advancement, and explicit reset/snap. Sensor callbacks may
advance private state to their arrival time; only the shared frame tick
publishes the pose used by the map. Cached compass peeks do not become new
samples. Native sub-degree precision and declination survive until legacy
integer consumers need rounding. Menus retain their existing resume snap;
manual browse retains a north-up map and a smoothed facing cone.

The compass event filter is explicitly zero after subscribing. Calibrated
firmware normally provides approximately 5 Hz readings; this setting removes
application-side suppression and does not increase firmware sampling.

## Measured controller behavior

`test-motion-host` runs the actual C controller, with 30 ms display observations
and 50/100/200/300 ms sensor intervals, in both directions and across north.
The results below describe deterministic replay, not physical-watch timing.

| Measurement | Result | Gate |
| --- | --- | --- |
| 90° acquisition, 90% reached | 200 ms | ≤240 ms |
| 180° acquisition, 90% reached | 270 ms | ≤300 ms |
| 5 Hz, 90°/s turn: frame speed | 41.3–124.3°/s | No 60 ms near-stop; peak ≤180°/s |
| 5 Hz, 180°/s turn: frame speed | 65.3–292.7°/s | No 60 ms near-stop; peak ≤360°/s |
| 5 Hz mean lag at 90°/s / 180°/s | 123 / 154 ms | Reported for comparison |
| Worst stop/reversal overshoot | 7.57° | ≤10° |
| Settling to idle after stopping | ≤880 ms | ≤1 second |
| Reversal after opposing sample | ≤10 ms in phase sweep | ≤150 ms |
| Stationary ±1° noise, mean / peak error | 0.23° / 0.40° | Mean ≤0.3° |

The regular-stream suite passes the speed gates for sample intervals up to
200 ms. It also replays 300 ms and irregular 53/197/107/293 ms intervals,
qualified prediction, opposing/duplicate readings, stale fade, delayed frames,
timestamp wrap, invalid input, and acquisition while already moving. A frozen
old-filter reference makes speed ripple regressions visible; merely changing
every frame is no longer considered smoothness evidence.

A separate replay compiled the actual, unmodified `cb165b2` controller with the
same 5 Hz, 180°/s stream and measured 100 frames after warmup. The old controller
produced ten near-stop episodes of 60 ms; the new one produced none. Mean lag
changed from 128.6 ms to 154.5 ms: the continuity improvement costs about 26 ms
of average lag in this case. This is a smoothness improvement rather than a
claim of uniformly lower lag.

Native-compass and phone-fallback integration tests compile the actual
`map_geometry.c` with a small SDK shim. They check sample identity, fractional
input, scheduler publication, same-heading validity recovery, declination,
menu/arrival lifecycle, manual browse, and north-up activation.

## Emulator rendering

Pebble Tool 5.0.40, SDK 4.33.1, QEMU 10.1.5-pebble14, platform Emery.
The 5 Hz fixture rotates at 90°/s with 128 route points, warms all cardinal
directions, and retains existing tile/render optimizations.

- Completed-draw cadence: **32.68 FPS**, 141 frames over a 4284 ms completion span.
- Draw CPU time: **14.67 ms mean, 18 ms maximum**, zero fixture errors.
- Frame timing includes event-loop delays. The first draw completed 1266 ms
  after the replay command; the final draw at 5550 ms. QEMU timer delivery and
  acquisition latency are distinct from sustained drawing cadence.
- The 0/30/45/60/75/90° angle sweep passes with zero raster errors and a
  maximum draw time of 16 ms.
- The mixed rendering matrix passes: isolated bearing maximum 14 ms; combined
  GPS/menu/tile reveal maximum 26 ms; manual browse maximum 16 ms; recenter
  maximum 20 ms. Manual browse recorded zero map-rotation/coverage errors.
- North-up smoke capture was visually inspected. Physical wrist-turn behavior
  and real sensor noise still need watch testing.

The diagnostic run exposed a -969 ms frame-clock step followed by a +1030 ms
step; saturated sample ages identify those invalid intervals. The referenced
[QEMU RTC source](https://github.com/sjp4/PebbleOS/blob/1ad5b68a94f096cb76e080ed646402e24efe56f7/src/fw/drivers/qemu/qemu_rtc_hal.c#L81)
reads seconds and milliseconds independently, consistent with this artifact.
Physical nRF5/SF32LB implementations obtain coherent readings, but the installed
emulator binary was not proven identical to that source and real wall-clock
corrections remain possible. The controller rebases backward steps without
integration and caps forward backlog at 120 ms. Hardware traces remain necessary
before treating emulator timing as a watch result.

The external `test-motion-reacquire` accelerometer replay did not produce its
watch-look event in QEMU (the same limitation was recorded before this rewrite).
Its logs confirm a Walk route and 25 Hz subscription, but do not establish sensor
delivery. The unchanged classifier passes deterministic CSV tests, route-start
acquisition was logged, and controller acquisition passes host integration.
Physical wrist-look validation therefore remains open.

## Production and diagnostics

All variants passed SDK packaging's 65,535-byte virtual-image limit. The linked
RAM footprints were 62,791 bytes for the merged baseline, 63,862 for production
(+1,071 bytes), and 64,685 for diagnostics. Both retain 4,092 resource bytes.
The diagnostic PBW was installed on Emery: trace allocation succeeded, 4,900
heap bytes remained after startup allocations, and buffered rows were emitted.
The trace's additional 1 KiB heap allocation is separate from the linked image.

Build production from WSL with:

```sh
bash tooling/pebble-emulator-codex.sh build-phone
```

Build the phone-compatible diagnostic package with:

```sh
MAPPY_BEARING_TRACE=1 bash tooling/pebble-emulator-codex.sh build-phone
```

Both commands write `apps/pebble-watch/build/pebble-watch.pbw`; copy it before
building the other variant. The normal release-install workflow explicitly
disables bearing and tile performance diagnostics.

The diagnostic build allocates one 1024-byte, 64-frame ring at service startup.
It records the latest roughly two seconds at the nominal frame cadence and
counts overwritten records. Allocation failure disables recording gracefully.
It performs no frame-by-frame logging. After **all** visual animation settles,
it flushes at most four records per 20 ms timer callback, pausing if motion
resumes. Production has no trace buffer, allocation, or hook work.

Capture Pebble developer logs while making a short turn, then hold still for
about two seconds so the buffer can drain. `MAPPY_BTRACE begin n=... drop=...`
precedes retained rows. Long gestures retain their most recent frames.

| Field | Meaning |
| --- | --- |
| `t` | Controller frame timestamp, milliseconds, wrapping unsigned 32-bit |
| `r` | Latest observed corrected compass bearing, centidegrees |
| `g` | Controller's observed/corrected destination, centidegrees |
| `p` | Published displayed bearing, centidegrees |
| `v` | Signed controller angular velocity, tenths of a degree per second |
| `a` | Age of the latest real sensor observation in milliseconds |
| `dt` | Time since preceding controller frame, milliseconds |
| `f` | Flags: valid 1, calibrated 2, acquisition 4, prediction 8, active 16, face-forward 32, age saturated 64, interval saturated 128 |

Angle 65535 means unavailable; sample age saturates at 65535 ms and `dt` at
255 ms. Full timestamps preserve longer frame intervals. Sensor timestamp can
be reconstructed as `t - a` when age is valid. Rows measure controller updates;
completed raster-draw cadence is measured separately by `MAPPY_FPERF`.

Trace host tests cover allocation failure, buffer wrap/drop accounting, idle
chunks, resuming during a flush, other active animations, timer retry,
timestamp wrap, and disabled-build zero overhead.

## Sources

- [Pinned firmware compass service](https://github.com/sjp4/PebbleOS/blob/1ad5b68a94f096cb76e080ed646402e24efe56f7/src/fw/services/ecompass/service.c#L142)
- [Rebble compass API](https://developer.rebble.io/docs/c/Foundation/Event_Service/CompassService/)
- [Damped spring mathematics](https://www.ryanjuckett.com/damped-springs/)
