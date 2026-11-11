# ADR-0004: Convert files with macOS's own frameworks, through a converter registry

- Status: Accepted
- Date: 2026-11-07

## Context
We want a converter in the menu bar panel: drop a file, pick what it should become.
Fifteen conversions were listed; phase 1 is images and PDF (spec
`docs/specs/2026-11-07-converter.md`). Later phases add documents, video and audio.

## Options
- **Bundle tools** (ffmpeg, libwebp, ImageMagick, librsvg): every format, including WebP output.
  But large binaries to ship, sign and keep patched, and licences to watch (ffmpeg builds with
  GPL parts, ImageMagick has a long security history).
- **Call Homebrew tools if installed** (`cwebp`, `ffmpeg`): works on this Mac only, breaks
  silently on another, and the shared app would behave differently.
- **Rely on Finder Quick Actions / Preview export**: already there, but several clicks per file,
  not in the panel, and no batch shrink.
- **System frameworks only** (chosen): ImageIO and CoreGraphics for images and PDF pages,
  `NSImage` (CoreSVG) for SVG, later AVFoundation for video and audio and AppKit's
  `NSAttributedString` readers for Word/RTF/HTML.

## Decision
Use only what macOS ships, verified by running it (macOS 27.0.1, 2026-11-07):
- ImageIO reads HEIC, WebP, PNG, JPG, TIFF, GIF, BMP and writes JPG, PNG, HEIC, TIFF, GIF,
  PDF and others. It **reads WebP but cannot write it** (`org.webmproject.webp` is missing
  from `CGImageDestinationCopyTypeIdentifiers`), so WebP is input only.
- `CGImageSourceCreateThumbnailAtIndex` with the transform option applies EXIF orientation,
  keeps the colour space (Display P3 stayed P3) and never enlarges.
- `CGImageDestinationAddImage` with the source's properties copies EXIF (dates checked).
- `NSImage(data:)` renders SVG through the system's SVG image rep, including text, gradients and
  blur filters; there is no WebKit view, so it works off the main thread. ImageIO itself does
  not read SVG.
- A JPG drawn into a PDF context straight from its data stays JPG inside the PDF (2.9 MB photo
  gave a 2.9 MB PDF; a decoded copy of it gave 8 MB), so photos are embedded that way.
- `CGPDFDocument` gives page boxes, rotation and the locked state for PDF to images.

The code is a registry in `MacarumCore/Converter`: each converter says which input kinds it
takes and what it offers for a given set of files, and runs an offer. The panel only asks the
registry, so a video converter later is a new type in the list, not a new screen.

## Consequences
- No WebP output, ever, unless a later ADR accepts a bundled encoder.
- SVG features the system renderer lacks render the way Preview shows them.
- Nothing to download, sign or update besides Macarum itself; the download stays small.
- Later phases depend on what AVFoundation and AppKit can do; PDF to Word has no
  native writer for layout and is likely plain text in a `.docx` at best. To be checked then.
