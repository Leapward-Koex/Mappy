# Tile pipeline v4: implementation and measured results

Measured 5 September 2026. Android source sharing, adaptive watch codecs and the
fixed day appearance are implemented. Phone and watch require protocol v4
together. Production retains 3,072-byte chunks, ACK-driven sending, complete-tile
serialization, control/GPS priority and a **30 ms** tile-to-tile pause. Paired-watch
Bluetooth acceptance remains pending; the measurements below do not estimate it.

## Implementation

Four dedicated source workers share downloads, session renewal and bitmap decode
across crops; crop workers are separate. Shared initial/renewed sessions, sources
and identical renders have consumer leases. Each request captures credentials,
generation, Android identity and settings. Obsolete consumers leave independently;
only the final consumer cancels a shared HTTP operation. Credential changes and
shutdown invalidate provider work. Cancellation is not a provider-validation error.

The original downloaded-byte cache remains alongside an 8 MiB decoded-pixel LRU.
Each bitmap is bulk-read once and recycled. Crops use primitive array sampling;
exact day lookup tables replace floating-point conversion and palette scans.
Successful binary HTTP responses skip UTF-8 conversion. Typed results carry
geometry, codec, bytes and preparation metrics into dispatch and Flutter.

The pinned pure-Java safe fast compressor is `at.yawk.lz4:lz4-java:1.11.2`.
Formats 1/2/3/4 are RLE, packed4, LZ4-packed4 and LZ4-RLE. The encoder preserves
the watch's original indexed-RLE/packed storage choice before choosing the
smallest compatible payload. Raw formats win ties. The bounded watch decoder
uses the existing scratch buffer and validates metadata, offsets, truncation,
exact pixel counts and index capacity before allocating cache storage.

Auto/night controls, preference reads/writes, commands, request arguments,
palettes and watch colour branches are removed. Old stored values are ignored
without resetting other preferences. Android launch windows also use the
existing light appearance for every OS setting.
Targeted release retention rules protect the safe LZ4 factory's reflective class,
INSTANCE and constructor access without retaining the JNI/unsafe implementations.

Native diagnostics retain 512 requests while Flutter is closed. Local work IDs
avoid collisions after watch restarts. Stage timings, cache/retry counts, codec,
bytes and terminal outcomes are exported without credentials or payloads.
Completion percentiles contain final ACK completions; cancellation/failure
durations are separate. Watch decode and render-submission timings are independent.

## Physical Android measurements

Samsung SM-F966B, separate debug app ID `com.leapwardkoex.mappy.tilebench`, fake
HTTP and nonuniform PNG fixtures, 30 samples per group after code/LUT warmup.
The installed user app was preserved. Physical timings were collected before the
final hoisting of source-dimension x sampling outside crop rows; the phone then
disconnected. The final source build passed the same pixel suite and release APK
smoke on the emulator. Colour conversion and codec implementations were unchanged.
All four source settings use the **same
synthetic imagery**: this validates settings/pipeline behavior, not differences
between Google's real map products. No credentials or network were used.

Preparation milliseconds, **median / p95**:

| Source setting | Crop | Cold caches | Warm source pixels | Encoded cache |
| --- | --- | ---: | ---: | ---: |
| roadmap | 54x63 | 1.473 / 1.727 | 0.408 / 0.542 | 0.015 / 0.018 |
| roadmap | 72x84 | 1.660 / 2.434 | 0.521 / 0.622 | 0.013 / 0.015 |
| roadmap | 108x126 | 2.145 / 4.084 | 1.019 / 1.175 | 0.013 / 0.015 |
| satellite | 54x63 | 1.378 / 2.886 | 0.358 / 0.451 | 0.015 / 0.017 |
| satellite | 72x84 | 1.705 / 1.945 | 0.454 / 0.514 | 0.011 / 0.012 |
| satellite | 108x126 | 2.005 / 2.802 | 0.839 / 0.896 | 0.011 / 0.013 |
| hybrid | 54x63 | 1.333 / 2.332 | 0.269 / 0.316 | 0.011 / 0.015 |
| hybrid | 72x84 | 1.607 / 1.949 | 0.538 / 0.745 | 0.013 / 0.016 |
| hybrid | 108x126 | 2.227 / 2.480 | 0.901 / 1.254 | 0.010 / 0.013 |
| terrain | 54x63 | 1.416 / 1.613 | 0.298 / 0.347 | 0.010 / 0.013 |
| terrain | 72x84 | 1.641 / 1.925 | 0.567 / 0.654 | 0.009 / 0.012 |
| terrain | 108x126 | 2.366 / 2.633 | 0.843 / 1.125 | 0.008 / 0.010 |

