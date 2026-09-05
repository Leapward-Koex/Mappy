#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR/apps/pebble-watch"
operation="${1:?Expected build, check, or install}"
if [[ "$operation" == build ]]; then
  export MAPPY_WATCH_HARDWARE_PERF=0
  exec make --jobs=1 release
fi
if [[ "$operation" != check && "$operation" != install ]]; then
  echo "Expected build, check, or install" >&2
  exit 2
fi
phone="${2:?Phone address required}"
release="${3:?Release filename required}"
if [[ "$release" == */* || "$release" != mappy-watch-*-phone.pbw ]]; then
  echo "Invalid release filename" >&2
  exit 2
fi
[[ -f "dist/$release" ]] || { echo "Release PBW is missing" >&2; exit 2; }

python3 - "$phone" <<'PY'
import socket
import sys
import time

host, separator, port = sys.argv[1].partition(":")
port = int(port) if separator else 9000
if not 1 <= port <= 65535:
    raise SystemExit("Developer connection port must be between 1 and 65535.")
for attempt in range(3):
    try:
        with socket.create_connection((host, port), timeout=3):
            break
    except OSError as error:
        if attempt == 2:
            raise SystemExit(
                f"Cannot reach Pebble developer connection at {host}:{port}: {error}. "
                "Enable its LAN developer connection and connect the phone and PC to the same LAN."
            )
        time.sleep(1)
PY

unset PEBBLE_EMULATOR PEBBLE_ADB PEBBLE_BT_SERIAL PEBBLE_QEMU PEBBLE_PHONE PEBBLE_CLOUDPEBBLE
if [[ "$operation" == check ]]; then
  exec pebble ping --phone "$phone"
else
  exec pebble install --phone "$phone" "dist/$release"
fi
