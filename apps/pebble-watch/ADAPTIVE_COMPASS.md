# Adaptive compass rotation, September 2026

The Compass Lab recording showed a median 398 ms callback interval, with 602/805 ms gaps and changes as large as 129.8 degrees between readings. The previous controller often finished an intermediate correction before receiving the next bearing. Replaying the actual C code with ideal 30 ms frames reproduced the visible pause followed by a speed burst.

## Implemented controller

- Keep displayed position and velocity continuous when observations arrive. The existing 30 ms scheduler, fractional bearings, manual facing cone, menu behavior, declination, invalid heading handling and phone protocol remain in place.
- Use a 16/s follower during calibrated tracking, 20/s during acquisition, and blend to the existing quieter 10/s gain at rest. Non-predicting phone/calibration input retains the faster gain.
- Limit **requested** tracking velocity to 1.5 times estimated sensor speed, with a 90 degrees/s floor and the existing 720 degrees/s ceiling. Integrate acceleration toward that request; a falling limit must brake existing momentum, not reset it.
- Predict with a reference whose velocity decreases linearly to zero. With signed estimated speed `v`, sample age `a`, and horizon `H`, the lead is `v * a * (2H - a) / (2H)`, using seconds and clamping `a` to `H`. Choose `H = min(2 * estimated_period, 500 ms, 2 * 24 degrees / abs(v))`. Consequently slow turns predict less, and the maximum lead is 24 degrees. Fixed-point staged products avoid floating point and stay within int32 bounds.
- A clear movement of at least 6 degrees from rest may qualify prediction immediately. Smaller movements require two consistent intervals above 15 degrees/s. A directly opposing observation cancels prediction; after a quiet interval, new prediction must agree with the new motion direction.
- Learn longer normal callback intervals immediately and shorter intervals with an eighth-weight average, bounded to 50–500 ms. Once a slower normal cadence is established, an isolated interval over 500 ms is treated as a gap rather than inflating the usual period. Seed/reset remains 200 ms.
- Hold prediction until `max(350 ms, 1.25 * estimated_period)`, then fade over 100 ms. A missing stream eventually returns to the last known bearing and idles, including when the SDK suppresses identical readings.
- Explicit acquisition and large corrections after more than one second of sensor silence use the fast acquisition path. Ordinary new readings do not restart acquisition. Substeps remain at most 10 ms, with at most 120 ms consumed after a delayed frame.

24 degrees was selected after comparing 12–40 degree envelopes, different gains/horizons, smooth versus hard prediction limits, and velocity feedforward. Larger 28–30 degree envelopes modestly reduced delay but worsened stop overshoot. Feedforward recovered delay at the cost of more ripple and larger overshoot. The selected gain/horizon provided a better compromise than enlarging the prediction envelope further.

## Results versus the previous committed controller

These measurements use the real C implementation and identical input/frame timing. The real recording has no independent physical wrist-angle reference: reported model speeds are not measured hardware animation speeds. The full capture's piecewise-linear proxy lag changed from 269 to 296 ms; that proxy is not physical latency. Synthetic trajectories have known positions and permit actual lag/overshoot measurements.

| Metric | Previous | Updated |
|---|---:|---:|
| Recorded sustained-turn near-stops lasting at least 60 ms | 7 | 0 |
| Highlighted gap minimum frame speed | 4 degrees/s | 65.7 degrees/s |
| Highlighted following speed peak | 720 degrees/s | 431 degrees/s |
| Peak frame speed across the recording | 720 degrees/s | 492.7 degrees/s |
| Synthetic 180 degrees/s, 200 ms delivery: mean lag | 154 ms | 142 ms |
| Same turn, 400 ms delivery: mean lag | 253 ms | 245 ms |
| 400 ms turn: speed variation coefficient | 0.985 | 0.444 |
| 400 ms turn followed by silence: overshoot | 7.8 degrees | 23.0 degrees |
| Same silent stop: idle delay | 900 ms | 1,110 ms |

A near-stop uses speed below 10 degrees/s, during gaps whose preceding and following measured intervals agree in direction and exceed 20 degrees/s. It excludes unobservable motion before the first changed reading; it does not establish the true wrist trajectory. Across all 30 integer-millisecond render phases, the updated controller had zero such near-stops, versus 6–8 for the previous controller.

The broader unit tests sweep stop/reversal timing at 200/400 ms cadence. Worst overshoot was 23.03 degrees. A delayed final partial reading can extend settling to 1.38 seconds after physical stop. Reversal starts within 150 ms of a directly opposing reading. Explicit 90/180 degree acquisition reaches 90% in 210/280 ms at 10 ms advancement; display-frame alignment adds up to one frame. Stationary +/-1 degree noise at 200 ms has 0.23 degree mean displayed jitter. Physical-watch validation is still needed, particularly for the deliberately increased coasting after stops.

## Build and rendering checks

SDK 4.33.1, Pebble Tool 5.0.40, Emery emulator:

- `doctor`, `test-tooling`, `test-motion-host`, `test-protocol`, and `test-tile-cache-host` passed. Tooling includes actual map-geometry integration, phone fallback, shared scheduling and trace-buffer checks.
- 79 benchmark scenarios ran with undefined-behavior sanitization: real capture, steady turns at 50/100/200/400 ms, irregular delivery, 600/800 ms gaps, reversals, acquisition, unsignaled steps, jitter, silent stops and repeated stop readings.
- 480 additional replays varied frame alignment across 30 phases for eight selected cases in both controllers. The final size cleanup produced identical metrics and every frame CSV across all 79 scenarios.
- Face-forward cadence: **32.91 FPS**, 144 completed frames, 4,345 ms measured span; mean draw cost 15.09 ms, maximum 21 ms. The earlier build measured 32.68 FPS. This measures emulator rendering, not physical-watch FPS.
- Fixture smoke and visual inspection passed. A redundant-check cleanup resolved a fixture virtual-size overflow; all final variants fit.
- Production linked footprint **64,170 bytes** (+308); diagnostic **65,009 bytes** (+324), below Pebble's 65,535-byte executable limit. The tracker still occupies 36 bytes; its added flag uses padding.
- Diagnostic startup heap remaining: **4,580 bytes**. The existing 1,024-byte trace ring successfully flushed outside animation. Production contains no trace logging.

## Repeat the comparison

The anonymized recording is `tooling/fixtures/compass-watch-sweeps.csv`; it omits absolute timestamps. The benchmark snapshots both source/header pairs, writes their hashes, and emits JSON metrics and per-frame CSVs.

```sh
python3 tooling/benchmark-compass-controller.py \
  --baseline /path/to/previous/bearing_smoothing.c \
  --output-dir apps/pebble-watch/codex-emulator/compass-comparison --sanitize
```

Place the previous matching header beside its source, or supply `--baseline-header`. Use `--frame-phase-ms 15` to vary rendering alignment, or `--case watch_sweeps` to select the physical recording. The automatic host tests also replay the troublesome segment and assert continued movement and bounded speed.

Production and diagnostic PBWs are saved separately under `codex-emulator/mappy-adaptive-compass-{production,diagnostic}.pbw`. The diagnostic version retains the existing buffered `MAPPY_BTRACE` format; its 64-frame ring preserves approximately the last two seconds and reports overwritten records. `codex-emulator/compass-adaptive-packaged/` contains the final benchmark and comparison plot. The prior controller remains available in commit 75ea075 (controller originally introduced in 67d80cd).
