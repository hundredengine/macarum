# Spec: File converter

Date: 2026-11-07, extended 2026-11-08. Status: all 15 conversions built (phase 1: images and PDF,
phase 2: video, sound and documents). Approach: ADR-0004.

## Goal
Turn a file into the format needed right now (a HEIC photo into a JPG for a form, a PDF into
page images, a big photo into a smaller one) without opening an app or a website. Nothing
leaves the Mac.

## Where it lives
A "Convert" section at the top of the menu bar panel (above Memory). It sits at the top
because that is the nearest target when a file is dragged from Finder to the menu bar icon,
and because its idle state is a single row (44 pt), so the memory summary moves down only a
little.

- Idle: a dashed drop zone, "Drop files to convert", with a "Choose…" button (standard open
  panel, several files allowed).
- The whole panel accepts a drop, not only the zone; while files hover over it the zone turns
  accent coloured and says "Drop to convert".
- Dragging from Finder with the panel open: pressing the mouse in Finder used to close the
  panel straight away. Now an outside click closes it when the button comes up, unless a file
  drag happened and was dropped on the panel. A plain click elsewhere still closes it.
- Dragging files onto the menu bar icon opens the panel (spring-loaded); dropping them on the
  icon opens the panel with those files already picked.

## Picking an output
After a drop or a choice the zone shows what came in ("IMG_2041.heic", "3 images") with an ×
to clear, and only the outputs that make sense for it. Pick an output (it lights up), then press Convert (or Return); nothing starts on its own. When only one output fits, it is picked already.

| Input | Offered |
|---|---|
| One image (HEIC, JPG, PNG, WebP, TIFF, GIF, BMP…) | To: JPG, PNG (not its own format), PDF. Max file size: 5 MB, 2 MB, 1 MB, 500 KB (only the ones below the file's size) |
| Several images | Each to: JPG, PNG. Combine: One PDF. Max file size: as above, for each |
| Several images (also) | Combine: Animated GIF |
| SVG (one or more) | To: PNG, at 1×, 2× (default) or 4× its size |
| PDF (one or more) | To: "Word, text only". Pages to: PNG, JPG |
| Video (MOV, MP4, M4V; one or more) | To: MP4 (not for MP4 files), GIF. Sound only: M4A (only when every video has sound). Video size: 1080p, 720p (only sizes smaller than the biggest video) |
| Sound (M4A, WAV, AIFF, MP3, CAF…) | To: M4A, WAV, AIFF (not its own format) |
| Word (.docx, .doc), RTF, HTML | To: PDF, Text |
| Mixed kinds | Only what applies to all of them; if nothing does, a short message |
| Anything else | "Macarum can't convert .zip files yet." Unsupported files in a mix are skipped and named |

Some offers carry one plain sentence that shows under the choices once the offer is picked:
Animated GIF "Each picture shows for half a second, then it starts over."; video GIF "At most
480 px wide, 10 frames a second, without sound." (or "Only the first 15 seconds go into the
GIF, at most 480 px wide." for a longer video); Text "Only the words, without fonts, pictures or
layout."; Word "Only the text comes over. The layout and images are not kept." Video offers
need the video's size and length, which AVFoundation reads off the main thread; the choices
appear when that is done, and "Reading the file…" shows only if it takes more than 0.3 s.

A "JPG quality" choice (Best 0.95, Good 0.85 default, Small 0.7) shows only when a JPG or HEIC
can come out; it is remembered.

## Exact behaviour
- **Image to JPG/PNG**: read with ImageIO, write with ImageIO. The EXIF
  orientation is applied to the pixels and the output says orientation 1, so every viewer shows
  it upright. The colour profile is kept (a Display P3 photo stays Display P3). Other metadata
  (EXIF dates, camera, GPS) is copied as it is; nothing is stripped. A transparent image going
  to JPG gets a white background. Animated GIF or HEIC sequences use their main frame. WebP can
  be read but macOS cannot write it (checked on macOS 27.0.1), so WebP is never offered as an output.
- **Max file size** (people shrink a photo to fit an upload form, not to a
  pixel width): "2 MB" is 2,000,000 bytes, so it also fits a form counting 2 × 1024 × 1024. The
  result is JPG (PNG when the image is transparent) at the highest quality from 0.92 down to 0.6
  that fits; only when 0.6 is still too big are the pixels reduced, keeping the aspect ratio.
  A file already under the limit is copied as is. Below 200 px wide it gives up and says so.
- **Right-click in Finder**: "Convert with Macarum" (a macOS Service, `NSServices` in the
  Info.plist: images, PDFs, movies, sound, Word, RTF and HTML) opens the panel with the files
  picked.
  Names: `photo 1200px.jpg`, `photo under 2MB.jpg`.
- **SVG to PNG**: drawn by macOS's own SVG renderer (`NSImage`, the one Finder and
  Preview use) at its own size times the chosen scale; a file without a size uses its viewBox.
  The background stays transparent. Features the system renderer lacks render as it does in
  Preview.
