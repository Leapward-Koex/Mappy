# Mappy Pebble Watch App

Native Pebble SDK watch app for Mappy.

## Target

- Watch: Pebble Time 2
- Pebble platform: `emery`
- Environment check: from the repository root run
  `.\tooling\pebble-wsl.ps1 doctor` in Windows PowerShell, or
  `bash tooling/pebble-emulator-codex.sh doctor` in WSL2.
- SDK setup or update: run `tooling/bootstrap-pebble-sdk-wsl.sh` from the
  repository root in WSL2. It requires network access and `sudo`.

The Pebble metadata keeps `sdkVersion` at `"3"` because that is the current
Pebble local-project metadata value. The actual installed SDK is managed by the
Pebble CLI.

The bootstrap script installs or activates the newest SDK reported by Pebble
Tool, so it can be rerun after an SDK is already installed. The `doctor`
command is the authoritative local readiness check.

## Make Targets

From `apps/pebble-watch` in WSL2, you can now use:

```sh
make release
```

That builds the production phone-mode watch app and copies a sideloadable PBW to:

```text
dist/mappy-watch-<version>-phone.pbw
```

For the emulator-style fixture variant, use:

```sh
make release-fixture
```

That builds with `MAPPY_WATCH_PHONE_MODE=fixture` and writes:

```text
dist/mappy-watch-<version>-fixture.pbw
```

`release-fixture` is development-only and must not be used as the production
watch package. `make build`, `make build-phone`, and `make build-fixture` leave
the raw Pebble output in `build/` without copying a release artifact.

## Emulator workflow for Codex

Run the portable helper from Windows PowerShell:

```powershell
# from the repository root
.\tooling\pebble-wsl.ps1 capture-phone
```

The direct WSL2 equivalent is:

```sh
# from the repository root
bash tooling/pebble-emulator-codex.sh capture-phone
```

This builds the default production-phone mode app, launches the `emery`
emulator, installs the PBW, and writes a screenshot to:

```text
apps/pebble-watch/codex-emulator/latest.png
```

The default mode keeps `src/pkjs/index.js` as a no-op so the real Android phone
runtime owns AppMessage responses. For emulator-only map rendering without a
phone, use the fixture build:

```sh
bash tooling/pebble-emulator-codex.sh capture-fixture
```

`capture-fixture` builds with `MAPPY_WATCH_PHONE_MODE=fixture` and bundles the
deterministic synthetic-map responder. It must not be used for production PBWs.
Use `capture-phone` or `MAPPY_WATCH_PHONE_MODE=phone` to force the production
path. Fixture captures wait briefly after install so the screenshot catches
loaded tiles; override with `PEBBLE_CAPTURE_DELAY_SECONDS=<seconds>`.

For local testing with the generated provider-map capture, use the explicit
real-fixture path:

```sh
bash tooling/pebble-emulator-codex.sh capture-real-fixture
```

This builds with `MAPPY_WATCH_PHONE_MODE=real-fixture` and loads
`tooling/real-map-fixtures/generated/pebble-map-real-fixture-pkjs.js`. The
generated files may be kept locally for emulator work, but are ignored by
default so a clean public export does not redistribute provider-derived map
data. If they are absent or deliberately need refreshing, regenerate them with
`.\tooling\pebble-wsl.ps1 generate-real-fixture` from Windows or
`bash tooling/pebble-emulator-codex.sh generate-real-fixture` from WSL. The
helper uses Pebble Tool's Python environment, including Pillow. The generator
reads the API key from the process environment, repository-root `.env.local`,
or legacy Android `local.properties`; it writes the real-fixture PKJS path
automatically and never embeds the credential or provider session token.
Refreshing performs live provider API requests and may incur usage. The
synthetic `fixture` mode remains the reproducible, publication-safe default for
emulator and CI testing.

### Tile-cache memory

Watch tiles remain compressed while cached in a fixed 46 KiB arena. Normal map
tiles use the existing RLE bytes plus bounded lookup checkpoints; high-entropy
tiles fall back to packed 4-bit pixels. A single 6,804-byte scratch tile is
shared for validation and north-up rendering. Arena eviction compacts storage,
prefers offscreen and retained zoom-fallback tiles, and preserves rendered
center tiles when an unusually large grid still exceeds the arena.

Run the host codec, geometry, malformed-input, and arena-bound checks with:

