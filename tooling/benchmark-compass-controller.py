#!/usr/bin/env python3
"""Replay real compass callbacks and deterministic cases through the actual C API.

Run under WSL with a C compiler, from the repository root:
  python3 tooling/benchmark-compass-controller.py --output-dir /tmp/bearing-bench
  python3 tooling/benchmark-compass-controller.py --baseline /tmp/old/bearing_smoothing.c \
      --output-dir apps/pebble-watch/codex-emulator/bearing-bench

Each source must have its matching bearing_smoothing.h beside it, or supply the
corresponding --candidate-header / --baseline-header. No Python struct layout or
Python approximation of the controller is used. All times are callback arrival
times. The real trace's linearly interpolated reference is a proxy, NOT measured
physical wrist position; its lag and error cannot establish physical accuracy.
"""
import argparse
import bisect
import csv
import hashlib
import io
import json
import math
from pathlib import Path
import shlex
import statistics
import subprocess

ROOT = Path(__file__).resolve().parents[1]
WRAPPER = r"""
#include <stdio.h>
#include "bearing_smoothing.h"
int main(void) {
  BearingTracker tracker;
  bearing_tracker_reset(&tracker);
  char op; unsigned now; int value, status;
  puts("time_ms,display_degrees,velocity_degrees_per_second,prediction_degrees,active");
  while (scanf(" %c %u %d %d", &op, &now, &value, &status) == 4) {
    switch (op) {
      case 'R': bearing_tracker_reset(&tracker); break;
      case 'O': bearing_tracker_observe(&tracker, status > 0 ? value : -1,
                                         now, status == 2); break;
      case 'T': bearing_tracker_set_target(&tracker, value, now); break;
      case 'A': bearing_tracker_request_acquisition(&tracker, now); break;
      case 'F':
        bearing_tracker_advance(&tracker, now);
        printf("%u,%.2f,%.2f,%.2f,%d\n", now,
          bearing_tracker_display_centi_degrees(&tracker) / 100.0,
          bearing_tracker_velocity_centi_degrees_per_second(&tracker) / 100.0,
          bearing_tracker_prediction_centi_degrees(&tracker, now) / 100.0,
          bearing_tracker_active(&tracker, now));
        break;
      default: return 2;
    }
  }
  return 0;
}
"""


def delta(a, b):
    value = (b - a) % 360
    return value - 360 if value > 180 else value


