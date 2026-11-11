# ADR-0001: Build our own clipboard history

- Status: Accepted
- Date: 2026-11-06

## Context
We want clipboard history for text, images and files, kept for at most 30 days,
skipping passwords, all on the Mac, in one small app that later also holds the other
Macarum tools (window on top, swap memory).

## Options
- **Spotlight clipboard history (built into macOS 26+)**: no install. Not checked in
  depth; it lives inside Spotlight, so it cannot be one part of a Macarum app, and its
  retention and type support are not under our control.
- **Maccy** (open source, MIT): small and good. Using it means one more separate app,
  and the other Macarum tools would still need their own app.
- **Paste, Raycast, Alfred**: paid or large all-in-one apps, the kind of tool we
  decided against.
- **Build it in Macarum** (Swift, SwiftUI, system SQLite, no dependencies).

## Decision
Build it in Macarum. It is the first part of the one Macarum app, and the scope is small
enough (about 2,000 lines) to keep fully understood.

## Consequences
- We own correctness: privacy rules (concealed and transient types, password managers),
  retention, and the pasteboard privacy prompt that macOS 15.4+ shows on every read until
  the app is set to "Always Allow".
- No App Store and no sandbox: the app is for this Mac only, signed with the Apple
  Development certificate so macOS permissions survive rebuilds.