Warm source and encoded-cache samples made zero additional tile HTTP calls.
Retries were zero in this offline run. Cold samples include reset/session setup
and real Android PNG decode. Fetch/decode metrics sum parallel source work and
can exceed request wall time. Raw stage data is saved locally in
`artifacts/tile-performance/android-physical-results.json`.

The isolated colour benchmark processes 217,728 deterministic RGBs in 30
alternating old/new runs. The old formula plus palette scan measured
**93.780 ms median / 95.907 ms p95**; lookup conversion measured
**3.713 / 3.763 ms**, a **25.26x median stage speedup**. This is not a whole-tile
or Bluetooth speedup. Independent host JVM and emulator ratios were 24.93x and
39.02x. Exhaustive unit comparison covers all 16,777,216 RGB values.

Sampled high-water allocations were 69,630,864 Java-heap bytes and 7,653,536
native-heap bytes. These include instrumentation, fixtures and garbage awaiting
collection; they are neither PSS nor an exact peak or before/after memory
comparison. The decoded cache's own retained pixel payload has a tested 8 MiB cap.

## Saved map compression measurements

The 54x63 group contains 225 original Googleplex Google Map Tiles palette crops.
Larger groups are fully covered crops reconstructed from that same saved atlas,
not new provider responses. Every tile retained its pixels and at-rest storage
size. This corpus chose format 4 throughout; shared synthetic vectors cover all
four codecs. No provider imagery was refreshed or committed.

| Crop | Corpus | Previous RLE bytes | Adaptive bytes | Reduction | 3,072-byte chunks |
| --- | --- | ---: | ---: | ---: | ---: |
| 54x63 | 225 original crops | 123,931 | 92,078 | 25.70% | 225 -> 225 |
| 72x84 | 196 atlas recrops | 191,363 | 144,295 | 24.60% | 196 -> 196 |
| 108x126 | 196 atlas recrops | 427,149 | 316,435 | 25.92% | 213 -> 198 |

Payload reduction is not an elapsed-delivery prediction: smaller crops still
occupy one chunk each. Host median-of-seven corpus encoding times were
2.916 -> 2.576 ms, 1.840 -> 3.315 ms and 3.843 -> 5.306 ms for the three groups.
Extra compression costs some CPU for larger crops while reducing transfer bytes.
Full data: `artifacts/tile-performance/android-jvm-benchmark.json`.

## Watch validation and memory

Emery, Pebble Tool 5.0.40, SDK 4.33.1, QEMU 10.1.5. Production ELF:

| Measurement | Baseline | Protocol v4 | Change |
| --- | ---: | ---: | ---: |
| Text | 54,775 B | 55,667 B | +892 B |
| Data | 240 B | 240 B | 0 |
| BSS | 5,596 B | 5,604 B | +8 B |
| Application footprint | 60,611 B | 61,511 B | +900 B |
| SDK-reported free heap | 70,461 B | 69,561 B | -900 B |
| Tile arena | 46 KiB | 46 KiB | 0 |
| Tile scratch | 6,804 B | 6,804 B | 0 |

Decoder code fits without shrinking the cache. Fixture-only builds relocate the
existing two 128-point route buffers (2,048 bytes) to one heap allocation to fit
the 65,535-byte executable limit. Capacity/lifetime are unchanged; this is not a
runtime memory saving. Production route-buffer placement is unchanged. Final
fixture footprint is 64,546 bytes with free heap 66,526 bytes before that
allocation. The optional hardware timing build footprint is 63,314 bytes.

