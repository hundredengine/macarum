import AppKit
import ImageIO
import MacarumCore
import Observation

/// What the preview pane shows for the selected item, loaded on demand.
enum PreviewContent {
    case text(String, lineCount: Int, characterCount: Int, looksLikeCode: Bool)
    case link(URL)
    case color(String, NSColor)
    case image(NSImage)
    case files([URL])
    case unavailable
}

/// A run of items copied on the same day, for the list headers.
struct DaySection: Identifiable {
    let id: String
    let title: String
    let items: [(index: Int, item: ClipItem)]
}

@MainActor @Observable
final class HistoryModel {
    nonisolated static let previewTextLimit = 100_000
    nonisolated static let previewImagePixels = 1600

    let store: ClipStore

    var query = "" {
        didSet {
            guard query != oldValue else { return }
            scheduleReload(delay: .milliseconds(60))
        }
    }
    var filter: ClipFilter = .all { didSet { if filter != oldValue { scheduleReload(delay: .zero) } } }

    private(set) var items: [ClipItem] = []
    private(set) var sections: [DaySection] = []
    /// The selected rows; the focused one drives the preview and single-item actions.
    private(set) var selection = ListSelection()
    /// The last delete, undoable until `undoWindow` passes or the panel closes.
    private(set) var pendingUndo: PendingUndo?
    private(set) var preview: PreviewContent?
    private(set) var totalCount = 0
    /// What Clear All removes: pinned items stay.
    private(set) var unpinnedCount = 0
    private(set) var hasLoaded = false
    /// Changes every time the panel opens, so the search field takes focus again.
    private(set) var focusToken = 0
    /// Bumped by keyboard moves so the list scrolls the selection into view.
    private(set) var scrollToken = 0
    /// True while the selected item's text is edited in the preview pane.
    private(set) var isEditing = false
    var editDraft = ""
    /// The footer asks "Delete all?" before the history is emptied.
    private(set) var isConfirmingClearAll = false

    var onChoose: (ClipItem, PasteMode) -> Void = { _, _ in }

    struct PendingUndo: Equatable {
        let batch: Int64
        let count: Int
    }

    /// How long "Deleted N items · Undo" stays in the footer.
    static let undoWindow: Duration = .seconds(5)
    private var undoTask: Task<Void, Never>?

    private var reloadTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?

    init(store: ClipStore) {
        self.store = store
    }

    var selectedID: Int64? { selection.focus }

    var selectedItem: ClipItem? {
        selectedID.flatMap { id in items.first { $0.id == id } }
    }

    var isMultiSelected: Bool { selection.isMultiple }

    /// The selected rows in list order.
    var selectedItems: [ClipItem] { items.filter { selection.ids.contains($0.id) } }

    func isSelected(_ id: Int64) -> Bool { selection.ids.contains(id) }

    var selectedIndex: Int? {
        selectedID.flatMap { id in items.firstIndex { $0.id == id } }
    }

    // MARK: Loading

    func panelWillOpen() {
        query = ""
        filter = .all
        selection = ListSelection()
        isConfirmingClearAll = false
        isEditing = false
        focusToken += 1
        scheduleReload(delay: .zero)
    }

    /// Frees images and long text while the panel is hidden.
    func panelDidClose() {
        finishPendingDelete()
        reloadTask?.cancel()
        previewTask?.cancel()
        preview = nil
        items = []
        sections = []
        hasLoaded = false
    }

    func scheduleReload(delay: Duration) {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    func reload() async {
        let query = query
        let filter = filter
        guard let found = try? await store.items(matching: query, filter: filter, limit: 2000) else { return }
        guard query == self.query, filter == self.filter else { return }
        let stats = try? await store.stats()
        items = found
        totalCount = stats?.itemCount ?? found.count
        unpinnedCount = totalCount - (stats?.pinnedCount ?? 0)
        sections = Self.groupByDay(found)
        hasLoaded = true
        selection.keep(only: found.map(\.id))
        if selection.focus == nil {
            preview = nil
            select(found.first?.id, scroll: true)
        } else {
            loadPreview()
        }
    }

    private var itemIDs: [Int64] { items.map(\.id) }

    // MARK: Selection and actions

    func select(_ id: Int64?, scroll: Bool = false) {
        guard id != selectedID || isMultiSelected || preview == nil else { return }
        selection.select(id)
        if scroll { scrollToken += 1 }
        loadPreview()
    }

    /// A click on a row: ⌘ toggles it, ⇧ selects the range from the anchor, plain picks it.
    func click(_ id: Int64, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            selection.toggle(id)
            loadPreview()
        } else if modifiers.contains(.shift) {
            selection.extend(to: id, in: itemIDs)
            loadPreview()
        } else {
            select(id)
        }
    }

