# Inkpeg brand icon

Original Inkpeg geometry from `site/assets/mark.svg`: curved rope, warm paper, red clip. `scripts/make-icon.swift` ports those vector paths to AppKit and adds a warm rounded macOS icon body. It uses no upstream Tendedero art.

Reproduce into a **new** directory, then compare generated files with this directory:

```sh
swift scripts/make-icon.swift /tmp/Inkpeg-new.iconset
iconutil -c icns /tmp/Inkpeg-new.iconset -o /tmp/Inkpeg-new.icns
```

The iconset supplies 16, 32, 128, 256 and 512 point representations at 1× and 2×. The bundle declares `CFBundleIconFile=Inkpeg.icns`. Light/dark background render checks are asset previews, not evidence of Finder or the application switcher; the app is an accessory app (`LSUIElement=true`).
