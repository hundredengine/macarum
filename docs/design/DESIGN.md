# Design direction

## App UI
Native macOS, nothing custom where the system has an answer. References: Spotlight and
Raycast (floating search panel), Maccy (clipboard rows), System Settings (grouped forms).
- System font (SF), system semantic colours, SF Symbols at one weight (medium) per surface.
- Selection uses `selectedContentBackgroundColor` with white text, like native lists.
- One surface treatment: the panel is a single Liquid Glass sheet (`NSGlassEffectView`),
  split by hairline dividers. No cards inside it, no extra shadows.
- Rhythm: tight inside a row (10 pt), looser between groups (day headers, 10 pt above).
- Drop targets (the converter) are the one place with an outline: a dashed hairline at rest,
  solid accent with a light accent fill while files hover. Choices are small bordered system
  buttons in labelled rows, never chips or cards.
- Motion: only the system's own window animation. No fades on rows.
- Forbidden: custom fonts, accent-tinted greys, pastel buttons, decorative gradients.

## App icon (design/icon/make_icon.py → Resources/AppIcon.icns)
- Motif: a macaron seen from the side (from the name), matte, on a mint squircle. Its
  layers also hint at a stack of history.
- Light from the top left. Three tones per material, shade shifted toward violet:
  shell #E8798E / #D4566F / #A93E5E, feet #C9506B / #A63D57,
  cream #F9EBD0 / #F3DDB6 / #D9B98A, background #CDEFDF → #8FD3B4.
- Two shells of equal height, porous feet a little wider than the shells, contact shadow
  touching the base.
- 16 and 32 px use a simpler drawing (`--small`): flat feet, thicker cream.
- Forbidden: gloss spots or rim strokes (reads as plastic candy), regular scallops,
  outlines, a gradient on every part.

## Menu bar icon
The same macaron as a template silhouette (`MenuBarIcon.swift`), in the app icon's
proportions: two broad, low shells, feet a little wider than each shell, and the cream drawn
fainter (42% opacity) behind a hairline gap. Taller domes with a thin cream read as a burger
(replaced 2026-11-11). Drawn in code so macOS tints it.
