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
  echo "Expected build, check, or install." >&2
  exit 2
fi
phone="${2:?Phone address required}"
release="${3:?Release filename required}"
[[ "$release" != */* && "$release" == mappy-watch-*-phone.pbw ]] || exit 2

# Probe from WSL, where Windows ADB's loopback forward is not accessible in NAT mode.
python3 - "$phone" <<'PY'
import socket, sys, time
host, separator, port = sys.argv[1].partition(":")
port = int(port) if separator else 9000
if not 1 <= port <= 65535:
    raise SystemExit("Invalid phone port.")
for attempt in range(3):
    try:
        with socket.create_connection((host, port), timeout=3):
            break
    except OSError as error:
        if attempt == 2:
            raise SystemExit("Cannot reach the Pebble developer connection at %s: %s. Open the Pebble app, enable its LAN developer connection, and put phone and PC on the same network." % (sys.argv[1], error))
        time.sleep(1)
PY
unset PEBBLE_EMULATOR PEBBLE_ADB PEBBLE_BT_SERIAL PEBBLE_QEMU PEBBLE_PHONE PEBBLE_CLOUDPEBBLE
if [[ "$operation" == check ]]; then
  exec pebble ping --phone "$phone"
else
  exec pebble install --phone "$phone" "dist/$release"
fi
