#!/usr/bin/env python3
"""Capture Pebble QEMU monitor screendumps for emulator visual checks."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import socket
import time
from uuid import UUID


DEFAULT_STATE_FILE = Path("/tmp/pb-emulator.json")


def emulator_state(platform: str, state_file: Path) -> dict:
    data = json.loads(state_file.read_text(encoding="utf-8"))
    platform_data = data.get(platform)
    if not platform_data:
        raise SystemExit(f"No running {platform} emulator found in {state_file}")
    live_versions = sorted(platform_data)
    return platform_data[live_versions[-1]]


def set_app_running(platform: str, state_file: Path, uuid_text: str, running: bool) -> None:
    from libpebble2.communication import PebbleConnection
    from libpebble2.communication.transports.websocket import WebsocketTransport
    from libpebble2.protocol.apps import AppRunState, AppRunStateStart, AppRunStateStop

    state = emulator_state(platform, state_file)
    port = state["pypkjs"]["port"]
    pebble = PebbleConnection(WebsocketTransport(f"ws://127.0.0.1:{port}/"))
    pebble.connect()
    packet_type = AppRunStateStart if running else AppRunStateStop
    pebble.send_packet(AppRunState(data=packet_type(uuid=UUID(uuid_text))))
    action = "launched" if running else "stopped"
    print(f"[pebble-qemu-capture] {action} {uuid_text} on {platform}", flush=True)


def screendump(monitor_port: int, out_path: Path) -> None:
    with socket.create_connection(("127.0.0.1", monitor_port), timeout=1.0) as sock:
        sock.sendall(f"screendump {out_path.as_posix()}\n".encode("ascii"))
        sock.settimeout(0.2)
        try:
            sock.recv(1024)
        except Exception:
            pass


def capture(args: argparse.Namespace) -> int:
    out_dir = args.out_dir.resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    state = emulator_state(args.platform, args.state_file)
    monitor_port = state["qemu"]["monitor"]

    if args.stop_before_launch and args.app_uuid:
        set_app_running(args.platform, args.state_file, args.app_uuid, False)
        time.sleep(args.stop_settle_seconds)

    start = time.time()
    launched = False
    errors: list[str] = []
    for index in range(args.frames):
        elapsed = time.time() - start
        if not launched and args.app_uuid and elapsed >= args.launch_after_seconds:
            set_app_running(args.platform, args.state_file, args.app_uuid, True)
            launched = True

        target = start + index * args.interval_seconds
        delay = target - time.time()
        if delay > 0:
            time.sleep(delay)

        try:
            screendump(monitor_port, out_dir / f"frame_{index:04d}.ppm")
        except Exception as exc:
            errors.append(f"{index}: {exc}")

    summary = out_dir / "capture-summary.txt"
    summary.write_text(
        "\n".join(
            [
                f"platform={args.platform}",
                f"monitor_port={monitor_port}",
                f"frames_attempted={args.frames}",
                f"interval_seconds={args.interval_seconds}",
                f"errors={len(errors)}",
                f"elapsed={time.time() - start:.3f}",
                *errors,
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    print(f"Capture: {out_dir}", flush=True)
    print(f"Summary: {summary}", flush=True)
    return 0 if not errors else 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", default="emery")
    parser.add_argument("--state-file", type=Path, default=DEFAULT_STATE_FILE)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--frames", type=int, default=180)
    parser.add_argument("--interval-seconds", type=float, default=0.05)
    parser.add_argument("--app-uuid")
    parser.add_argument("--stop-before-launch", action="store_true")
    parser.add_argument("--stop-settle-seconds", type=float, default=0.5)
    parser.add_argument("--launch-after-seconds", type=float, default=0.5)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    if args.frames <= 0:
        raise SystemExit("--frames must be positive")
    if args.interval_seconds <= 0:
        raise SystemExit("--interval-seconds must be positive")
    return capture(args)


if __name__ == "__main__":
    raise SystemExit(main())
