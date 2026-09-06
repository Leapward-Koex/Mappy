# Mappy Mobile Companion

Mappy connects an Android phone's location and Google Maps Platform services to
the Mappy navigation app for Pebble watches. The Flutter interface provides
route search, saved destinations, watch display settings, setup status, and
redacted diagnostics.

## Requirements

- Flutter 3.47.2 (Dart 3.13.2)
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

If Flutter 3.47.2 is already active globally, the equivalent `flutter` commands
work as well.

## Google Maps Platform setup

Mappy uses the Map Tiles, Places, Geocoding, and Routes APIs. In the app, open
Settings > Google Maps setup to see the Android package name and current
signing SHA-1 that should be attached to the key's Android application
restriction. Paste the key there and select **Save and validate**; Android
stores it in encrypted local storage and Flutter receives only redacted status
information afterward.

The phone map uses a separate, app-restricted **Maps SDK for Android** key.
Set `MAPPY_ANDROID_SDK_API_KEY` in the repository-root `.env.local` for local
builds, including all existing VS Code launch configurations. Gradle resolves
it from the process environment first, then `.env.local`, then the ignored
`mappy.androidSdkApiKey` entry in `android/local.properties`. No Dart define
or VS Code launch change is needed. Stop and rebuild the app after changing
the key; hot reload does not update the native manifest. If using a process
environment variable, restart VS Code after changing the machine environment.

Every Android variant embeds this SDK key in the manifest; release packaging
fails if it is missing. GitHub Actions reads the repository Actions secret
`MAPPY_ANDROID_SDK_API_KEY` via `secrets`, for both debug and release builds.
Restrict the key to Maps SDK for Android and `com.leapwardkoex.mappy` with the
appropriate debug/release signing SHA-1s (use the Play app signing certificate
for Play-distributed builds). This SDK key does not replace the user-supplied
key for Map Tiles, Places, Geocoding, and Routes.

For local debug or profile builds, copy the repository-root `.env.example` to
`.env.local` and set `MAPPY_DEV_GOOGLE_API_KEY`. The ignored file is read only
at build time. A process-level variable with the same name takes precedence;
the legacy ignored `mappy.devGoogleApiKey` entry in `android/local.properties`
remains supported as a fallback. Release builds force the development key to
an empty value regardless of local configuration.

Never commit real credentials to source, assets, Gradle files, generated
files, or tests.

## Android release signing

Release packaging refuses to run without an explicitly configured, non-debug
signing identity. Prefer these environment variables:

```text
MAPPY_RELEASE_STORE_FILE=/absolute/path/to/release-upload.jks
MAPPY_RELEASE_STORE_PASSWORD=...
MAPPY_RELEASE_KEY_ALIAS=...
MAPPY_RELEASE_KEY_PASSWORD=...
```

Ignored `android/local.properties` may instead define the equivalent
`mappy.releaseStoreFile`, `mappy.releaseStorePassword`,
`mappy.releaseKeyAlias`, and `mappy.releaseKeyPassword` values for local-only
release verification. Never commit the keystore or those values.

GitHub prerelease builds require repository secrets named
`MAPPY_RELEASE_KEYSTORE_BASE64`, `MAPPY_RELEASE_STORE_PASSWORD`,
`MAPPY_RELEASE_KEY_ALIAS`, and `MAPPY_RELEASE_KEY_PASSWORD`. Pull requests build
the debug variant; only protected, signed release artifacts are uploaded.

On the first eligible launch, Navigate shows a one-time setup checklist for
Google Maps, location, and recommended background reliability. It never opens
Android permission dialogs automatically, can be deferred, and remains
available later at Settings > Setup checklist. Active navigation and incoming
Google Maps shares take priority over the checklist.

## Battery optimization

Android battery exemption requests use the published `permission_handler` 12.x
package, compatible with this app's Android SDK and AGP 9 build. The status is
read from Android and refreshed after the permission dialog or app settings
closes. Declining the exemption leaves optimization enabled.

Settings > Permissions > Phone battery settings opens Mappy's app settings for
manual battery configuration. Manufacturer-specific autostart and sleeping-app
controls may need to be adjusted separately; they cannot be verified through
Android's battery exemption API and do not affect the reported exemption status.
Battery optimization remains unavailable on non-Android platforms.

## App structure

- `lib/main.dart` contains the three-tab app shell plus Navigate and Saved.
- `lib/first_run_setup_checklist.dart` contains the reusable first-run and
  manually reopened readiness checklist.
- `lib/settings_screens.dart` contains setup, permissions, watch connection,
  preferences, and diagnostics pages.
- `lib/about_screen.dart` contains installed-version and source-repository
  information.
- `lib/provider_bridge.dart` models provider requests, results, and settings.
- `lib/location_bridge.dart` exposes location permission and fix state.
- `lib/bridge_channel.dart` exposes Pebble transport and diagnostic events.
- `lib/watch_protocol.dart` encodes the Mappy watch protocol.
- `lib/watch_phone_worker.dart` coordinates phone-side watch requests.
- `icon/` contains the app-icon source and the documented regeneration
  workflow.
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

Android unit tests require Java 21, matching CI and the PebbleKit2 dependency.
They are local and fake-backed, so they need neither network access nor a live
API key:

```sh
cd android
./gradlew testDebugUnitTest
```

Before a release, validate a restricted key on a build signed with the intended
release identity. The in-app provider check verifies all required APIs and
confirms that the configured Android package and certificate restrictions are
enforced. CI verifies the SDK key is embedded in the release manifest and rejects other
Google API-key-shaped values in the APK.

To update launcher and notification artwork, follow
[`icon/README.md`](icon/README.md). The launcher resources are generated with
`flutter_launcher_icons`; Android notification artwork is maintained as the
separate monochrome drawable required by the platform.

## Diagnostics and privacy

Diagnostic exports redact API keys, authorization headers, bearer tokens, and
sensitive query parameters. Review an export before sharing it, especially if
native or provider error messages were included.
