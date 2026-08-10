# Pebble Emulator Fixture Mode Spec

This spec defines the development-only watch build mode used to verify the
Pebble emulator without a real Android phone transport.

Production watch builds must continue to use the Android-native phone runtime.
Fixture mode exists only for emulator and CI-style watch rendering checks.

## Build Modes

The watch app supports three build-time phone modes:

| Mode | Build flag | PKJS entrypoint | Purpose |
| --- | --- | --- | --- |
| `phone` | `MAPPY_WATCH_PHONE_MODE=phone` | `src/pkjs/index.js` | Production/default. The watch sends AppMessage commands to the real phone runtime. |
| `fixture` | `MAPPY_WATCH_PHONE_MODE=fixture` | `src/pkjs/fixture-index.js` | Emulator-only. Bundles deterministic synthetic payloads and responds locally through PebbleKit JS. |
| `real-fixture` | `MAPPY_WATCH_PHONE_MODE=real-fixture` | `src/pkjs/real-fixture-index.js` | Local emulator-only mode. Bundles a locally generated provider-map capture when that ignored file is present. |

`phone` is the default for normal `pebble build` and for the watch package that
ships with the Android companion.

## Fixture Mode Requirements

Fixture mode must:

- be opt-in through a build-time flag or an explicit emulator tooling command,
- generate deterministic synthetic map, route, and destination payloads with no API key,
- send startup settings, destinations, GPS, map tiles, route points, and nav
  steps through the same AppMessage command IDs used by production,
- make screenshots visibly distinct during startup before GPS/tiles arrive,
- avoid any provider or network request at runtime,
- remain scoped to Pebble emulator testing and local development.

Fixture mode must not:

- be enabled by default,
- be used for production PBWs,
- store or request user credentials,
- replace Android-native transport in the production architecture,
- run in parallel with the Android-native phone worker.

`real-fixture` has the same production isolation requirements as `fixture`.
Its provider-derived generated files are useful local test inputs, but they are
excluded from clean public exports by default. Keeping or regenerating them
locally is supported; committing or redistributing them requires a separate
provider-terms review. The source-controlled synthetic fixture remains the CI
and publication-safe baseline.

## Tooling

The repository Pebble helper must expose explicit fixture-mode commands:

```sh
bash tooling/pebble-emulator-codex.sh doctor
bash tooling/pebble-emulator-codex.sh test-tooling
bash tooling/pebble-emulator-codex.sh test-protocol
bash tooling/pebble-emulator-codex.sh smoke-fixture
bash tooling/pebble-emulator-codex.sh build-fixture
bash tooling/pebble-emulator-codex.sh install-fixture
bash tooling/pebble-emulator-codex.sh capture-fixture
bash tooling/pebble-emulator-codex.sh build-fixture-animation
bash tooling/pebble-emulator-codex.sh install-fixture-animation
bash tooling/pebble-emulator-codex.sh capture-fixture-animation
bash tooling/pebble-emulator-codex.sh record-fixture-animation
bash tooling/pebble-emulator-codex.sh build-real-fixture
bash tooling/pebble-emulator-codex.sh install-real-fixture
bash tooling/pebble-emulator-codex.sh capture-real-fixture
bash tooling/pebble-emulator-codex.sh generate-real-fixture
```

`tooling/pebble-wsl.ps1` must expose the same commands from Windows
PowerShell, translate the repository path into WSL, and preserve all command
arguments.

The production/default equivalents remain:

```sh
bash tooling/pebble-emulator-codex.sh build-phone
bash tooling/pebble-emulator-codex.sh install-phone
bash tooling/pebble-emulator-codex.sh capture-phone
```

The helper may also honor `MAPPY_WATCH_PHONE_MODE=phone|fixture|real-fixture` for direct
builds. `PEBBLE_PHONE_MODE` is an allowed alias.

Fixture capture tooling may wait briefly after install before taking a
screenshot so the generated GPS and tile messages can finish loading. The delay
must be overrideable for debugging.

Animated tile loading checks may use fixture-only tile response controls:

| Variable | Meaning |
| --- | --- |
| `MAPPY_FIXTURE_TILE_DELAY_MS` | Hold the first fixture tile response so placeholder/loading frames are visible. |
| `MAPPY_FIXTURE_TILE_STAGGER_MS` | Add this delay per requested tile so tile arrivals are visually separated. |
| `MAPPY_FIXTURE_TILE_ANIMATION_MODE` | Send startup `CMD_TILE_ANIMATION`; `-1` leaves the watch value unchanged, `0`, `1`, and `2` force the protocol modes. |

The `*-fixture-animation` helper commands are aliases for fixture mode with
development defaults suitable for emulator capture. They must remain opt-in and
must not affect phone-mode builds.

`record-fixture-animation` may additionally start a clean emulator, install the
watch app, and capture QEMU monitor screendumps while the delayed fixture tiles
arrive. Capture frequency must leave enough emulator time for app install,
PebbleKit JS, and rendering to progress. This is a visual test harness only; it
must not be required for production builds.

## Acceptance Criteria

- `MAPPY_WATCH_PHONE_MODE=phone pebble build` bundles only the no-op PKJS
  entrypoint and excludes fixture responder sources from the phone build inputs.
- `MAPPY_WATCH_PHONE_MODE=fixture pebble build` bundles the fixture PKJS
  entrypoint.
- `MAPPY_WATCH_PHONE_MODE=real-fixture pebble build` bundles the local
  provider-map fixture when it exists and fails with an actionable message when
  it does not.
- `capture-phone` installs and screenshots the production phone-waiting watch
  path.
- `capture-fixture` installs and screenshots a nonblank map using generated
  fixture tiles without a connected phone.
- `capture-real-fixture` installs and screenshots the locally generated
  provider-map capture without changing the production or synthetic modes.
- `capture-fixture-animation` installs the same fixture with delayed,
  staggered tile responses and can show placeholder frames followed by visible
  tile arrivals.
- `record-fixture-animation` writes a frame sequence spanning a fresh app
  launch through visible tile arrival and can be encoded into a video/contact
  sheet for animation review.
- `doctor` verifies the active Pebble Tool, SDK, Emery QEMU, and Python helper
  dependencies, and fails when the installation reports an available update.
- `test-tooling` validates helper syntax, credential resolution without live
  requests, and the repository skill's required command coverage.
- `smoke-fixture` produces a nonempty screenshot and stops the emulator on both
  success and failure.
- `generate-real-fixture` can load a credential from repository-root
  `.env.local` without printing or embedding it.
- Static scans can distinguish fixture-only PKJS responders from production
  PKJS.
