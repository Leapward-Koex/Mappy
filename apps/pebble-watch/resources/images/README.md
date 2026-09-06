# Mappy launcher icon

`menu_icon.png` is the 25 x 25 Pebble launcher resource registered as `MENU_ICON`
with `menuIcon: true` in `../../package.json`.

`menu_icon.svg` is its editable, pixel-aligned source. It adapts the winding route
and two oval markers from Android's notification icon at
`../../../mobile-companion/android/app/src/main/res/drawable/ic_stat_mappy.xml`.
The route is two pixels thick through the tight bend, the markers have balanced
pixel steps, and a two-pixel margin keeps the silhouette clear of the menu edge.

The PNG uses only opaque black and fully transparent pixels, with no smoothing
or dithering. Black keeps the glyph visible on Emery's white and blue launcher
rows; transparency avoids a square behind it. Emery does not invert app icons.
See the [Pebble launcher icon guidance](https://developer.repebble.com/guides/app-resources/images/#menu-icon-in-the-launcher).

After editing the SVG, regenerate with ImageMagick 7 from `apps/pebble-watch`:

```sh
magick -background none resources/images/menu_icon.svg -channel A -threshold 50% +channel -strip PNG8:resources/images/menu_icon.png
```

Keep `PNG8:` so the output retains a palette with binary transparency. Avoid
forcing a one-bit PNG export, which can discard transparency in ImageMagick.
The PNG is checked in, so normal Pebble builds do not need ImageMagick.

Review at native size and with nearest-neighbor enlargement, then use the
repository's `install-phone`, `button`, and `screenshot` helpers to inspect
both selected and unselected launcher rows on Emery.
