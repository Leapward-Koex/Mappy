---
name: pebble-emulator
description: Build, test, debug, and capture the Mappy Pebble watch app with the repository's WSL2 Pebble Tool workflow. Use for Pebble CLI/SDK setup checks, Emery emulator runs, PBW builds, screenshots, deterministic or provider-backed fixtures, input/protocol debugging, animation capture, and memory or performance regression checks under apps/pebble-watch. Do not use for unrelated watchface projects.
---

# Pebble Emulator

Use the repository helpers instead of reconstructing Pebble commands by hand. They keep phone and fixture builds separate, use the active SDK, recover the emulator when practical, and put captures under `apps/pebble-watch/codex-emulator/`.

## Start with the environment check

Run this from Windows PowerShell at the repository root:

```powershell
.\tooling\pebble-wsl.ps1 doctor
```

From an existing WSL shell, run:

```bash
bash tooling/pebble-emulator-codex.sh doctor
```

Treat any nonzero result as an environment failure. The check verifies Pebble Tool, the active SDK, Emery SDK files, QEMU, Node/npm, and the Python modules used by screenshots and fixture generation. It also reports when a newer CLI or SDK is available.

Run `tooling/bootstrap-pebble-sdk-wsl.sh` only when the user has authorized setup or an update because it uses `sudo`, the network, and the Python package index. It is safe to rerun and activates the newest installed SDK. This workflow was last exercised with Pebble Tool 5.0.39, SDK 4.17, and QEMU 10.1.5-pebble14; rely on `doctor`, not these version strings, to determine current readiness.

## Choose a test mode

| Mode | Purpose | Primary command |
| --- | --- | --- |
| `phone` | Production PBW using the Android companion | `build-phone` or `capture-phone` |
| `fixture` | Deterministic offline tiles, route, menu, and input | `smoke-fixture` or `capture-fixture` |
| `real-fixture` | Saved provider responses without a live request during the emulator run | `capture-real-fixture` |
| animation fixture | Reproducible tile-load motion and frame recording | `record-fixture-animation` |

Prefer `fixture` for normal development and regression testing. Use `phone` before handing off a release build. Use `real-fixture` only when the saved provider rendering is relevant.

## Follow the normal verification loop

From Windows PowerShell, run:

```powershell
.\tooling\pebble-wsl.ps1 test-tooling
.\tooling\pebble-wsl.ps1 test-protocol
.\tooling\pebble-wsl.ps1 test-motion-host
.\tooling\pebble-wsl.ps1 test-tile-cache-host
.\tooling\pebble-wsl.ps1 build-phone
.\tooling\pebble-wsl.ps1 smoke-fixture
```

The equivalent WSL form is `bash tooling/pebble-emulator-codex.sh <command>`.

After `smoke-fixture`, inspect `apps/pebble-watch/codex-emulator/latest.png`; a nonempty PNG is necessary but not sufficient. Check that the map, route, marker, labels, and current menu/input state are visually plausible. The smoke command stops the emulator even when capture fails.

When changing watch C code, compare the build's flash and RAM figures with the preceding result. Do not accept a performance or memory regression merely to simplify implementation.

## Build and capture deliberately

Useful commands are:

```text
build-phone
build-fixture
build-real-fixture
capture-phone
capture-fixture
capture-real-fixture
screenshot [name]
install
kill
wipe
```

Run `capture-*` when a clean build-install-launch-screenshot sequence is wanted. Use `screenshot` for an already running emulator. Always run `kill` after interactive investigation if the selected command does not stop it automatically.

## Exercise input and protocol states

With the fixture emulator running, use:

```text
button <action> <button>
debug-facing <degrees>
debug-compass <degrees|clear>
debug-manual-browse <degrees>
debug-recenter <degrees>
debug-map-settings <width> <height>
debug-tile [index]
debug-route-progress <percent>
debug-motion <stationary-raise|walking-to-look>
```

Capture a screenshot after state changes that affect rendering. If a debug command fails, collect the command output and `pebble logs --emulator emery`; do not assume the message reached the watch.

For motion-assisted face-forward work, run `test-motion-host` before using the
emulator. Use `test-motion-reacquire` for the owned fixture-emulator sequence;
it replays both deterministic accelerometer traces, asserts one watch-look
event and a 2–8 tick fast bearing animation, and captures the final state. The
command refuses to run while another QEMU session exists and does not use the
wipe-and-retry path.

## Work with provider-backed fixtures safely

Keep generated provider fixture files local and ignored. The emulator reads the saved fixture and does not call the provider.

To intentionally refresh a fixture, run:

```powershell
.\tooling\pebble-wsl.ps1 generate-real-fixture
```

The generator resolves the key in this order: explicit option, process environment, repository-root `.env.local`, then legacy Android `local.properties`. Prefer `.env.local`; never print the key, paste it into a command line, commit it, or include it in logs or screenshots. Refreshing a fixture performs live provider API requests and may incur usage, so do it only when the task requires fresh data.

Do not remove useful existing generated fixtures merely because they are not publication candidates. Verify publication safety through ignore rules instead.

## Record animation efficiently

Start with a short capture before recording a long sequence. In WSL:

```bash
PEBBLE_QEMU_CAPTURE_FRAMES=12 PEBBLE_QEMU_CAPTURE_INTERVAL=0.2 \
  bash tooling/pebble-emulator-codex.sh record-fixture-animation skill-smoke
```

Inspect `capture-summary.txt` and require `errors=0`. Review representative frames for progression and visual correctness. Increase frames only after the short run succeeds; the default 60 frames at 0.2 seconds provides a reliable full sequence without starving the emulator. Stop the emulator when finished.

## Diagnose failures

1. Run `doctor` again and retain its output.
2. Run `test-tooling` to distinguish helper/guide drift from an SDK failure.
3. Run the failing build command directly and do not install an older PBW after a failed build.
4. For emulator failures, run `kill`, then retry once; use `wipe` only when persisted emulator state is the likely cause.
5. For fixture failures, confirm the selected mode and required generated file before changing application logic.
6. Report the exact command, nonzero output, active CLI/SDK/QEMU versions, and capture path.

Finish by reporting the build mode, tests run, emulator platform, visual result, memory figures when applicable, and any skipped live-provider operation.
