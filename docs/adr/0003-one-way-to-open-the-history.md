# ADR-0003: One way to open the history at a time

- Status: Accepted (replaces the "plus an optional keyboard shortcut" part of ADR-0002)
- Date: 2026-11-06

## Context
Settings showed a "⌘ three times" toggle and a separate keyboard shortcut field at once.
It was unclear what the shortcut was for: two triggers side by side read as two features,
and it was unclear which one was in use.

## Options
- Keep both, with help text explaining that either works.
- Drop the shortcut and keep only ⌘ three times.
- **One choice, "Open history with": ⌘ three times or a keyboard shortcut** (chosen).

## Decision
Settings has a single "Open history with" picker. Only the chosen trigger is active. The
shortcut recorder appears only when "Keyboard shortcut" is picked, and it keeps the clash
rules from ADR-0002. The default stays ⌘ three times.

## Consequences
- People who cannot or will not grant Accessibility (needed to watch ⌘ in other apps) can
  switch to a shortcut, which works without it.
- Inside the panel, shortcuts such as ⌘E or ⌘↩ are swallowed by the panel's own key
  handling, so the ⌘ counter also asks macOS when a key last went down; a ⌘ press with a
  key during it never counts as a tap.
