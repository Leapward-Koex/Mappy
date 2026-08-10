# Secure Storage Spec

This spec defines local storage for the user's Google API key and related
credential-adjacent state in the Android-first Mappy MVP.

## Design Basis

- MVP accepts user-supplied Google API keys.
- The full API key must never be stored in Flutter, PKJS, watch storage, logs,
  exports, or build artifacts.
- Android native secure storage is the only full-key owner.

Development exception:

- During local development only, a Google API key may be hardcoded through an
  ignored Android-local build configuration such as `android/local.properties`.
- That development key may be compiled into debug/profile build artifacts, and
  native startup may seed it into Android secure storage for faster provider
  testing.
- Native storage must distinguish app-seeded development keys from user-entered
  keys using a native-only provenance marker. Startup seeding may write the
  development key only when no key exists, or when replacing a key already
  marked as app-seeded development state.
- For debug/profile verification only, this seeded development key may be an
  unrestricted Google API key. In that case native validation may skip the
  intentionally wrong Android package/certificate rejection requirement and
  mark the provider valid after the real Map Tiles, Places, Geocoding, and
  Routes requests succeed.
- The development key must not be committed to repository source, Dart/Flutter
  source, Android resources, assets, package metadata, tests, release builds, or
  documentation examples.
- Release builds must force the development hardcoded key value empty.
- Any key used this way must be treated as exposed and rotated before public
  distribution.

## Stored Data

Secure storage contains:

| Item | Required | Notes |
| --- | --- | --- |
| Google API key | Yes after setup | Full secret, native-only. |
| Key metadata | Yes | Redacted prefix, length, created/updated timestamp. |
| Validation state | Yes | Last validation status and safe provider details. |
| Validation timestamp | Yes | Used to decide whether revalidation is needed. |

Secure storage must not contain:

- Bearer tokens.
- Credentials forwarded by another application.
- Pebble Timeline tokens.
- Notification/share payloads.

Non-secret local repositories may store destinations, settings, route cache,
tile cache, and diagnostics, but they must not store the full key.

## Native API

Native secure storage exposes:

```text
storeApiKey(plaintext) -> KeyStatus
getKeyForProviderCall() -> plaintext in native memory only
clearApiKey() -> KeyStatus
getKeyStatus() -> redacted KeyStatus
markValidationResult(result) -> KeyStatus
```

Flutter-visible `KeyStatus`:

```text
configured: boolean
redacted_preview: string | null
length: integer | null
updated_at: timestamp | null
validation_state: enum
validation_updated_at: timestamp | null
```

`getKeyForProviderCall()` must not be reachable through Flutter method channels.

## Input Validation

Before storing:

- Trim surrounding whitespace.
- Reject empty strings.
- Reject values that do not match the expected Google API key shape.
- Reject strings containing whitespace after trim.
- Reject obvious URLs, JSON blobs, or bearer-token prefixes.
- Accept `AIza`-shaped Google API keys for validation.

The validator should avoid overfitting the complete Google key format because
Google may change generated key shapes. Provider validation is authoritative.

## Storage Mechanism

Required Android design:

- Generate or retrieve an Android Keystore key for encryption.
- Encrypt the full API key before writing to app-private storage.
- Use authenticated encryption such as AES-GCM.
- Store ciphertext only in app-private storage.
- Do not require biometric/user-auth gating for MVP because background provider
  calls while the app is foregrounded must not deadlock on an auth prompt.

Allowed implementation:

- Direct Android Keystore plus app-private preferences/file storage.
- Or Jetpack Security `EncryptedSharedPreferences` if it is available and uses
  Android Keystore-backed authenticated encryption.

Forbidden implementation:

- Plain `SharedPreferences` for the full key.
- Flutter `shared_preferences` for the full key.
- Dart constants, Android resources, Gradle fields, assets, or generated source
  containing the full key.
- PKJS `localStorage`.
- Watch persistent storage.
- Logs or diagnostics exports.

The development exception above permits an ignored local Gradle/BuildConfig
field only for debug/profile builds. It does not permit committed source or
release artifacts to contain the full key.

## Backup And Migration

MVP backup policy:

- The full API key must not be restored onto another device unless the encrypted
  storage mechanism guarantees device-bound key protection.
- Prefer disabling backup for the companion app until explicit backup rules are
  implemented.
- If Android backup remains enabled for non-secret app data, secret storage must
  be excluded through backup/data-extraction rules.

Migration:

- There is no supported migration from browser or PKJS storage.
- If old or unsupported credential-like data is found, reject it locally and ask
  the user to enter a Google API key.

Key clearing:

- `clearApiKey` deletes ciphertext, validation state, and redacted metadata.
- Clearing the key pushes setup-required state to the watch if connected.
- Clearing the key does not delete destinations or settings.
- Cache clear controls are separate from key clearing.

## Memory And Logging

Rules:

- Keep plaintext key lifetime as short as practical.
- Do not include the full key in exceptions.
- Do not stringify provider request objects with query parameters that include
  the key.
- Redact any value that matches configured key preview or common key patterns.
- Use POST headers/body handling that avoids logging full URLs when a key is in a
  query parameter.

Diagnostics may include:

- `configured` boolean.
- Redacted preview.
- Validation state.
- Safe HTTP status.
- Provider error class.

Diagnostics must not include:

- Full key.
- More than the allowed redacted preview.
- Provider session token.
- Authorization headers.

## Validation State

Validation states match `BYOK_PROVIDER_POLICY.md`:

- not configured
- validating
- valid
- invalid key
- API disabled
- quota or billing issue
- provider permission denied
- network unavailable
- unsupported restricted-key behavior

Validation state is not proof that future route/tile calls will succeed. The UI
must show operation-specific errors when later provider calls fail.

## Tests

Unit tests:

- Reject empty input.
- Reject incorrectly shaped credentials.
- Reject URL/blob/bearer-like input.
- Store valid-looking key and return only redacted status.
- Clear key removes ciphertext and validation state.
- Redaction catches the stored key in messages and nested data structures.

Android instrumentation or JVM tests with fakes:

- Ciphertext differs from plaintext.
- Flutter method channel never returns full key.
- Provider adapter can retrieve plaintext only through native internal API.
- Backup exclusion config exists or backup is disabled.

Static tests:

- No full-key fixture values in committed source except clearly fake test values.
- No Google API key-shaped values in release artifacts.
- No `localStorage`, watch persistence, resources, or Dart preferences contain
  the key.
- Diagnostic export fixtures contain no full key.

## Acceptance Criteria

- Full API key is stored only by Android native secure storage.
- Flutter can submit, clear, and view redacted status but cannot read the full
  key back.
- Provider adapters can use the key for direct Google calls.
- Incorrectly shaped credentials are rejected without network calls.
- Logs and exports redact the key.
- App uninstall or key clear removes MVP credential state.