- **Images to one PDF** (also "PDF" for a single image): one page per image in the order
  dropped or chosen, each page the image's size at its own resolution (72 dpi when it has none),
  no margins, like Finder's "Create PDF". JPG photos are embedded as they are; other opaque
  images are embedded as JPG at the chosen quality; transparent ones stay lossless. The PDF is
  named after the first image.
- **PDF to images**: every page at 144 dpi (twice its size in points, an A4 page is
  1191 × 1684 px), on white, with the page rotation applied. A one-page PDF gives
  `report.png`; more pages go into a new folder `report/` as `report 01.png`, `report 02.png`
  (numbers padded so they sort). A PDF locked with a password is refused with a clear message.

- **Images to an animated GIF**: one frame per image in the order dropped or chosen,
  each shown 0.5 s, looping forever. Every frame is the size of the biggest image (by area),
  scaled down to at most 1200 px on its long side; other images are fitted in, keeping their
  shape, centred on white (GIF has no partial transparency, white reads cleanest). Named after
  the first image. An image that cannot be read is named as a failure; the rest still make the GIF.
- **Video to MP4**: picture and sound are copied as they are when MP4 can hold them
  (H.264, HEVC, AAC: fast and lossless); otherwise re-encoded at the highest quality preset.
  The MP4 is written with its index at the front, so uploads can start playing early.
- **Smaller video**: AVFoundation's 1920×1080 or 1280×720 preset, as MP4, named
  `holiday 720p.mp4`. Offered only when the video is bigger than that box (long side × short
  side, so a portrait 1080×1920 video is offered 720p, not 1080p). Never enlarges.
- **Video to GIF**: the first 15 seconds at most, 10 frames a second, at most 480 px
  wide (never enlarged), looping, no sound. Frames are taken within half a frame of their time,
  which is much faster than exact times; a frame that cannot be read repeats the one before.
- **Sound out of a video**: AVFoundation's Apple M4A preset (AAC). A video without
  sound gets "This video has no sound."
- **Sound files**: M4A is AAC through the same preset. WAV and AIFF are uncompressed
  PCM at the source's rate and channels, 16-bit (24-bit when the source is 24-bit PCM).
- **Video and sound in general**: the folder is checked first, so a long job does not fail at
  the end on permission. AVFoundation writes to the temporary folder, then the file is moved to
  its free name (never replacing a file). Cancel stops the running export straight away and
  leaves nothing behind; finished files stay. Copy protected files are refused ("This file is
  copy protected, so it can't be converted."). A video AVFoundation cannot open
  gives "Macarum couldn't open this file." instead of offers; a broken sound file gets
  "Macarum couldn't open this sound file." when converting.
- **Documents to PDF or text**: read with AppKit's own readers (`NSAttributedString`:
  Office Open XML, Word 97, RTF, HTML). HTML import uses WebKit on the main thread and loads
  nothing from the internet (checked with a local server: no request for a remote image or
  stylesheet). The PDF is the text laid out with TextKit on the document's own paper and
  margins (A4 with 2.5 cm margins when it says none), like printing from TextEdit. Text is
  UTF-8 `.txt`. An empty document gives "This document has no text."; an unreadable one
  "Macarum couldn't read this document."
- **PDF to Word**: the text of each page (PDFKit) one after another, saved as `.docx`
  by AppKit's Office Open XML writer. macOS has nothing that rebuilds a PDF's layout, so the
  offer says "text only" and its note says layout and images are not kept. A PDF without text
  (scanned pages) gives "This PDF has no text to copy. It may be scanned pages."; a locked one
  the usual password message.

## Saving
- Settings, "Converter" section: "Save to" Next to the original (default) or a chosen folder
  (Downloads is the suggestion). A missing chosen folder falls back to asking: the error says
  so and points to Settings.
- Names never overwrite: `photo.jpg`, then `photo (1).jpg`, `photo (2).jpg`. Files are written
  with exclusive create, so a file that appears meanwhile is not overwritten either.
- "Copy the result to the clipboard" toggle (off by default). Copying puts one image as its
  file plus its image data (so Finder pastes a file and chat apps paste the picture); several
  results or a PDF go as files.
- Copied results are added to Macarum's clipboard history once, as coming from Macarum. The
  monitor skips that clipboard change, so there is no second entry, and the same result copied
  again moves the existing entry to the top (the history's normal duplicate rule).

## While it runs and after
- Work runs off the main thread, one file at a time; the panel stays responsive. A progress bar
  with "Converting 3 of 12…" and Cancel shows while it runs (files already done are kept).
  Video and sound report progress within a file too: one file shows "Converting… 42%", and
  the bar moves smoothly across several.
- Success: "Saved IMG_2041.jpg" or "Saved 3 files in Downloads", with Show in Finder (selects
  the results) and Copy. A new drop starts over; × clears.
- Errors are short and say what to do: "IMG_2041.heic: Macarum couldn't read this image.",
  "report.pdf is locked with a password.", "Can't save in Desktop: permission denied.
  Choose another folder in Settings." When some files fail, the others still save and the
  message says "2 saved, 1 failed".

## Not now
WebP output, editing (crop, rotate, trim a video), choosing pages, a custom width or GIF speed,
metadata removal, PDF to Word with layout (no system framework does it, ADR-0004).
