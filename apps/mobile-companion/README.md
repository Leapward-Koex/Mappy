# Mappy Mobile Companion

Mappy connects an Android phone's location and Google Maps Platform services to
the Mappy navigation app for Pebble watches. The Flutter interface provides
route search, saved destinations, watch display settings, setup status, and
redacted diagnostics.

## Requirements

- Flutter 3.44.1 (Dart 3.12.1)
- Android development tools for Android builds
- A Pebble-compatible phone bridge
- A Google Maps Platform API key for live maps and routing

The Dart package is named `mappy`. Android and iOS use the bundle identifier
`com.leapwardkoex.mappy`.

## Run locally

This repository includes FVM configuration for the supported Flutter version:

```sh
fvm flutter pub get
fvm flutter run
```

If Flutter 3.44.1 is already active globally, the equivalent `flutter` commands
work as well.

## Google Maps Platform setup

Mappy uses the Map Tiles, Places, Geocoding, and Routes APIs. In the app, open
Setup to see the Android package name and signing SHA-1 that should be attached
to the key's Android application restriction. Paste the key into Setup; Android
stores it in encrypted local storage and Flutter receives only redacted status
information afterward.

For local debug or profile builds, copy the repository-root `.env.example` to
`.env.local` and set `MAPPY_DEV_GOOGLE_API_KEY`. The ignored file is read only
at build time. A process-level variable with the same name takes precedence;
the legacy ignored `mappy.devGoogleApiKey` entry in `android/local.properties`
remains supported as a fallback. Release builds force the development key to
an empty value regardless of local configuration.

Never commit real credentials to source, assets, Gradle files, generated
files, or tests.

## App structure

- `lib/main.dart` contains the Flutter app shell and screens.
- `lib/provider_bridge.dart` models provider requests, results, and settings.
- `lib/location_bridge.dart` exposes location permission and fix state.
- `lib/bridge_channel.dart` exposes Pebble transport and diagnostic events.
- `lib/watch_protocol.dart` encodes the Mappy watch protocol.
- `lib/watch_phone_worker.dart` coordinates phone-side watch requests.
- `android/` implements secure key storage, Google provider calls, foreground
  location, and Pebble transport.
- `ios/` is the Flutter iOS runner; Android-only native capabilities report as
  unavailable on iOS.

## Verification

Run the Flutter checks from this directory:

```sh
fvm flutter analyze
fvm flutter test
```

Android unit tests are local and fake-backed, so they need neither network
access nor a live API key:

```sh
cd android
./gradlew testDebugUnitTest
```

Before a release, validate a restricted key on a build signed with the intended
release identity. The in-app provider check verifies all required APIs and
confirms that the configured Android package and certificate restrictions are
enforced.

## Diagnostics and privacy

Diagnostic exports redact API keys, authorization headers, bearer tokens, and
sensitive query parameters. Review an export before sharing it, especially if
native or provider error messages were included.
