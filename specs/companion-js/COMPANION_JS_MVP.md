# Companion JS MVP Spec

This spec defines the MVP role of the PebbleKit JS bundle in Mappy.

MVP decision: PebbleKit JS is not the phone runtime. The Android native
integration inside the Flutter companion app owns Pebble transport, Google API
access, map tile generation, routing, destinations, settings, and diagnostics.

## Required MVP Behavior

The bundled PKJS entrypoint for MVP is a comment-only no-op file packaged for
Pebble SDK compatibility. Do not remove the entrypoint unless `wscript` is
changed and `pebble build` is verified.

Current entrypoint:

- `apps/pebble-watch/src/pkjs/index.js` remains intentionally empty.

The emulator fixture build defined in
`../watch/PEBBLE_EMULATOR_FIXTURE_MODE_SPEC.md` is the only allowed exception.
That build must be explicitly selected with `MAPPY_WATCH_PHONE_MODE=fixture` or
an equivalent emulator tooling command, and must not be shipped as the
production phone-runtime path.

## Forbidden MVP Behavior

PKJS must not:

- Store, receive, or log the user's Google API key.
- Store, receive, or log bearer tokens or credential-like secrets.
- Call Google Map Tiles, Geocoding, Routes, Places, or any other Google API.
- Call an application backend.
- Contain provider URLs, `XMLHttpRequest`, `fetch`,
  `Authorization`, `localStorage`, config-webview listeners, share-intent
  listeners, or notification listeners for MVP.
- Register an independent `Pebble.addEventListener('appmessage', ...)`
  dispatcher that responds to watch commands in parallel with Android native
  code.
- Respond to `CMD_TILE_REQUEST`.
- Respond to `CMD_ROUTE_REQUEST`.
- Own GPS updates.
- Own saved locations or settings persistence.
- Implement any phone integration owned by Flutter or Android native code.

## Allowed MVP Behavior

PKJS may contain:

- A startup comment explaining that Android native owns the MVP phone runtime.
- Build-time compatibility stubs required by the Pebble SDK.

## Post-MVP Only

A future relay shim is allowed only after a separate spec amends this one and
defines:

- local-only IPC between Android/Flutter and PKJS,
- no-server secret transfer rules,
- duplicate worker prevention,
- ACK/NACK ownership,
- test coverage proving only one phone worker responds to watch commands.

No relay shim is part of MVP.

## Package Metadata

The Pebble package may keep `enableMultiJS` if required by tooling, but this
does not grant PKJS runtime ownership.

The package must define the AppMessage keys in
`../shared/PROTOCOL_MVP.md` even when PKJS is empty, because the native watch app
and Android companion still use the same message dictionary.

MVP package metadata must declare the Mappy Android companion package for
PebbleKit Android 2 bound-service discovery:

```json
"companionApp": {
  "android": {
    "apps": ["com.leapwardkoex.mappy"]
  }
}
```

The release package ID is `com.leapwardkoex.mappy`. Do not add an unplanned
companion URL, notification filter, or PKJS config URL.

MVP package metadata must remain minimal:

- no `shareTarget`,
- no Google Maps `notificationFilter`,
- no unrelated `companionApp` URL or package reference,
- no `microphone` capability,
- no `configurable` capability until Flutter/native settings are wired,
- no Pebble `location` capability unless the watch app itself directly requests
  watch-side location.

## Acceptance Criteria

- Static scan of PKJS finds no Google API endpoints.
- Static scan of PKJS finds no API-key, backend, Timeline,
  localStorage, XHR/fetch, share-intent, notification, or config-webview
  behavior.
- Static scan of the production `phone` build PKJS finds no
  `Pebble.addEventListener('appmessage'...)` handler for MVP.
- Static scan of fixture PKJS responders treats them as emulator-only and
  verifies they contain no API key or network calls.
- Watch tile and route requests are handled only by the Android native
  companion.
- The comment-only PKJS entrypoint is packaged successfully by `pebble build`.
- Generated package metadata contains the shared message keys and Mappy Android
  companion package metadata required by PebbleKit Android 2, with no extra
  integration surface.
