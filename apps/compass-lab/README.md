# Compass Lab

A separate, minimal Pebble Time 2 / Emery app for collecting the actual compass
callbacks that drive Mappy. Its UUID is different from Mappy, so both can remain
installed. There is no map, smoothing, prediction, phone companion, or live log
stream during recording.

## On the watch

The screen shows clockwise **magnetic bearing**, calibration status, the most
recent callback interval, marker number, recording state, and sample count.
The displayed angle has one decimal place; the recording retains the exact
native heading integer.

- **SELECT** starts or pauses recording. Press again to resume into a new segment.
- **UP** starts another numbered marker: use it before each different turn.
- **DOWN** pauses recording and exports the retained samples to developer logs.
  Start the computer capture command below before pressing DOWN.
- **Hold UP** for 1.2 seconds while paused to clear the buffer.
- **BACK** pauses and reminds you to export. **Hold BACK** for 1.2 seconds to exit.

The buffer holds **2,048 samples**, about 6 minutes 49 seconds at 5 callbacks/s,
or 1 minute 42 seconds at 20 callbacks/s. Recording stops when full; old samples
are never overwritten. No flash or Bluetooth writes happen during recording.

**Recordings are held in RAM. Export before exiting or restarting the app.**
A completed export leaves the buffer intact, so DOWN can send it again. The watch
says "Export sent"; the computer validates whether every row actually arrived.

## Install and capture from this computer

Build:

```powershell
.\tooling\compass-lab.ps1 build
```

Output: `apps/compass-lab/dist/compass-lab-0.1.0.pbw`.

Install with the Android phone connected by USB, USB debugging authorized, the
watch connected in the Pebble app, and the phone/PC on the same LAN:

```powershell
.\tooling\compass-lab.ps1 install
```

Record on the watch. When ready to export, run:

```powershell
.\tooling\compass-lab.ps1 capture
```

Then press **DOWN on the watch**. The command saves a checked `.csv`, a raw `.log`,
and a timing-summary `.json` in `apps/compass-lab/captures/`, and exits after a
complete export. Codex can read those files directly from this workspace.
The helper opens the same Pebble developer connection used by the existing
Mappy installer. With more than one USB phone, supply `-DeviceSerial`.

If using a manually enabled Pebble developer connection instead of USB discovery:

```powershell
.\tooling\compass-lab.ps1 install -PhoneAddress 192.168.1.20:9000
.\tooling\compass-lab.ps1 capture -PhoneAddress 192.168.1.20:9000
```

Use the address shown by your Pebble app. Do not run the normal Mappy release
installer for this app; it installs Mappy's PBW.

Exports run at 20 rows/s to avoid flooding developer-log transport. Allow up to
about two minutes for a completely full buffer. The computer checks sample
indices, counts, schema, and end marker. It refuses to treat a partial recording
as complete and asks you to press DOWN again if rows are missing. Keep the app
open until the computer prints its CSV path. Ctrl+C stops the computer listener
without deleting the watch buffer or partial raw log.

From WSL, the equivalent collector is:

```sh
python3 tooling/compass-lab.py capture --phone 192.168.1.20:9000
```

An existing log can be converted again with:

```sh
python3 tooling/compass-lab.py convert recording.log --output recording.csv
```

## Suggested first recording

Wait for **Calibrated**, then press SELECT. Hold still for three seconds. Press
UP and turn roughly 45 degrees, then hold still for three seconds. Use another
marker for 90 degrees, then another for a quick 150-degree turn. Repeat left
and right, using the same wrist posture as Mappy. Exact angles are unnecessary;
markers plus a note about which turns visibly jumped are more useful.

Keep the recorder running during each turn and its following hold. Pause between
sets if needed. No special walking or route setup is required.

## Check physical angles before tuning Mappy

The first watch recording measured callback timing, but a subsequent check on
Pebble Time 2 firmware 4.36.2 showed approximately half-angle movement in this
unsmoothed app. A calibrated status does not independently prove accurate
bearings. Do not rescale the export or assume its reported speed equals wrist
speed; preserve the native values for diagnosis.

