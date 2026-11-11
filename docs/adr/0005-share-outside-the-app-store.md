# ADR-0005: Share Macarum as a notarized dmg from the website and a Homebrew tap

- Status: Accepted
- Date: 2026-11-11
- Amends: ADR-0001 ("no App Store and no sandbox: the app is for this Mac only")

## Context
We want other people to be able to use Macarum, installed the way Mac apps
usually are, and upgraded through Homebrew like other casks.

## Options
- **Mac App Store**: needs the sandbox. Free Cached Memory runs `purge` with the admin password
  (guideline 2.4.5 forbids asking for root), Relaunch/Quit ends other apps' processes, and the
  ⌘ ⌘ ⌘ monitor and direct paste lean on Accessibility. Features would be cut and review could
  still refuse. Rejected.
- **pkg installer** (tried first): needs a second certificate (Developer ID
  Installer) and an install wizard for an app that is one folder. Homebrew installs apps from a
  dmg or zip. Replaced.
- **dmg, signed and notarized, on hundredengine.id plus a Homebrew tap**: the usual drag to
  Applications, one file for both routes, `brew upgrade` follows the cask. Chosen.
- **Official homebrew/cask**: asks for a notable app; a self-submitted new app is usually
  refused. The tap can be offered there later.
- **In-app updates (Sparkle)**: download users would get new versions without Homebrew. More
  work and a feed to host; not now.

## Decision
`tools/build_dmg.sh` signs the app and dmg with Developer ID, notarizes and staples both (the app
too, so it opens offline once Homebrew copies it out). The site serves the dmg at
`/download/macarum/Macarum-<version>.dmg`; the public repo `hundredengine/homebrew-tap` holds
`Casks/macarum.rb` pointing at that file. Steps in `docs/guides/sharing.md`.

## Consequences
- Download users only learn about new versions from the site until in-app updates exist.
- Each release touches three places (this repo, the website, the Homebrew tap), in that order.
- Privacy promise is public now: nothing leaves the Mac, no account, no telemetry.
