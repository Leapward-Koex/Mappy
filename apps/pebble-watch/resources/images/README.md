# Mappy launcher icon

`menu_icon.png` is the 25 x 25 Pebble launcher resource registered as `MENU_ICON`
with `menuIcon: true` in `../../package.json`.

`menu_icon.svg` retains the original Android notification icon's curved route
and two oval markers, without a background tile or view cone. The source is
`../../../mobile-companion/android/app/src/main/res/drawable/ic_stat_mappy.xml`.
The route is black and 1.8 pixels wide at native size. Its Bezier curve and the
marker ellipses are rasterized at 16x resolution, then area-downsampled and
quantized to Pebble's four supported alpha levels without dithering.

## Smooth grayscale edges

All RGB values are black. Pixel opacity is exactly 0, 85, 170, or 255, so the
edges appear light gray and dark gray against a white launcher row, while the
interiors remain solid black. Partial opacity also blends the edges into the
blue selection row instead of leaving a white fringe. Only the boundary pixels
are shaded; this is coverage antialiasing, not a blur applied to the icon.

The four opacity levels match the SDK's 2-bit alpha quantization. The launcher
luminance-tints app icons, which preserves this black-with-alpha artwork.
The PNG is stored as RGBA; Pebble's resource compiler handles palette packing.

## Regenerate

With ImageMagick 7, from `apps/pebble-watch`:

```sh
magick -background none -density 1536 resources/images/menu_icon.svg -filter Box -resize '25x25!' -channel A -fx 'round(a*3)/3' +channel -depth 8 -strip PNG32:resources/images/menu_icon.png
```

Keep `PNG32:` to preserve both intermediate opacity levels. Do not threshold
the alpha channel or use the old `PNG8:` export: either can remove the edge
shading. The PNG is checked in, so normal builds do not need ImageMagick.

Review at native size and with nearest-neighbor enlargement, then inspect
both white and blue launcher rows on Emery using the repository's
`install-phone`, `button`, and `screenshot` helpers.
