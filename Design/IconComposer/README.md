# Cherry Icon Composer Notes

Icon Composer is installed at:

```sh
open -a "/Applications/Xcode.app/Contents/Applications/Icon Composer.app"
```

Recommended workflow:

1. Open Icon Composer and create a new icon document.
2. Drag the numbered SVG files from `layers/` into the layer sidebar together for the light appearance, or use `dark-layers/` for the dark appearance.
3. Keep the numbered order as the Z stack: warm base, pale eucalyptus rear pane, frosted middle pane, lavender active slab, mint overlap glow.
4. Use Icon Composer for the glass decisions: Liquid Glass on, soft blur, high translucency, gentle specular highlights.
5. Preview macOS Default, Dark, and Mono appearances at small sizes.
6. Save the result as `Cherry.icon`.

For this SwiftPM app, `Scripts/install-local-app` currently consumes `Sources/Cherry/Resources/AppIcon.icns`. To ship an Icon Composer result here, export a flattened 1024 PNG from Icon Composer, then regenerate `AppIcon.icns` with `iconutil` using the same size set in `.build/icon-work/AppIcon.iconset`.