For a fresh calibration, leave Compass Lab open, briefly attach the charger
until charging registers, then remove it. Move away from the charger, phone,
magnets and metal furniture. Rotate and tilt the watch in several directions
until it reports Calibrated. Pebble documents charging as clearing saved
calibration; the same reset is present in the firmware 4.36.2 compass service.

Then hold the watch face level and rotate in known 90-degree increments through
a complete turn, pausing for two seconds at each position. A paper right-angle
reference helps check relative angles without relying on another magnetometer.
Use UP to mark each held position, and record both clockwise and counterclockwise
turns. Note any compressed angular range, reversal, or jump. Only after this
check passes should another set of moderate/quick wrist sweeps be used to tune
prediction. Keep the existing controller while diagnosing incorrect raw input.

References: [Pebble compass calibration guide](https://developer.repebble.com/guides/events-and-services/compass/),
[firmware 4.36.2 reset and heading calculation](https://github.com/coredevices/PebbleOS/blob/v4.36.2/src/fw/services/ecompass/service.c#L228).

## Data and timing

Every real CompassService callback is retained while recording, including
unchanged headings and invalid/calibrating states. The service is subscribed
with heading filter zero; this removes application-side angular suppression,
but does not change the firmware's sampling frequency. There are no repeated
`peek()` readings or synthetic samples.

Each sample contains:

- UTC seconds and milliseconds taken immediately on callback entry.
- Exact SDK magnetic and true-heading integers (65,536 units per full turn,
  counterclockwise), status, and the SDK declination-valid flag.
- Marker and recording-segment numbers.

These are **application callback arrival times**, not hardware acquisition
timestamps; the Compass API does not supply an acquisition timestamp. These are
also SDK compass bearings, not raw magnetometer X/Y/Z measurements. SDK true
heading is currently documented as reserved; the exporter only presents true
bearing as meaningful when the SDK marks declination valid.

The CSV adds clockwise degrees, elapsed time, intervals, shortest angular
changes, and observed angular velocity. It keeps all native values and original
timestamps. Invalid bearings stay blank in the derived degree columns.
Intervals at segment boundaries reflect the user pause and are excluded from
rate statistics; derived velocity also restarts at each segment.

UTC clocks can move backward or forward after synchronization. Backward steps
are flagged and preserved, never silently repaired. This matters in QEMU, where
RTC discontinuities were seen during earlier compass tests. Check clock flags
and segment boundaries before interpreting an interval as sensor latency.

The UI redraws at most 10 times per second and does not set the recording rate.
Exports happen only after recording is paused; sample callbacks do no logging,
allocation, flash writes, or display drawing.

## Development validation

```sh
bash apps/compass-lab/tests/host.sh
bash apps/compass-lab/tests/smoke.sh
```

The host tests cover raw precision, identical/invalid readings, markers,
pause/resume segments, capacity without overwrite, north crossings, partial and
duplicate exports, CSV conversion, and clock discontinuities. The smoke test
owns an Emery emulator, builds with explicit test inputs, injects compass headings/calibration states, operates
record/marker/pause/export buttons, captures screenshots, and validates the CSV.
It refuses to interrupt another running emulator. It also runs the desktop live
collector and verifies that exporting the same buffer again produces an identical
CSV. Test builds display `COMPASS LAB - TEST` and exported data carries
`test_input=1`; the physical-watch collector rejects such data.

This installed QEMU/firmware combination returned compass-unavailable and decoder
errors when using `emu-compass`, so the UI/export test uses AppMessage injection
compiled only with `COMPASS_LAB_TEST_INPUT=1`. The production build/install helper
explicitly disables that flag. Hardware compass sampling still needs checking on
the physical watch; emulator fixture timing is not evidence of sensor cadence.

Verified with Pebble Tool 5.0.40, SDK 4.33.1 and Emery QEMU 10.1.5-pebble14:
recorder host tests (including undefined-behavior sanitizer), six CSV/export
tests, the emulator UI/control/export flow, and live desktop collection all
passed. Re-exporting the retained buffer produced an identical CSV. Production
uses approximately 44 KiB of linked RAM, well below the 65,535-byte executable
limit; the sample buffer accounts for 40 KiB of that. The first physical capture retained 71 calibrated callbacks over 23.656 seconds,
with a 398 ms median interval; its angle-accuracy limitation is described above.
