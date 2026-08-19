# Updating app icons

`drawing.svg` is the editable source of truth for Mappy's app icon. Keep its
layer IDs intact: `layer1` is the background, `layer2` is the view cone,
`layer3` is the route, and `layer4` contains the two markers.

The launcher generator consumes raster files, not the SVG directly. The update
script renders all three inputs from `drawing.svg` before invoking it:

- `icon_1024_1024.png` is the generated full-colour 1024 x 1024 launcher source.
- `icon_foreground.png` is generated without the background for Android's
  adaptive foreground layer.
- `icon_monochrome.png` is generated from the route and markers for Android
  13+ themed launchers.

The configuration lives in `../flutter_launcher_icons.yaml`. It intentionally
generates Android icons only; the iOS runner is left unchanged.

## Regenerate the icons

After editing `drawing.svg`, run the following command from
`apps/mobile-companion`:

```powershell
.\tool\update_icons.ps1
```

The script requires ImageMagick 7 and FVM. It renders the full-colour,
adaptive-foreground, and monochrome PNGs from the SVG, runs
`fvm flutter pub get`, and then runs:

```sh
fvm dart run flutter_launcher_icons
```

The package regenerates the Android `mipmap-*` launcher bitmaps and the
adaptive/themed resources under `android/app/src/main/res`. Do not hand-edit
those generated launcher files.

To prepare only the three raster inputs while working on the artwork, use:

```powershell
.\tool\update_icons.ps1 -SkipPackageGeneration
```

## Notification icon

`flutter_launcher_icons` does not generate Android notification small icons.
The update script therefore generates a separate monochrome VectorDrawable at
`../android/app/src/main/res/drawable/ic_stat_mappy.xml`. The foreground service
references it with `R.drawable.ic_stat_mappy`.

The notification glyph intentionally uses only the route and two markers. A
notification small icon is rendered by Android as a system-coloured alpha
silhouette, so the opaque, full-colour launcher image must not be used there.
The script reads the route and outer marker geometry from the stable SVG IDs
`path2`, `path10-8`, and `path10-8-5`; keep those IDs intact when editing the
artwork.

## Verify

After regeneration:

1. Review the generated resource diff and run `fvm flutter analyze`.
2. Build or run the Android app and inspect the launcher icon with circle,
   squircle, and rounded-square launcher masks.
3. Start a Pebble watch session and confirm the status-bar notification shows
   the route-and-markers glyph rather than a solid square.

Configuration details are documented by
[`flutter_launcher_icons`](https://pub.dev/packages/flutter_launcher_icons).
Android's adaptive and notification icon constraints are covered by the
[adaptive icon](https://developer.android.com/develop/ui/compose/system/icon_design_adaptive)
and [Image Asset Studio](https://developer.android.com/studio/write/create-app-icons#notification)
guides.
