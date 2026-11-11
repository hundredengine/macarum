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

## Welcome window
Shown once on first launch, before macOS asks for anything (spec
`docs/specs/2026-11-11-welcome.md`). References and what is taken from each:
- Apple's own "Welcome to …" sheets (Pages, Notes, Reminders): a bold title, then rows of one
  tinted symbol, a semibold title and one grey line; one prominent button at the bottom right.
  Taken: the row anatomy, the accent on symbols and on the one button, no title bar text.
- Rectangle's Accessibility window: one small window, one button that opens System Settings,
  and it notices the permission by itself. Taken: a single window and the live check.
- CleanShot X's permission list: the state sits next to the permission and turns into a green
  check mark. Taken: the state line (waiting with the system spinner, then the green check).
- Raycast's onboarding: ends by teaching the shortcut. Taken: the last line says "Press ⌘ three
  times to try it". Not taken: several pages, illustrations, progress dots.
- Maccy: no onboarding, the bare macOS prompt on first use. That is what this window replaces;
  taken: the menu bar glyph shown as it really looks, so people know what to look for.

The one direction:
- One fixed window (520 pt wide), not resizable, no title text, close button only, centred.
- One text edge. The app icon (56 pt) and the row symbols (22 pt, medium, accent) share the
  left column; the title, every row and the state line start at the same x. Nothing is centred.
- Rhythm: 2 pt between a row's title and its line, 14 pt between rows, 24 pt under the
  header, 20 pt around the one hairline that separates the tools from the permission.
- Feature rows are one line each. The permission is the only block with a paragraph: the
  first sentence in the primary colour, what Macarum does with it in secondary.
- One primary action (the default button, system style). "Not Now" is a plain button to its
  left. The state line above them has the same height in every state, so the window never
  changes size.
- Colour only from the system: accent, label colours, system green for the check mark. The
  app icon is the only illustration.
- Copy: short, says what happens, names the thing people miss (no Dock icon). No "Get
  started", no exclamation marks. Claims about the permission must match the code.

## App icon (design/icon/make_icon.py → Resources/AppIcon.icns)
- Motif: a macaron seen from the side (from the name), matte, on a pale sky blue squircle. Its
  layers also hint at a stack of history. Pink and cream both stand clear of the blue, and the
  icon stays bright in a light and a dark Dock.
- Class: the macOS 26 system icons. A simple, clean object with few layers; detail is taken
  away, not added. Compared side by side with twelve system icons before it shipped.
- Light from the top left. Three tones per material, shade shifted toward violet:
  shell #FFA3B4 / #F06A86 / #CC4A6C (deep #A2365A), feet #C94468 / #96305A,
  cream #FBE7BF / #F1D39C / #D2A869, background #DCEEFB → #A6D2F1.
- Two shells of equal height with broad shoulders and a gently rounded crown; the top shell
  has one clear lit plane, the bottom shell is a step darker. The feet are one matte band a
  little wider than the shells, with an uneven edge and a few dark pores. The cream is thinner
  than a shell and sits a little inside them. One contact shadow touching the base.
- 16 and 32 px use a simpler drawing (`--small`): feet as one dark line, a narrower cream.
- Forbidden: gloss spots or rim strokes (reads as plastic candy), a highlight on each ruffle
  (reads as beads), a glossy streak along the cream (reads as a plastic tube), grain or noise,
  a radial glow behind the macaron, regular scallops, outlines, green or purple backgrounds.
- The body is drawn outside any SVG filter and filters work in sRGB: a filter rounds dark
  colours to few steps, which shows as bands in a smooth gradient.

## Menu bar icon
The same macaron as a template silhouette (`MenuBarIcon.swift`), in the app icon's
proportions: two broad, low shells, feet a little wider than each shell, and the cream drawn
fainter (42% opacity) behind a hairline gap. Taller domes with a thin cream read as a burger
(replaced 2026-11-11). Drawn in code so macOS tints it.