Host codec/cache and production assembly tests pass with ASAN/UBSAN, including
all 12 shared vectors, arbitrary chunk splits, overlapping matches, malformed
streams, required field/type checks, metadata changes and stale/offscreen input.
Smoke, all three geometries, north-up/facing-up pan under load, inertia,
zoom/recenter/menu cancellation and rapid zoom reversal pass. Emulator
input-to-frame was 5-8 ms; delayed-fixture viewport fill was 2.237-3.142 s.
Angle gates at 0/30/45/60/75/90 degrees reported zero errors. Nonzero-angle maximum
draw times were 18-20 ms versus 20-22 ms baseline; frame mixes differ, so this is
a regression check, not a speedup claim. Screenshots were visually inspected.
Real AppMessage fixture transfers for LZ4 formats 3 and 4 completed their grids.

Detailed local watch report and captures:
`apps/pebble-watch/codex-emulator/tile-speed-watch-validation.md`.

## Checks and reproduction

Android full unit suite passed (142 tests), plus four instrumented tests on both the Pixel
emulator and physical Samsung. The release APK built with R8 and release lint.
A separate instrumented smoke test loaded that actual minified APK through an
isolated boot-parent DexClassLoader on both devices: safe factory initialization
and all three packed geometries reconstructed correctly. Targeted R8 rules retain
the reflection-loaded Java-safe classes and keep the factory in their package.
Flutter analysis is clean and 109 tests pass. Pebble tooling/protocol consistency,
codec/cache/rendering/assembly tests, production PBW, smoke and pan-load checks pass.

Run offline Android checks from repository root:

```powershell
.\tooling\test-android-tile-pipeline.ps1 -DeviceSerial <adb-serial> -JavaHome <jdk-path>
```

Use a Gradle-compatible JDK that loads PebbleKit2's Java-21 bytecode. This run
used installed Android Studio Java 25. `-IncludeCorpus` enables the optional JVM
benchmark and forces tasks to execute when regenerating reports.
Saved provider imagery remains local in `tooling/real-map-fixtures/generated`.
The existing `pebble-wsl.ps1` commands cover `test-tooling`, `test-protocol`,
`test-tile-cache-host`, `build-phone`, `smoke-fixture` and `test-pan-under-load`.

The minified codec regression is `MinifiedTileCodecInstrumentedTest`. After
building `:app:assembleRelease :app:assembleDebug :app:assembleDebugAndroidTest`
with `-PmappyTileBenchmark=true`, install the isolated debug and test APKs and run:

```powershell
adb -s <serial> push apps/mobile-companion/build/app/outputs/apk/release/app-release.apk /data/local/tmp/mappy-tile-release.apk
adb -s <serial> shell am instrument -w -e class com.leapwardkoex.mappy.MinifiedTileCodecInstrumentedTest -e releaseApk /data/local/tmp/mappy-tile-release.apk com.leapwardkoex.mappy.tilebench.test/androidx.test.runner.AndroidJUnitRunner
```

The test copies the APK to private read-only code storage and uses a boot-parent
class loader, so the debug dependency cannot mask a release retention failure.

## Remaining physical acceptance

No paired protocol-v4 watch Bluetooth trial was performed. Full end-to-end
preparation/ACK baseline comparisons under live provider latency, physical watch
interaction p95 and 0/10/30 ms pacing acceptance remain unmeasured. The saved
corpus does not identify every map source; the all-source device matrix is
explicitly synthetic. No estimates substitute for these missing results.

Debug pacing trials accept `-PmappyTilePacingMillis=0`, `10` or `30`; bridge
status exports the configured delay. Release always uses 30 ms. Build watch
logs with `MAPPY_WATCH_HARDWARE_PERF=1` and the `build-phone` helper. Keep the
phone/watch, route, fixtures, crop sizes and interaction sequence fixed. Compare
median/p95 request-to-final-ACK, separate watch frame times, failures/retries
and p95 interaction latency. Reduce production pacing only if completion
improves with no extra failures/retries and at most 5% worse p95 interaction.
