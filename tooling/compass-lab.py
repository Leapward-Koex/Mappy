#!/usr/bin/env python3
"""Capture Compass Lab developer logs and validate/export complete recordings."""
from __future__ import annotations
import argparse
import csv
from datetime import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
CAPTURES = ROOT / "apps/compass-lab/captures"


class ExportParser:
    def __init__(self):
        self.header = None
        self.rows = {}
        self.problem = None
        self.complete = None

    def feed(self, line):
        match = re.search(r"\bCLAB ([BSEX])\s+(.+)", line)
        if not match:
            return None
        kind, body = match.groups()
        try:
            fields = {key: int(value) for key, value in
                      re.findall(r"([a-z]+)=(-?\d+)", body)}
            if kind == "B":
                self.header, self.rows, self.problem, self.complete = fields, {}, None, None
                if fields.get("v") != 1 or fields.get("turn") != 65536:
                    raise ValueError("Unsupported Compass Lab export version/angle units")
                if not 1 <= fields.get("n", 0) <= 2048 or "e" not in fields:
                    raise ValueError("Invalid export header")
            elif self.header and fields.get("e") == self.header.get("e"):
                if kind == "X":
                    self.problem = "Watch interrupted the export"
                    return self.problem
                if kind == "S":
                    if not all(key in fields for key in ("i", "s", "m", "h", "t", "c", "d", "k", "r")):
                        raise ValueError("Truncated sample row")
                    i = fields["i"]
                    if not (0 <= i < self.header["n"] and 0 <= fields["s"] <= 0xffffffff
                            and 0 <= fields["m"] < 1000 and -1 <= fields["c"] <= 2
                            and fields["d"] in (0, 1) and 0 <= fields["k"] <= 65535 and 1 <= fields["r"] <= 65535
                            and -2**31 <= fields["h"] < 2**31 and -2**31 <= fields["t"] < 2**31):
                        raise ValueError("Out-of-range sample row")
                    if i in self.rows and self.rows[i] != fields:
                        raise ValueError("Conflicting duplicate sample row")
                    self.rows[i] = fields
                elif kind == "E":
                    if fields.get("n") != self.header["n"] or len(self.rows) != self.header["n"]:
                        self.problem = f"Incomplete export: {len(self.rows)}/{self.header['n']} samples"
                    if not self.problem:
                        self.complete = [self.rows[i] for i in range(self.header["n"])]
                        return "complete"
                    return self.problem
        except ValueError as error:
            if kind == "B": self.header = None
            self.complete = None
            self.problem = str(error)
            return self.problem
        return None


def clockwise(native, units=65536):
    return (-native % units) * 360.0 / units