def native_to_centi(native):
    """Exact map_geometry.c conversion, including nearest centidegree rounding."""
    clockwise = (65536 - native % 65536) % 65536
    return ((clockwise * 36000 + 32768) // 65536) % 36000


def angle_to_native(angle):
    return int(math.floor((-angle % 360) * 65536 / 360 + 0.5)) % 65536


def percentile(values, fraction):
    if not values:
        return None
    ordered = sorted(values)
    index = (len(ordered) - 1) * fraction
    left = int(index)
    right = min(left + 1, len(ordered) - 1)
    return ordered[left] + (ordered[right] - ordered[left]) * (index - left)


def rounded(value):
    return round(value, 4) if value is not None else None


def reference(points, time):
    index = bisect.bisect_right([p[0] for p in points], time) - 1
    if index < 0:
        return points[0][1], 0.0
    if index >= len(points) - 1:
        return points[-1][1], 0.0
    t0, a0 = points[index]
    t1, a1 = points[index + 1]
    speed = (a1 - a0) * 1000 / (t1 - t0)
    return a0 + speed * (time - t0) / 1000, speed


def observations(points, interval_pattern, end, dropout=None, jitter=False, keep_identical=False):
    result = []
    time = 0
    i = 0
    while time <= end:
        angle, unused = reference(points, time)
        # Reproducible stationary noise with both alternating and slower changes.
        if jitter and time:
            angle += [0.8, -0.4, 1.0, -0.9, 0.2, -0.7, 0.5, -0.5][i % 8]
        sample = (time, angle_to_native(angle), 2)
        # The SDK wrapper suppresses an exactly unchanged native heading even
        # with filter=0. Keep that behavior unless this is an explicit contrast.
        if keep_identical or not result or sample[1:] != result[-1][1:]:
            result.append(sample)
        interval = interval_pattern[i % len(interval_pattern)]
        if dropout and time == dropout[0]:
            interval = dropout[1]
        time += interval
        i += 1
    return result


def make_scenarios(fixture):
    real_rows = list(csv.DictReader(fixture.open()))
    real_samples = [(int(r["elapsed_ms"]), int(r["magnetic_native"]),
                     int(r["status"])) for r in real_rows]
    if not real_samples or real_samples[0][0] != 0 or any(b[0] <= a[0] for a, b in zip(real_samples, real_samples[1:])):
        raise ValueError("Fixture needs one segment starting at zero with strictly increasing arrival times.")
    points = []
    previous = None
    unwrapped = 0.0
    for time, native, status in real_samples:
        angle = native_to_centi(native) / 100
        if previous is None:
            unwrapped = angle
        else:
            unwrapped += delta(previous, angle)
        previous = angle
        points.append((time, unwrapped))
    scenarios = [dict(name="watch_sweeps", kind="recorded",
                      samples=real_samples, points=points,
                      window=(0, real_samples[-1][0]), end=real_samples[-1][0] + 2500)]
    for period in (50, 100, 200, 400):
        for speed in (30, 90, 180, -30, -90, -180):
            points = [(0, 10), (6000, 10 + speed * 6)]
            scenarios.append(dict(name=f"steady_{speed}_{period}ms", kind="steady",
                samples=observations(points, [period], 8500), points=points,
                window=(1500, 5500), end=8500, stop=6000, direction=1 if speed > 0 else -1))
        for angle in (90, 180):
            points = [(0, 0), (1000, 0), (1001, angle)]
            samples = [(0, angle_to_native(0), 2), (1000, angle_to_native(angle), 2)]
            scenarios.append(dict(name=f"acquisition_{angle}_{period}ms", kind="acquisition",
                samples=samples, points=points, window=(1000, 3500), end=3500,
                acquisition=(1000, angle), stop=1000, direction=1))
            scenarios.append(dict(name=f"observed_step_{angle}_{period}ms", kind="observed_step",
                samples=samples, points=points, window=(1000, 3500), end=3500,
                observed_step=(1000, angle), stop=1000, direction=1))
        points = [(0, 0), (1000, 0), (3000, 180), (5000, 0)]
        scenarios.append(dict(name=f"reversal_{period}ms", kind="reversal",
            samples=observations(points, [period], 7500), points=points,
            window=(1500, 4800), end=7500, reversal=3000, stop=5000, direction=-1))
        points = [(0, 180), (5000, 180)]
        scenarios.append(dict(name=f"jitter_{period}ms", kind="jitter",
            samples=observations(points, [period], 5000, jitter=True), points=points,
            window=(1000, 5000), end=7500, stop=5000, direction=0))
    for name, pattern, gap in (
        ("irregular", [50, 200, 400, 300, 200, 400], None),
        ("dropout_600", [200], (2000, 600)),
        ("dropout_800", [200], (2000, 800)),
    ):
        for speed in (30, 90, 180, -30, -90, -180):
            points = [(0, 350), (6000, 350 + speed * 6)]
            scenarios.append(dict(name=f"{name}_{speed}", kind="steady",
                samples=observations(points, pattern, 8500, gap), points=points,
                window=(1500, 5500), end=8500, stop=6000, direction=1 if speed > 0 else -1))
    for speed in (30, 90, 180, -30, -90, -180):
        points = [(0, 10), (6000, 10 + speed * 6)]
        scenarios.append(dict(name=f"silent_stop_{speed}_400ms", kind="steady",
            samples=observations(points, [400], 6000), points=points,
            window=(1500, 5500), end=8500, stop=6000, direction=1 if speed > 0 else -1))
    for speed in (30, 90, 180, -30, -90, -180):
        points = [(0, 10), (6000, 10 + speed * 6)]
        scenarios.append(dict(name=f"repeated_stop_{speed}_400ms", kind="steady",
            samples=observations(points, [400], 8500, keep_identical=True), points=points,
            window=(1500, 5500), end=8500, stop=6000, direction=1 if speed > 0 else -1))
    return scenarios


def compile_controller(source, header, output, compiler, sanitize):
    output.mkdir(parents=True, exist_ok=True)
    # Snapshot the pair so a concurrent source edit cannot change a running case.
    copied_source = output / "bearing_smoothing.c"
    copied_header = output / "bearing_smoothing.h"
    copied_source.write_bytes(source.read_bytes())
    copied_header.write_bytes(header.read_bytes())
    wrapper = output / "driver.c"
    wrapper.write_text(WRAPPER)
    binary = output / "replay"
    command = shlex.split(compiler) + ["-std=c11", "-Wall", "-Wextra", "-Werror",
        "-O2", "-I", str(output), str(wrapper), str(copied_source), "-o", str(binary)]
    if sanitize:
        command += ["-fsanitize=undefined", "-fno-sanitize-recover=all"]
    subprocess.run(command, check=True)
    return binary, dict(source=str(source), source_sha256=hashlib.sha256(
        copied_source.read_bytes()).hexdigest(), header_sha256=hashlib.sha256(
        copied_header.read_bytes()).hexdigest(), command=command)


def replay(binary, scenario, frame_ms, phase):
    commands = []
    sample_index = 0
    samples = scenario["samples"]
    for time in range(phase, scenario["end"] + 1, frame_ms):
        while sample_index < len(samples) and samples[sample_index][0] <= time:
            st, native, status = samples[sample_index]
            if "acquisition" in scenario and st == scenario["acquisition"][0]:
                commands.append(f"A {st} 0 0\n")
            commands.append(f"O {st} {native_to_centi(native)} {status}\n")
            sample_index += 1
        commands.append(f"F {time} 0 0\n")
    result = subprocess.run([str(binary)], input="".join(commands), text=True,
                            capture_output=True, check=True)
    frames = []
    latest = 0
    previous_display = None
    previous_unwrapped = None
    previous_time = None
    latest_unwrapped = None
    previous_native_angle = None
    for row in csv.DictReader(io.StringIO(result.stdout)):
        time = int(row["time_ms"])
        while latest < len(samples) and samples[latest][0] <= time:
            heading = native_to_centi(samples[latest][1]) / 100
            if latest_unwrapped is None:
                latest_unwrapped = heading
            else:
                latest_unwrapped += delta(previous_native_angle, heading)
            previous_native_angle = heading
            latest += 1
        display = float(row["display_degrees"])
        truth, truth_speed = reference(scenario["points"], time)
        if previous_display is None:
            unwrapped = truth + delta(truth % 360, display)
            frame_speed = 0.0
        else:
            unwrapped = previous_unwrapped + delta(previous_display, display)
            frame_speed = (unwrapped - previous_unwrapped) * 1000 / (time - previous_time)
        frame = dict(time_ms=time, display_degrees=display,
            display_unwrapped_degrees=unwrapped,
            velocity_degrees_per_second=float(row["velocity_degrees_per_second"]),
            frame_speed_degrees_per_second=frame_speed,
            prediction_degrees=float(row["prediction_degrees"]), active=int(row["active"]),
            sample_index=latest - 1, sample_age_ms=time - samples[latest - 1][0],
            latest_observed_degrees=previous_native_angle,
            reference_degrees=truth, reference_velocity_degrees_per_second=truth_speed,
            reference_error_degrees=unwrapped - truth,
            latest_observation_error_degrees=delta(previous_native_angle, display))
        frames.append(frame)
        previous_display, previous_unwrapped, previous_time = display, unwrapped, time
    # A retrospective mask using only measured successive differences. Requiring
    # two same-sign >=20 deg/s intervals avoids counting the start of a sweep as
    # a mid-turn pause. It still cannot prove physical motion between callbacks.
    interval_speeds = [(native_to_centi(b[1]) / 100, native_to_centi(a[1]) / 100,
                        b[0] - a[0]) for a, b in zip(samples, samples[1:])]
    interval_speeds = [delta(a, b) * 1000 / dt for b, a, dt in interval_speeds]
    for frame in frames:
        i = frame["sample_index"]
        frame["sustained_observed_turn"] = int(0 < i < len(interval_speeds) and
            abs(interval_speeds[i - 1]) >= 20 and abs(interval_speeds[i]) >= 20 and
            interval_speeds[i - 1] * interval_speeds[i] > 0)
    return frames


def episodes(frames, predicate, frame_ms):
    result = []
    start = None
    for frame in frames:
        if predicate(frame):
            if start is None:
                start = frame["time_ms"]
        elif start is not None:
            result.append(dict(start_ms=start, duration_ms=frame["time_ms"] - start))
            start = None
    if start is not None:
        result.append(dict(start_ms=start,
                           duration_ms=frames[-1]["time_ms"] - start + frame_ms))
    return result


def metrics(scenario, frames, frame_ms):
    start, end = scenario["window"]
    window = [f for f in frames if start <= f["time_ms"] <= end]
    speeds = [abs(f["frame_speed_degrees_per_second"]) for f in window]
    signed_speeds = [f["frame_speed_degrees_per_second"] for f in window]
    errors = [f["reference_error_degrees"] for f in window]
    low = episodes(window, lambda f:
        abs(f["reference_velocity_degrees_per_second"]) >= 30 and
        abs(f["frame_speed_degrees_per_second"]) < 10, frame_ms)
    low = [e for e in low if e["duration_ms"] >= 60]
    pulses = episodes(window, lambda f:
        abs(f["reference_velocity_degrees_per_second"]) >= 30 and
        abs(f["frame_speed_degrees_per_second"]) >
          2 * abs(f["reference_velocity_degrees_per_second"]), frame_ms)
    lag = [-1000 * f["reference_error_degrees"] /
           f["reference_velocity_degrees_per_second"] for f in window
           if abs(f["reference_velocity_degrees_per_second"]) >= 30]
    result = dict(reference_kind="piecewise_linear_callback_proxy" if
                  scenario["kind"] == "recorded" else "known_synthetic_trajectory",
        sample_count=len(scenario["samples"]),
        identical_successive_readings=sum(a[1:] == b[1:] for a, b in
                                         zip(scenario["samples"], scenario["samples"][1:])),
        metric_window_ms=[start, end],
        mean_abs_speed_dps=rounded(statistics.mean(speeds)),
        peak_frame_speed_dps=rounded(max(speeds)),
        peak_internal_speed_dps=rounded(max(abs(f["velocity_degrees_per_second"]) for f in window)),
        speed_p05_dps=rounded(percentile(speeds, .05)),
        speed_p95_dps=rounded(percentile(speeds, .95)),
        speed_stddev_dps=rounded(statistics.pstdev(speeds)),
        signed_speed_stddev_dps=rounded(statistics.pstdev(signed_speeds)),
        speed_coefficient_of_variation=rounded(statistics.pstdev(speeds) /
            statistics.mean(speeds)) if statistics.mean(speeds) else 0,
        low_speed_60ms_episodes=low, low_speed_60ms_count=len(low),
        repeated_double_reference_speed_episodes=len(pulses),
        max_abs_reference_error_deg=rounded(max(map(abs, errors))),
        mean_abs_reference_error_deg=rounded(statistics.mean(map(abs, errors))),
        mean_reference_lag_ms=rounded(statistics.mean(lag)) if lag else None,
        max_abs_latest_observation_error_deg=rounded(max(abs(
            f["latest_observation_error_degrees"]) for f in window)),
        max_abs_prediction_deg=rounded(max(abs(f["prediction_degrees"]) for f in frames)))
    sustained_low = episodes(window, lambda f: f["sustained_observed_turn"] and
        abs(f["frame_speed_degrees_per_second"]) < 10, frame_ms)
    sustained_low = [e for e in sustained_low if e["duration_ms"] >= 60]
    result["sustained_observed_turn_low_speed_60ms_episodes"] = sustained_low
    result["sustained_observed_turn_low_speed_60ms_count"] = len(sustained_low)
    result["sustained_observed_turn_low_speed_total_ms"] = sum(e["duration_ms"] for e in sustained_low)
    if "stop" in scenario:
        stop = scenario["stop"]
        stopped = [f for f in frames if f["time_ms"] >= stop]
        direction = scenario["direction"]
        final = reference(scenario["points"], scenario["end"])[0]
        result["stop_overshoot_deg"] = rounded(max(0, max(
            direction * (f["display_unwrapped_degrees"] - final) for f in stopped)))
        result["settle_after_stop_ms"] = next((f["time_ms"] - stop for i, f in enumerate(stopped)
            if not f["active"] and all(not rest["active"] for rest in stopped[i:])), None)
    if "acquisition" in scenario or "observed_step" in scenario:
        event_kind = "acquisition" if "acquisition" in scenario else "observed_step"
        event, angle = scenario[event_kind]
        result[event_kind + "_90_percent_ms"] = next((f["time_ms"] - event for f in frames
            if f["time_ms"] >= event and abs(f["display_unwrapped_degrees"]) >= abs(angle) * .9), None)
    if "reversal" in scenario:
        event = scenario["reversal"]
        opposite_sample = next(s[0] for i, s in enumerate(scenario["samples"]) if i and
            s[0] > event and delta(native_to_centi(scenario["samples"][i - 1][1]) / 100,
                                  native_to_centi(s[1]) / 100) < 0)
        result["first_opposing_sample_ms"] = opposite_sample
        result["reversal_after_opposing_sample_ms"] = next((f["time_ms"] - opposite_sample
            for f in frames if f["time_ms"] >= opposite_sample and
            f["velocity_degrees_per_second"] < 0), None)
    if scenario["kind"] == "jitter":
        result["stationary_mean_abs_jitter_deg"] = rounded(statistics.mean(map(abs, errors)))
        result["stationary_peak_jitter_deg"] = rounded(max(map(abs, errors)))
    if scenario["kind"] == "recorded":
        # Specific measured first-interval hesitation from the user's sweep.
        before = [f for f in frames if 9300 <= f["time_ms"] < 9621]
        after = [f for f in frames if 9621 <= f["time_ms"] < 10023]
        if before and after:
            result["highlight_9222_10023ms"] = dict(
                minimum_pre_callback_speed_dps=rounded(min(abs(f["frame_speed_degrees_per_second"]) for f in before)),
                internal_speed_last_frame_before_callback_dps=rounded(before[-1]["velocity_degrees_per_second"]),
                maximum_post_callback_speed_dps=rounded(max(abs(f["frame_speed_degrees_per_second"]) for f in after)))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--candidate", type=Path,
        default=ROOT / "apps/pebble-watch/src/c/bearing_smoothing.c")
    parser.add_argument("--candidate-header", type=Path)
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--baseline-header", type=Path)
    parser.add_argument("--fixture", type=Path,
        default=ROOT / "tooling/fixtures/compass-watch-sweeps.csv")
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--cc", default="cc")
    parser.add_argument("--frame-ms", type=int, default=30)
    parser.add_argument("--frame-phase-ms", type=int, default=0)
    parser.add_argument("--sanitize", action="store_true")
    parser.add_argument("--case", action="append",
        help="Only cases whose name contains this text; repeat to select more.")
    args = parser.parse_args()
    if args.frame_ms <= 0 or not 0 <= args.frame_phase_ms < args.frame_ms:
        parser.error("Frame interval must be positive and phase within one interval.")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    scenarios = make_scenarios(args.fixture)
    if args.case:
        scenarios = [s for s in scenarios if any(text in s["name"] for text in args.case)]
    if not scenarios:
        parser.error("No cases matched.")
    summary = dict(
        caveats=[
            "Real trace reference interpolates callback headings; physical wrist position is unknown.",
            "Ideal fixed render intervals isolate controller motion; replay does not measure watch FPS.",
            "True stop/lag/jitter metrics apply only to synthetic trajectories.",
            "Low-speed episode: >=60 ms below 10 deg/s while reference exceeds 30 deg/s.",
            "Correction error relative to latest observation is not physical stopping overshoot.",
            "Sustained-observed-turn mask: consecutive measured intervals >=20 deg/s with agreeing signs.",
            "Synthetic callbacks suppress identical native headings, except explicit repeated_stop cases.",
        ],
        frame_ms=args.frame_ms, frame_phase_ms=args.frame_phase_ms,
        fixture_sha256=hashlib.sha256(args.fixture.read_bytes()).hexdigest(), controllers={})
    for label, source, header in (
        ("candidate", args.candidate, args.candidate_header),
        ("baseline", args.baseline, args.baseline_header),
    ):
        if source is None:
            continue
        source = source.resolve()
        header = header.resolve() if header else source.with_name("bearing_smoothing.h")
        binary, build = compile_controller(source, header, args.output_dir / label,
                                           args.cc, args.sanitize)
        results = {}
        for scenario in scenarios:
            frames = replay(binary, scenario, args.frame_ms, args.frame_phase_ms)
            results[scenario["name"]] = metrics(scenario, frames, args.frame_ms)
            path = args.output_dir / label / (scenario["name"] + ".csv")
            with path.open("w", newline="") as stream:
                writer = csv.DictWriter(stream, fieldnames=list(frames[0]))
                writer.writeheader()
                writer.writerows(frames)
        summary["controllers"][label] = dict(build=build, scenarios=results)
        print(f"{label}: {len(results)} scenarios; C SHA256 {build['source_sha256']}")
        if "watch_sweeps" in results:
            print(json.dumps(results["watch_sweeps"], indent=2))
    (args.output_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    with (args.output_dir / "metrics.csv").open("w", newline="") as stream:
        fields = ["controller", "scenario", "reference_kind", "mean_abs_speed_dps",
            "peak_frame_speed_dps", "speed_stddev_dps", "speed_coefficient_of_variation",
            "low_speed_60ms_count", "sustained_observed_turn_low_speed_60ms_count", "repeated_double_reference_speed_episodes",
            "mean_reference_lag_ms", "max_abs_prediction_deg", "stop_overshoot_deg",
            "settle_after_stop_ms", "acquisition_90_percent_ms",
            "reversal_after_opposing_sample_ms", "stationary_mean_abs_jitter_deg"]
        writer = csv.DictWriter(stream, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        for controller, entry in summary["controllers"].items():
            for scenario, result in entry["scenarios"].items():
                writer.writerow(dict(controller=controller, scenario=scenario, **result))
    print(f"Wrote {args.output_dir / 'summary.json'} and metrics.csv; per-frame CSVs are under each controller.")


if __name__ == "__main__":
    main()