    /// ↑/↓ (and page keys); with ⇧ the selection grows or shrinks from its anchor.
    func moveSelection(by offset: Int, extend: Bool = false) {
        guard !items.isEmpty else { return }
        if extend {
            selection.extend(by: offset, in: itemIDs)
            scrollToken += 1
            loadPreview()
            return
        }
        let current = selectedIndex ?? -1
        let next = max(0, min(items.count - 1, current + offset))
        select(items[next].id, scroll: true)
    }

    func moveToEdge(top: Bool, extend: Bool = false) {
        guard let edge = (top ? items.first : items.last)?.id else { return }
        if extend {
            selection.extend(to: edge, in: itemIDs)
            scrollToken += 1
            loadPreview()
        } else {
            select(edge, scroll: true)
        }
    }

    /// ↩, ⌥↩ and ⌘↩ act on one item only; with several selected they do nothing.
    func choose(_ mode: PasteMode) {
        guard !isMultiSelected, let item = selectedItem else { return }
        onChoose(item, mode)
    }

    func choose(index: Int, mode: PasteMode) {
        guard items.indices.contains(index) else { return }
        select(items[index].id)
        onChoose(items[index], mode)
    }

    /// Text, links and colours can be edited; images and files cannot.
    var canEditSelected: Bool {
        guard !isMultiSelected, let kind = selectedItem?.kind else { return false }
        return kind == .text || kind == .link || kind == .color
    }

    func startEditing() {
        guard canEditSelected, let item = selectedItem else { return }
        Task {
            guard let snapshot = try? await store.snapshot(for: item.id),
                  let data = snapshot.first(PasteboardType.plainText),
                  let text = String(data: data, encoding: .utf8),
                  selectedID == item.id, !isMultiSelected else { return }
            editDraft = text
            isEditing = true
        }
    }

    func cancelEditing() {
        isEditing = false
        focusToken += 1
    }

