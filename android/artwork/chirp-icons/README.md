# Chirp Android icon sources

The operator selected `app-icon-08-pond-moonlight-fullbleed-1024.png` and
`glyph-13-round-finbird-black-1024.png` on 2026-10-17. Their exact source pixels are
preserved as `approved-pond-fullbleed.png` and `approved-glyph.png`.

The adaptive icon uses the complete opaque, full-bleed pond artwork as its background
and an empty foreground, as explicitly allowed by the operator. Built-in imagegen
cutout attempts changed details of the selected bird and were discarded. **No generated
cutout or replacement illustration ships. No rounded tile or border is added.**
The navy overscan fits the moon and bird into the central 72/108 dp viewport without
changing their identity. Android launchers choose the mask.

The themed icon uses the original glyph's alpha, with sound waves. The notification
uses that **same original alpha**, cropped before the detached waves, retaining the eye,
pupil, tail fins and feet. Android supplies the notification/theme tint.

Run `swift android/scripts/make-icons.swift` to regenerate:

- `app/src/main/res/drawable-nodpi/chirp_launcher_{background,foreground,monochrome}.png`
- `app/src/main/res/drawable-nodpi/ic_chirp_notification.png`
- `app/src/main/res/mipmap-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/ic_launcher.png`
  and round-name aliases in `values-{density}/mipmap_aliases.xml`.
- `adaptive-preview.png`, a circular-mask review preview only.

Adaptive XML uses a 108 dp canvas and adds `<monochrome>` on Android 13+. Legacy PNGs, shared by normal and round resource names,
are also full bleed; no shape is baked into them. The app overrides HeliBoard's
`ic_launcher` and `ic_launcher_round` names at all densities and adaptive qualifiers,
including the resource used by its settings About screen. Application and IME service
explicitly reference the new mipmap.

Lint retains warnings-as-errors with two icon-only style exceptions in
`app/lint.xml`: the v26 folder must match HeliBoard's qualifier to override it on API
31/32, and opaque legacy launcher art is intentional per the operator. Runtime icon
selection, mask rendering and monochrome presence are tested on API 31 and 37.

The shipped assets use the supplied sources and deterministic packaging only; there is
no generation prompt for the final artwork. The built-in imagegen tool was used only
for the discarded intermediate cutout attempts.
