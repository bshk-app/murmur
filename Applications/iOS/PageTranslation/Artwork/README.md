# Safari action icon

`ActionAssets.xcassets/ActionIcon.appiconset` belongs only to `MurMurPageTranslation`.
Its transparent cat outline matches Murmator's mascot and remains readable when
Safari tints the action list for light or dark appearance. Do not replace it with
the containing application's opaque App Store icon: Safari uses the alpha mask,
so an opaque square becomes a solid square in the Share menu.

Apple specifies a template version of the containing application's icon for a
custom iOS Action extension in [Creating an App Extension](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionCreation.html#//apple_ref/doc/uid/TP40014214-CH5-SW4).

The CoreGraphics path in `GenerateActionIcon.swift` is the editable vector source.
To regenerate the PNG sizes and asset catalog manifest, run from `Applications/iOS`:

```sh
swift PageTranslation/Artwork/GenerateActionIcon.swift
tuist generate --no-open
```

Validate in Safari's actual Share menu, in both light and dark appearance, with
`MurMurPageTranslation` embedded in the production app or `MurmatorPageTestHost`.
Inspect the compiled extension's `CFBundleIcons` and `CFBundleIcons~ipad` entries
as well as the visible icon; successful asset compilation alone is insufficient.
