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

For this SwiftPM app, keep the source Icon Composer package at `Sources/Cherry/Resources/AppIcon.icon`.
`Scripts/install-local-app` compiles it with `xcrun actool` for macOS 26+, producing the bundle's `Assets.car`,
`AppIcon.icns`, and `CFBundleIconName` metadata. `Sources/Cherry/Resources/AppIcon.icns` is only the checked-in
fallback/runtime icon used when the app is launched outside the packaged bundle.
