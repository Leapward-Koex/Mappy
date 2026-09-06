#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$root/apps/compass-lab"
if pgrep -x qemu-pebble >/dev/null; then
  echo 'Another emulator is running; wait for its owner to finish.' >&2
  exit 75
fi
COMPASS_LAB_TEST_INPUT=1 pebble build
mkdir -p captures
log=captures/emulator-smoke.log
PYTHONUNBUFFERED=1 pebble install --emulator emery --logs build/compass-lab.pbw >"$log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; pebble kill >/dev/null 2>&1 || true' EXIT
sleep 5
pebble send-app-message --emulator emery --app-uuid 8a74f020-498f-46c8-992c-14925ca16d88 --int 0=0 2=2
pebble emu-button --emulator emery click select
pebble send-app-message --emulator emery --app-uuid 8a74f020-498f-46c8-992c-14925ca16d88 --int 0=0 2=2
sleep 1
pebble send-app-message --emulator emery --app-uuid 8a74f020-498f-46c8-992c-14925ca16d88 --int 0=49152 2=2
sleep 1
pebble emu-button --emulator emery click up
pebble send-app-message --emulator emery --app-uuid 8a74f020-498f-46c8-992c-14925ca16d88 --int 0=21845 2=1
sleep 1
pebble send-app-message --emulator emery --app-uuid 8a74f020-498f-46c8-992c-14925ca16d88 --int 0=65535 2=2
sleep 1
pebble screenshot --emulator emery --no-open captures/recording.png
pebble emu-button --emulator emery click select
pebble screenshot --emulator emery --no-open captures/paused.png
pebble emu-button --emulator emery click down
for attempt in $(seq 1 50); do
  if grep -q 'CLAB E' "$log"; then break; fi
  sleep 0.2
done
python3 "$root/tooling/compass-lab.py" convert "$log" --output captures/emulator-smoke.csv
python3 - <<'PY'
import csv
with open('captures/emulator-smoke.csv') as f: rows = list(csv.DictReader(f))
assert len(rows) >= 4, 'No injected compass callbacks captured'
assert all(r['test_input'] == '1' for r in rows), 'Test data must be clearly labeled'
assert len({r['magnetic_native'] for r in rows}) >= 3, 'Headings did not change'
assert {r['marker'] for r in rows} >= {'0', '1'}, 'UP marker missing'
assert {'1', '2'} <= {r['status'] for r in rows}, 'Calibration state not retained'
print('Emery capture/export: test compass callbacks, headings, marker and calibration passed')
PY

# Check the real desktop capture loop and re-export of the unchanged buffer.
kill "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true
prefix="captures/live-smoke-$(date +%Y%m%d-%H%M%S)"
python3 "$root/tooling/compass-lab.py" capture --emulator --output "$prefix" >"$prefix-output.log" 2>&1 &
pid=$!
sleep 2
pebble emu-button --emulator emery click down
for attempt in $(seq 1 50); do
  if ! kill -0 "$pid" 2>/dev/null; then break; fi
  sleep 0.2
done
if kill -0 "$pid" 2>/dev/null; then echo 'Live capture timed out' >&2; exit 1; fi
wait "$pid"
cat "$prefix-output.log"
cmp captures/emulator-smoke.csv "$prefix.csv"
echo 'Live collector: verified identical CSV from repeated watch export'
