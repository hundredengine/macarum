<p align="center"><img src="design/icon/AppIcon-1024.png" width="128" alt="Macarum icon"></p>

# Macarum

A small, free menu bar app for the Mac. Three tools in one macaron:

- **Clipboard history.** Everything you copy (text, links, colours, images, files) stays
  findable for a week, or up to 30 days. Press ⌘ three times, type to search, press ↩ to
  paste. Pin what you want to keep. Copies from password managers and copies marked
  private are never saved.
- **Memory check.** See memory pressure, swap and which apps hold the most memory, and
  relaunch or quit the heavy ones.
- **File converter.** Drop files on the panel, or right-click them in Finder and choose
  Convert with Macarum: photos (HEIC, WebP, PNG, JPG) to JPG or PNG, SVG to PNG, smaller photos,
  images to one PDF or an animated GIF, PDF pages to images, videos to MP4, GIF or a smaller
  size, sound between M4A, WAV and AIFF, Word, RTF and HTML to PDF or text.

**Nothing leaves your Mac.** No account, no analytics, no network code: the app never
connects to the internet. Your history lives in `~/Library/Application Support/Macarum`.

## Install

Download it from [hundredengine.id/work/macarum](https://hundredengine.id/work/macarum/),
open the file and drag Macarum to Applications. Or with [Homebrew](https://brew.sh):

```sh
brew install --cask hundredengine/tap/macarum
```

`brew upgrade` brings new versions.

Needs macOS 26 or newer, on Apple silicon or Intel. On first open, allow Macarum in
System Settings > Privacy & Security > Accessibility (for ⌘ three times and pasting), and
choose "Always Allow" when macOS asks about the clipboard.

## Use

- ⌘ three times (or click the menu bar icon) opens the history.
- Type to search, ↑↓ to pick, ↩ to paste, ⌥↩ to paste as plain text, ⌘↩ to copy only,
  ⌘1–9 to paste a row, ⌘E to edit, ⌘P to pin, ⌘⌫ to delete (⌘Z undoes it for 5 seconds),
  Tab to filter by type, Esc to close. ⌘, opens Settings.
- Prefer a keyboard shortcut over ⌘ three times? Pick one in Settings; Macarum refuses
  shortcuts that macOS and common apps already use.
- Converted files land next to the original or in a folder you choose, and never overwrite
  a file: `photo (1).jpg`.

## Build from source

Needs Xcode 27 (Swift 6.4) on macOS 26 or later. No third-party dependencies: only Apple's
own frameworks and the system SQLite.

```sh
tools/run_tests.sh      # unit tests
tools/build_app.sh      # build, install to ~/Applications and start it
```

`build_app.sh` signs with your Apple Development certificate if you have one, so macOS
keeps the permissions between builds; without one it signs ad hoc and macOS asks again
after each build. `tools/make_icon.sh` redraws the icon (needs Inkscape).

The code is split in two: `Sources/MacarumCore` holds the logic with unit tests,
`Sources/Macarum` is the app. Decisions are in `docs/adr/`, behaviour in `docs/specs/`.

## Contributing

Macarum is a small project made for daily use. Bug reports are welcome as issues. For a
new feature, please open an issue first; the app stays small on purpose.

## License

The code is [MIT](LICENSE). The Macarum name and icon belong to Hundred Engine; please use
a different name and icon if you ship your own version.