```sh
bash tooling/pebble-emulator-codex.sh test-tile-cache-host
```

Run the pixel-exact face-forward raster property tests and comparative host
benchmark with:

```sh
bash tooling/pebble-emulator-codex.sh test-face-forward-render-host
```

Run the whole-frame Emery gates at representative face-forward bearings with:

```sh
bash tooling/pebble-emulator-codex.sh test-face-forward-angles
```

Codex can inspect that PNG directly from Windows. Emulator button input can be
sent with:

```sh
bash tooling/pebble-emulator-codex.sh button click select
bash tooling/pebble-emulator-codex.sh screenshot after-select.png
```

Use `PEBBLE_PLATFORM=<platform>` to test another supported Pebble platform.

### Debug compass injection

The emulator does not provide reliable live compass data for face-forward map
rotation. For rotation debugging, install a fixture build and inject a simulated
watch compass heading:

```sh
bash tooling/pebble-emulator-codex.sh capture-fixture
bash tooling/pebble-emulator-codex.sh debug-facing 45
bash tooling/pebble-emulator-codex.sh screenshot debug-facing-45.png
```

`debug-facing <degrees>` switches centered-map orientation to face-forward and
then sends `CMD_DEBUG_COMPASS` with a heading from `0` to `359`. Use
`debug-compass clear` to clear the simulated compass heading. To exercise
large-tile rotation without a phone tile payload, use:

```sh
bash tooling/pebble-emulator-codex.sh debug-map-settings 108 126
bash tooling/pebble-emulator-codex.sh debug-facing 45
bash tooling/pebble-emulator-codex.sh debug-tile 0
```

### Motion-assisted face-forward reacquisition

During an active face-forward Walk route, the production watch app samples the
accelerometer at 25 Hz in batches of five. A fixed-memory classifier recognizes
walking followed by a stable wrist raise and temporarily accelerates bearing
animation. It unsubscribes during menus, manual browse, non-Walk routes,
north-up mode, and after route completion. Raw motion samples never leave the
watch.

The classifier and bearing profiles have a host test that does not require an
emulator:

```sh
bash tooling/pebble-emulator-codex.sh test-motion-host
```

With a fixture build and active face-forward Walk route, deterministic sensor
traces can be replayed directly through the emulator accelerometer channel:

```sh
bash tooling/pebble-emulator-codex.sh debug-motion stationary-raise
bash tooling/pebble-emulator-codex.sh debug-motion walking-to-look
```

`test-motion-reacquire` automates the fixture route, negative stationary-raise
case, walking-to-look transition, compass target change, 2–8 animation-tick
assertion, log capture, and final screenshot. It exits without installing,
wiping, or stopping anything when an emulator session is already running.

For consumed-route overlay debugging, start a fixture route from the watch, then
move the debug GPS fix along the active route:

```sh
bash tooling/pebble-emulator-codex.sh debug-route-progress 0
bash tooling/pebble-emulator-codex.sh debug-route-progress 50
bash tooling/pebble-emulator-codex.sh debug-route-progress 25
```

The value is a percent from route start to destination. Moving from a higher
percent back to a lower percent should reveal previously hidden dots or route
line segments.

## Codex skill

The repository publishes `.agents/skills/pebble-emulator/SKILL.md`. Codex can
discover that skill from the repository root; invoke `$pebble-emulator` when a
task involves the Mappy watch app, its emulator, PBW builds, screenshots,
fixtures, input, protocol debugging, or watch performance checks.

For production work, `src/pkjs/index.js` stays no-op and the Android native
companion remains the intended responder unless the specs are explicitly
changed.

## Current Scope

This app contains the native MVP map, route, input, and AppMessage surfaces plus
the no-op PebbleKit JS entrypoint required by the Pebble SDK project layout.

Touch input is compiled behind `PBL_TOUCH`. The current visible SDK touch event
shape used by the app exposes a single contact point, so the watch implements
real-device touch panning and records a bounded `pinch unavailable` diagnostic;
hardware buttons remain the zoom fallback until an `emery` SDK/hardware build
exposes reliable pinch or multi-touch data.

The current production decision is therefore no-pinch fallback, not synthetic
pinch. Touch panning sends no touch-specific AppMessage command, and fallback
diagnostics are emitted as `CMD_LOG_EVENT` records that Android maps to
`pinch_unavailable`, `touch_disabled`, and `zoom_clamped`.
