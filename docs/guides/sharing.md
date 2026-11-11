# Sharing Macarum

Macarum is shared outside the App Store (ADR-0005). Two ways in, both from the same file:

- **Download**: https://hundredengine.id/work/macarum/ links `Macarum-<version>.dmg`.
- **Homebrew**: `brew install --cask hundredengine/tap/macarum`; the cask in
  `hundredengine/homebrew-tap` downloads the same dmg, and `brew upgrade` picks up a new version
  once the cask's `version` and `sha256` change.

## Signing

`tools/build_dmg.sh` signs the app and the dmg with a Developer ID certificate and notarizes
both with an App Store Connect API key (`NOTARY_KEY_ID`, `NOTARY_ISSUER`, `NOTARY_KEY` in the
environment). The app gets its own stapled ticket, so it opens offline after Homebrew copies it
out of the dmg.

## Each release

1. Raise `VERSION` in `tools/build_app.sh` and add the version to `CHANGELOG.md`.
2. `tools/build_dmg.sh` prints the dmg's SHA-256.
3. Put the dmg on the website.
4. Set `version` and `sha256` in the cask. Only after the website serves the new file, or
   installs fail on a missing download.

## On the other Mac

- macOS 26 or newer (Liquid Glass panel), Apple silicon or Intel.
- Grant Accessibility (System Settings > Privacy & Security > Accessibility) so ⌘ three times
  and direct paste work, and set clipboard access to "Always Allow" when macOS asks.
