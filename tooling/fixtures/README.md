# Compass controller benchmark fixture

compass-watch-sweeps.csv contains the user's 71 real compass callbacks from the
Compass Lab recording made on 6 September 2026. It retains only elapsed callback
arrival time, the original native magnetic bearing, and calibration status.
Absolute UTC timestamps, marker values, and other export metadata are omitted.
The original complete export was validated against all 71 raw developer-log rows
before this fixture was extracted. All readings report calibrated (status 2).
The 70 arrival intervals have a 398 ms median and range from 195 to 805 ms.

**Subsequent angle-distortion report.** After this capture, the user confirmed
approximately half-angle movement in the unsmoothed Compass Lab app (Pebble Time
2, firmware 4.36.2), alongside half-angle movement and sudden jumps in Mappy. Retain these native values unchanged as a
regression input and callback-timing reference. Angle-derived replay results
measure response to the reported headings, not accurate physical wrist motion;
do not infer an optimal prediction angle from this recording. A new capture
must first verify known physical 90/180-degree turns.

Native values have 65,536 units per counterclockwise turn. The benchmark uses
Mappy's exact clockwise centidegree conversion, including rounding, then calls
the actual C controller through its public interface.

These are application callback timestamps, not sensor acquisition timestamps.
There is no independent physical wrist-angle measurement. Interpolated headings
are explicitly labeled as a piecewise-linear proxy and must not be presented as
measured physical lag, accuracy, or stop overshoot.

From the repository root, using WSL/Linux Python 3 and a C compiler:

    python3 tooling/benchmark-compass-controller.py \
        --baseline /path/to/old/bearing_smoothing.c \
        --output-dir apps/pebble-watch/codex-emulator/compass-benchmark --sanitize

Omit --baseline for a single version. Each controller source needs its matching
bearing_smoothing.h beside it; header paths can also be specified explicitly.
The output includes a JSON summary, a metrics CSV, a per-frame CSV for each case,
and the exact source/header snapshots and SHA-256 hashes used for both builds.
Use --case watch_sweeps to replay only the recording or --frame-phase-ms 15
to vary frame alignment.

The 79 cases cover the physical trace; synthetic steady ±30/90/180 deg/s turns
at 50/100/200/400 ms cadence; irregular cadence; 600/800 ms delivery gaps; 90/180
degree acquisitions and unsignaled heading steps; reversals; stationary noise; and stopping with no further
callbacks, contrasted with repeated unchanged callbacks. Synthetic traces cross north and multiple full revolutions.
Synthetic positions are known, allowing actual lag and stopping overshoot to be
calculated there. Rendering is an ideal 30 ms schedule, so results do not measure
physical-watch FPS.

The broad low-speed metric counts >=60 ms below 10 deg/s while the reference
exceeds 30 deg/s. The stricter sustained-observed-turn metric counts only gaps
whose preceding and following measured intervals both exceed 20 deg/s and agree
in direction. This excludes initial acquisition from the mid-turn metric, while
still being a retrospective proxy rather than proof of motion between callbacks.

Synthetic callbacks normally suppress exactly unchanged native values, matching the SDK even with a zero event filter. Acquisition explicitly requests the controller acquisition operation before the new target; observed-step cases omit that request.