    /// Saves the edit unless it is empty or unchanged; the item stays selected at the top.
    func saveEditing() {
        guard isEditing, let item = selectedItem else { return }
        let text = editDraft
        isEditing = false
        focusToken += 1
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            try? await store.replaceText(of: item.id, with: text)
            preview = nil
            selection.select(item.id)
            scrollToken += 1
            await reload()
        }
    }

    func choose(_ item: ClipItem, mode: PasteMode) {
        select(item.id)
        onChoose(item, mode)
    }

    func togglePin(_ item: ClipItem) {
        Task {
            try? await store.setPinned(item.id, !item.isPinned)
            scrollToken += 1
            await reload()
        }
    }

    /// With several selected: unpins them when all are pinned, otherwise pins them all.
    var selectionIsAllPinned: Bool { selectedItems.allSatisfy(\.isPinned) }

    func togglePinSelected() {
        let targets = selectedItems
        guard !targets.isEmpty else { return }
        let pin = !targets.allSatisfy(\.isPinned)
        Task {
            try? await store.setPinned(targets.map(\.id), pin)
            scrollToken += 1
            await reload()
        }
    }

    /// Deletes the selected rows (pinned ones too) as one undoable step; the selection moves
    /// to the row below them, or above at the end. A delete made while the previous one can
    /// still be undone joins it, so one Undo brings both back.
    func deleteSelected() {
        let ids = selection.ordered(in: itemIDs)
        guard !ids.isEmpty else { return }
        let nextID = selection.successor(in: itemIDs)
        let joining = pendingUndo
        selection.select(nextID)
        preview = nil
        Task {
            guard let batch = try? await store.trash(ids, into: joining?.batch) else { return }
            pendingUndo = PendingUndo(batch: batch, count: (joining?.count ?? 0) + ids.count)
            startUndoTimer(for: batch)
            scrollToken += 1
            await reload()
        }
    }

    /// Puts the last deleted items back where they were and selects the ones the current
    /// search and filter still show.
    func undoDelete() {
        guard let pending = pendingUndo else { return }
        undoTask?.cancel()
        pendingUndo = nil
        Task {
            guard let restored = try? await store.restore(pending.batch) else { return }
            await reload()
            let back = Set(restored)
            let shown = itemIDs.filter { back.contains($0) }
            guard let first = shown.first else { return }
            selection.select(first)
            for id in shown.dropFirst() { selection.toggle(id) }
            scrollToken += 1
            loadPreview()
        }
    }

    private func startUndoTimer(for batch: Int64) {
        undoTask?.cancel()
        undoTask = Task { [weak self] in
            try? await Task.sleep(for: Self.undoWindow)
            guard !Task.isCancelled else { return }
            self?.finishPendingDelete()
        }
    }

    /// The undo window is over: the deleted items and their files go for real.
    private func finishPendingDelete() {
        undoTask?.cancel()
        undoTask = nil
        guard let pending = pendingUndo else { return }
        pendingUndo = nil
        let store = store
        Task { _ = try? await store.emptyTrash(pending.batch) }
    }

    func askToClearAll() {
        guard unpinnedCount > 0 else { return }
        isConfirmingClearAll = true
    }

    func cancelClearAll() {
        isConfirmingClearAll = false
    }

    func clearAll() {
        isConfirmingClearAll = false
        Task {
            try? await store.deleteAll()
            selection = ListSelection()
            preview = nil
            await reload()
        }
    }

    func cycleFilter(backwards: Bool = false) {
        let all = ClipFilter.allCases
        let i = all.firstIndex(of: filter) ?? 0
        filter = all[(i + (backwards ? all.count - 1 : 1)) % all.count]
    }

    // MARK: Preview

    private func loadPreview() {
        previewTask?.cancel()
        guard !isMultiSelected, let item = selectedItem else {
            preview = nil
            return
        }
        // Simple kinds render from the row alone, without touching the store.
        switch item.kind {
        case .link where URL(string: item.title) != nil:
            preview = .link(URL(string: item.title)!)
            return
        case .color:
            if let c = ClipClassifier.hexColorComponents(item.title) {
                preview = .color(item.title, NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a))
                return
            }
        default:
            break
        }
        let store = store
        previewTask = Task { [weak self] in
            // Waiting a moment while arrow keys repeat avoids decoding images nobody looks at.
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled, let snapshot = try? await store.snapshot(for: item.id) else { return }
            let content = await Self.makePreview(item: item, snapshot: snapshot)
            guard !Task.isCancelled, self?.selectedID == item.id else { return }
            self?.preview = content
        }
    }

    nonisolated private static func makePreview(item: ClipItem, snapshot: ClipSnapshot) async -> PreviewContent {
        switch item.kind {
        case .image:
            for type in PasteboardType.images {
                if let data = snapshot.first(type), let image = downsampledImage(data) { return .image(image) }
            }
            return .unavailable
        case .file:
            let urls = snapshot.all(PasteboardType.fileURL)
                .compactMap { String(data: $0, encoding: .utf8).flatMap(URL.init(string:)) }
            return urls.isEmpty ? .unavailable : .files(urls)
        case .text, .link, .color:
            guard let data = snapshot.first(PasteboardType.plainText), let full = String(data: data, encoding: .utf8) else {
                return .unavailable
            }
            let text = full.count > previewTextLimit ? String(full.prefix(previewTextLimit)) + "\n…" : full
            let lines = full.split(separator: "\n", omittingEmptySubsequences: false)
            let indented = lines.filter { $0.hasPrefix("    ") || $0.hasPrefix("\t") }.count
            let codeMarks = full.filter { "{};<>=".contains($0) }.count
            let looksLikeCode = lines.count > 2 && (Double(indented) / Double(lines.count) > 0.25 || codeMarks > lines.count)
            return .text(text, lineCount: lines.count, characterCount: full.count, looksLikeCode: looksLikeCode)
        }
    }

    nonisolated private static func downsampledImage(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: previewImagePixels,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    // MARK: Day groups

    /// Pinned items in their own section at the top, then one section per day.
    static func groupByDay(_ items: [ClipItem], now: Date = Date(), calendar: Calendar = .current) -> [DaySection] {
        var sections: [DaySection] = []
        let pinned = items.enumerated().filter { $0.element.isPinned }.map { ($0.offset, $0.element) }
        if !pinned.isEmpty { sections.append(DaySection(id: "pinned", title: "Pinned", items: pinned)) }
        var currentKey: String?
        var bucket: [(Int, ClipItem)] = []
        var currentTitle = ""
        for (index, item) in items.enumerated() where !item.isPinned {
            let day = calendar.startOfDay(for: item.lastCopiedAt)
            let key = String(day.timeIntervalSince1970)
            if key != currentKey {
                if let currentKey { sections.append(DaySection(id: currentKey, title: currentTitle, items: bucket)) }
                currentKey = key
                currentTitle = dayTitle(day, now: now, calendar: calendar)
                bucket = []
            }
            bucket.append((index, item))
        }
        if let currentKey { sections.append(DaySection(id: currentKey, title: currentTitle, items: bucket)) }
        return sections
    }

    static func dayTitle(_ day: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: day, to: calendar.startOfDay(for: now)).day ?? 0
        if days < 7 { return day.formatted(.dateTime.weekday(.wide)) }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}
