# Clipboard history

Date: 2026-11-06. Status: built (v0.1).

## What it does
- Saves every copy (text, links, colours, images, files) with the app it came from.
- Skips copies marked concealed or transient (password managers, nspasteboard.org markers),
  copies from password apps, and apps the person adds to an ignore list.
- Same content copied again moves to the top instead of making a duplicate.
- Keeps items for 1 day, 1 week, 2 weeks or 30 days (default 1 week since pinning exists, maximum 30), with a hard
  2 GB ceiling; oldest go first.

## Opening and using the panel
- ⌘ pressed three times (ADR-0002) or a keyboard shortcut, one of the two (ADR-0003), or the
  menu bar icon.
- A floating panel that does not take focus from the app underneath (like Spotlight):
  search field, day-grouped list, preview pane, metadata.
- Keys: ↑↓ move, ⌘↑/⌘↓ jump to ends, ↩ paste, ⌥↩ paste as plain text, ⌘↩ copy only,
  ⌘1–9 paste that row, ⌘E edit, ⌘P pin, ⌘⌫ delete (see below), ⌘Z undo a delete,
  ⇧⌘⌫ clear all (asks first in the footer), Tab cycles the type filter, Esc clears search then closes.

## Selection and delete keys (2026-11-07)
- Several rows can be selected, like a Finder list: ⌘-click toggles a row, ⇧-click selects
  the range from the last plainly clicked or ⌘-clicked row, ⇧↑/⇧↓ (and ⇧⌘↑/⇧⌘↓, ⇧Page Up/Down)
  grow or shrink that range. The last selected row cannot be ⌘-clicked off. This works the
  same during a search: select several results and delete them.
- With several selected the preview pane shows "N items selected" (and how many are pinned)
  with Pin and Delete buttons. Pin pins them all; when all are already pinned it reads Unpin
  and unpins them all (⌘P does the same).
- ↩, ⌥↩, ⌘↩ and ⌘E act on one item only, so they do nothing while several are selected
  (no Paste hint is shown then). ⌘1–9 still pastes that row and selects only it.
- Only ⌘⌫ (or ⌘⌦) deletes the selected rows. ⌫ and ⌦ alone always edit the search text and
  never delete items, so clearing a search by holding ⌫ cannot run on into the history
  (2026-11-07: ⌫ alone deleting items after the search text was gone felt dangerous;
  the first version let ⌫ delete once the text was empty or the list had been clicked).
  The footer shows "⌘⌫ Delete" while a row is selected. While an item is edited, all keys
  belong to the editor (unchanged).
- After a delete the row below the deleted ones is selected (or the one above, at the end).
  The search and type filter stay as they were, so the remaining results stay filtered.

## Undo a delete
- Every delete (one row or several, pinned rows too) can be undone. The footer shows
  "Deleted N items" with an Undo button and ⌘Z for 5 seconds. A second delete inside that
  time joins the first, so one Undo brings both back and the 5 seconds start again.
- Undo puts the items back exactly: content, every saved format and blob file, pin,
  timestamps and copy count, and so their old place in the list. Restored rows that match
  the current search and filter show up there again and are selected.
- How (`ClipStore.trash`/`restore`/`emptyTrash`): a delete only marks the rows with a batch
  number (`trash_batch`); every read, the retention purge, the size limit and Clear All skip
  marked rows, and blob files stay on disk. The rows and files are removed for real when the
  5 seconds pass, when the panel closes, or, after a quit or crash, when the store opens at
  the next launch. Copying the same content again while it waits brings that row back as
  a normal copy. An edit that equals a deleted row removes that row for real.
- Clear All keeps its confirmation and has no undo.
- Pin (⌘P or the Pin button): pinned items sit in a "Pinned" section at the top and are never
  removed by the retention period, the size limit, Clear All or Clear History; only Delete or
  Unpin. An edit that merges into a pinned item keeps the pin.
- Buttons above the preview: Pin, Copy, Edit (text, links, colours only) and Delete. No right-click
  menu: it proved confusing (macOS also adds "Ask Siri" to it).
- Edit: the preview turns into a text editor, the list waits (dimmed). ⌘↩ or Save keeps the
  text, Esc or Cancel drops it. A saved edit replaces the item with plain text (rich formats
  are dropped), moves it to the top, and merges with an identical item if there is one.
- Footer: "Clear All…" asks "Delete all N items?" in place; ↩ confirms, Esc cancels.
- Paste writes the item back to the clipboard and presses ⌘V for the person (needs
  Accessibility; without it the item is just copied).

## Storage
`~/Library/Application Support/Macarum/history.sqlite` (WAL) plus `blobs/` for any single
format over 256 KB. Only standard formats are kept (plain text, RTF, RTFD, HTML, PNG, TIFF,
JPEG, HEIC, PDF, file and web URLs). Search runs over a folded (case and accent
insensitive) copy of the text plus the source app name; every word must match.

## Performance budget
- Idle: one change-counter read every 0.5 s with 0.25 s leeway, no other work.
- Capture: hashing, thumbnail (96 px, decoded at that size) and disk writes happen in the
  store actor, off the main thread.
- Panel: list rows carry only a title and a tiny thumbnail; full text and images are
  loaded for the selected row only, after a 40 ms pause, and freed when the panel closes.
