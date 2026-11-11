# ADR-0002: Open the history by pressing ⌘ three times

- Status: Accepted
- Date: 2026-11-06

## Context
We wanted something easier than a three-key shortcut and did not want Macarum to
take over shortcuts other apps use. Checked on a Mac with common apps installed: ⌥Space belongs to ChatGPT and
Claude, ⌃V pastes images in Claude Code, ⌘⇧V is "paste without formatting" in many apps.
`RegisterEventHotKey` also accepts a shortcut another app already holds (tested with ⌘Space
and ⌘⇧3), so clashes cannot be detected by registering.

## Options
- ⌥V: two keys, replaces typing √.
- Double-tap ⌘: lightest, more accidental triggers.
- **Triple-tap ⌘** (chosen), plus an optional keyboard shortcut.

## Decision
Default trigger: ⌘ pressed three times on its own (each press under 0.3 s, gaps under
0.4 s). Any other key, modifier or click in between resets the count, so ⌘C/⌘V never add
up. An optional keyboard shortcut can be recorded in Settings; the recorder refuses
macOS shortcuts (defaults plus the user's own from `com.apple.symbolichotkeys`), known app
shortcuts and ⌘+key, and warns for ⌥/⌃+key and ⌘⇧+key.

## Consequences
- Watching ⌘ in other apps needs the Accessibility permission (also needed to paste for
  the person). Without it the history still opens from the menu bar icon.
- The app sees every key press to reset the count; it only keeps the tap counter.