def export_csv(rows, path, test_input=False):
    first_ms = rows[0]["s"] * 1000 + rows[0]["m"]
    previous_ms, previous_heading, previous_segment = None, None, None
    records = []
    intervals = []
    backwards = 0
    for row in rows:
        now_ms = row["s"] * 1000 + row["m"]
        dt = None if previous_ms is None else now_ms - previous_ms
        segment_start = row['r'] != previous_segment
        valid = row["c"] in (1, 2)
        heading = clockwise(row["h"]) if valid else None
        change = None if segment_start or heading is None or previous_heading is None else (
            (heading - previous_heading + 180) % 360 - 180)
        if dt is not None and not segment_start:
            if dt < 0:
                backwards += 1
            elif dt > 0:
                intervals.append(dt)
        records.append({
            "test_input": int(test_input), "sample": row["i"], "marker": row["k"], "segment": row["r"], "segment_start": int(segment_start),
            "utc_seconds": row["s"], "utc_milliseconds": row["m"],
            "callback_time_ms": now_ms, "elapsed_ms": now_ms - first_ms,
            "interval_ms": dt, "clock_went_backward": int(dt is not None and dt < 0),
            "magnetic_native": row["h"], "true_native": row["t"],
            "magnetic_clockwise_degrees": None if heading is None else round(heading, 6),
            "true_clockwise_degrees": round(clockwise(row["t"]), 6) if valid and row["d"] else None,
            "status": row["c"], "declination_valid": row["d"],
            "change_degrees": None if change is None else round(change, 6),
            "observed_speed_degrees_per_second": round(change * 1000 / dt, 6)
                if change is not None and dt is not None and dt > 0 else None,
        })
        previous_ms, previous_heading, previous_segment = now_ms, heading, row["r"]
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as output:
        writer = csv.DictWriter(output, fieldnames=list(records[0]))
        writer.writeheader()
        writer.writerows(records)
    ordered = sorted(intervals)
    summary = {
        "test_input": bool(test_input), "samples": len(rows), "markers": sorted({row["k"] for row in rows}), "segments": sorted({row["r"] for row in rows}),
        "elapsed_ms": records[-1]["elapsed_ms"],
        "positive_interval_min_ms": min(intervals) if intervals else None,
        "positive_interval_median_ms": ordered[len(ordered) // 2] if ordered else None,
        "positive_interval_max_ms": max(intervals) if intervals else None,
        "backward_clock_steps": backwards,
        "invalid_samples": sum(row["c"] <= 0 for row in rows),
        "timestamp_source": "watch UTC clock at application compass callback entry",
        "raw_angle_units_per_turn": 65536,
    }
    path.with_suffix(".json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(f"CSV: {path.resolve()}", flush=True)
    print(json.dumps(summary, indent=2), flush=True)
    return summary


def convert(log, output):
    parser = ExportParser()
    for line in Path(log).read_text(encoding="utf-8", errors="replace").splitlines():
        parser.feed(line)
    if parser.complete is None:
        raise ValueError(parser.problem or "No complete export; keep app open and press DOWN again while capturing")
    return export_csv(parser.complete, output, bool(parser.header.get("test", 0)))


def capture(args):
    prefix = Path(args.output) if args.output else CAPTURES / datetime.now().strftime("compass-%Y%m%d-%H%M%S")
    prefix.parent.mkdir(parents=True, exist_ok=True)
    log_path, csv_path = prefix.with_suffix(".log"), prefix.with_suffix(".csv")
    if log_path.exists() or csv_path.exists():
        raise ValueError("Capture output already exists; choose a new --output prefix")
    command = ["pebble", "logs", "--emulator", "emery"] if args.emulator else ["pebble", "logs", "--phone", args.phone]
    print(f"Raw log: {log_path.resolve()}", flush=True)
    print("Connecting to developer logs. Press DOWN in Compass Lab when your recording is ready.", flush=True)
    parser = ExportParser()
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True, encoding="utf-8", errors="replace", bufsize=1, env=dict(os.environ, PYTHONUNBUFFERED="1"))
    try:
        with log_path.open("w", encoding="utf-8", buffering=1) as log:
            for line in process.stdout:
                log.write(line)
                result = parser.feed(line)
                if "CLAB B" in line:
                    print("Receiving watch recording...", flush=True)
                if result == "complete":
                    is_test = bool(parser.header.get("test", 0))
                    if is_test and not args.emulator:
                        raise ValueError("TEST build data received; install the production Compass Lab PBW for watch measurements")
                    export_csv(parser.complete, csv_path, is_test)
                    return
                if result:
                    print(f"{result}. Keep the app open; press DOWN again to retry.", flush=True)
                elif "CLAB" not in line:
                    # Surface connection failures and Pebble Tool status instead
                    # of leaving a silent listener when no watch is connected.
                    print(line.rstrip(), flush=True)
        raise ValueError(f"Developer log connection ended before a complete export (exit {process.wait()})")
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    live = sub.add_parser("capture", help="Wait for DOWN export and save a checked CSV plus raw log")
    source = live.add_mutually_exclusive_group(required=True)
    source.add_argument("--phone", help="Pebble developer connection IP[:port]")
    source.add_argument("--emulator", action="store_true")
    live.add_argument("--output", help="Output path prefix; default is a timestamp under apps/compass-lab/captures")
    saved = sub.add_parser("convert", help="Convert an existing complete CLAB log")
    saved.add_argument("log", type=Path)
    saved.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        if args.command == "capture": capture(args)
        else: convert(args.log, args.output)
    except (ValueError, OSError) as error:
        print(f"Compass Lab: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("Capture stopped; raw log retained. Watch recording can be exported again.", file=sys.stderr)
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
