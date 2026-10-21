# Pingit icon artwork

The vector source is `scripts/generate-icons.swift`. It draws the shared bell,
PR badge, and the menu bar optical variant using Core Graphics. No third-party
packages, fonts, image generation, or runtime drawing dependencies are required.

From the repository root, regenerate all assets and this contact sheet:

```sh
swift -module-cache-path build/icon-module-cache scripts/generate-icons.swift
```

- `AppIcon-master.pdf`: 1024-point vector master, with transparent margins around
  a flat, light rounded-square face. `AppIcon-1024.png` is its raster export.
- `MenuBar-master.pdf`: 20 × 18-point monochrome vector master.
- `contact-sheet.png`: 512, 128, 32, and 16-pixel app icons; actual-size 18-point
  menu bar previews in light and dark appearances; and the 32-point header mark.
- `pingit/Resources/Assets.xcassets`: ten macOS AppIcon slots (16, 32, 128,
  256, 512 points at 1× and 2×), plus the menu bar and header image sets.

The 16/32-point app icons and header use a larger badge and heavier PR strokes.
The menu bar uses its own grid with a larger badge, transparent separation, and
transparent PR cutouts. Every nontransparent template pixel is black; the
exporter asserts this at both resolutions. The catalog marks it as a template,
and SwiftUI explicitly requests `.renderingMode(.template)`, allowing macOS to
tint it for the current appearance and selection state. Connection status stays
in the accessible menu bar label and the existing popover content.

The project targets macOS 14, so it uses the compatible PNG asset catalog rather
than requiring a newer layered Icon Composer format. The asset catalog compiler
creates AppIcon.icns and adds the bundle icon metadata.

References: [Apple app icon asset configuration](https://developer.apple.com/documentation/xcode/configuring-your-app-icon),
[Apple asset catalog app icon sizes](https://developer-mdn.apple.com/library/archive/documentation/Xcode/Reference/xcode_ref-Asset_Catalog_Format/AppIconType.html).

Validation performed with Xcode 27.1 on the macOS 14 deployment target:

- Debug preview build succeeded; all 142 existing tests passed.
- `scripts/validate-app.sh` passed on the regular ad hoc preview build.
- Loaded images from the compiled bundle: AppIcon metadata/ICNS present,
  MenuBarIcon is a 20 × 18-point template, and PingitMark is a 32-point original.
- Visually inspected the exported contact sheet, including small optical variants
  and light/dark menu bar renderings. Live UI inspection was unavailable because
  the computer-use service timed out when opening the built app.
