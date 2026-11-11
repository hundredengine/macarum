import AppKit
import MacarumCore
import SwiftUI

/// Layout constants for the history panel, in one place.
enum PanelMetrics {
    static let size = CGSize(width: 800, height: 500)
    static let cornerRadius: CGFloat = 22
    static let listWidth: CGFloat = 330
    static let rowHeight: CGFloat = 36
    static let rowRadius: CGFloat = 8
    static let badgeSize: CGFloat = 24
}

struct HistoryView: View {
    @Bindable var model: HistoryModel
    let preferences: Preferences
    let accessDenied: Bool
    let openSettings: () -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            if preferences.isPaused {
                Banner(symbol: "pause.circle.fill", text: "History is paused. New copies are not saved.",
                       action: "Resume") { preferences.isPaused = false }
            } else if accessDenied {
                Banner(symbol: "exclamationmark.triangle.fill",
                       text: "macOS is blocking Macarum from reading the clipboard.",
                       action: "Open Settings", perform: openSettings)
            }
            Divider()
            content
            Divider()
            FooterBar(model: model)
        }
        .frame(width: PanelMetrics.size.width, height: PanelMetrics.size.height)
        .onChange(of: model.focusToken, initial: true) { searchFocused = true }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search clipboard history", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 19))
                .focused($searchFocused)
                .disabled(model.isEditing)
            FilterMenu(filter: $model.filter)
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
    }

    @ViewBuilder
    private var content: some View {
        if !model.hasLoaded {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.items.isEmpty {
            EmptyState(query: model.query, filter: model.filter, openHint: preferences.openHint)
        } else {
            HStack(spacing: 0) {
                HistoryList(model: model)
                    .frame(width: PanelMetrics.listWidth)
                    // While an item is edited the list waits, so the edit is never lost by a stray click.
                    .opacity(model.isEditing ? 0.45 : 1)
                    .allowsHitTesting(!model.isEditing)
                Divider()
                PreviewPane(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Search bar pieces

private struct FilterMenu: View {
    @Binding var filter: ClipFilter

    var body: some View {
        Menu {
            Picker("Show", selection: $filter) {
                ForEach(ClipFilter.allCases, id: \.self) { f in
                    Label(f.title, systemImage: f.symbol).tag(f)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(filter.title)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .help("Filter by type (Tab)")
    }
}

extension ClipFilter {
    var title: String {
        switch self {
        case .all: "All Types"
        case .text: "Text"
        case .links: "Links"
        case .images: "Images"
        case .files: "Files"
        }
    }

    var symbol: String {
        switch self {
        case .all: "square.stack"
        case .text: "text.alignleft"
        case .links: "link"
        case .images: "photo"
        case .files: "doc"
        }
    }
}

private struct Banner: View {
    let symbol: String
    let text: String
    let action: String
    let perform: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.orange)
            Text(text).font(.system(size: 12))
            Spacer()
            Button(action, action: perform).controlSize(.small)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.08))
    }
}

// MARK: - List

private struct HistoryList: View {
    @Bindable var model: HistoryModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                    ForEach(model.sections) { section in
                        Section {
                            ForEach(section.items, id: \.item.id) { entry in
                                HistoryRow(item: entry.item, index: entry.index,
                                           isSelected: model.isSelected(entry.item.id))
                                    .id(entry.item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) { model.choose(index: entry.index, mode: .paste) }
                                    .onTapGesture { model.click(entry.item.id, modifiers: NSEvent.modifierFlags) }
                            }
                        } header: {
                            SectionHeader(title: section.title)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.automatic)
            .onChange(of: model.scrollToken) {
                guard let id = model.selectedID else { return }
                proxy.scrollTo(id, anchor: nil)
            }
        }
    }
}

private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar.opacity(0.001)) // keeps the pinned header hit-testable without a visible slab
    }
}

private struct HistoryRow: View {
    let item: ClipItem
    let index: Int
    let isSelected: Bool

    private var onAccent: Bool { isSelected }

    var body: some View {
        HStack(spacing: 10) {
            KindBadge(item: item, isSelected: onAccent)
            Text(item.title)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(onAccent ? Color.white : Color.primary)
            Spacer(minLength: 4)
            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(onAccent ? Color.white.opacity(0.75) : Color.secondary.opacity(0.6))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: PanelMetrics.rowHeight)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: PanelMetrics.rowRadius, style: .continuous)
                    .fill(Color(nsColor: .selectedContentBackgroundColor))
            }
        }
    }
}

/// The small square at the start of a row: a thumbnail, a colour swatch, a file icon or a symbol.
private struct KindBadge: View {
    let item: ClipItem
    let isSelected: Bool

    var body: some View {
        Group {
            switch item.kind {
            case .image:
                if let data = item.thumbnail, let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    symbol("photo")
                }
            case .color:
                if let c = ClipClassifier.hexColorComponents(item.title) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.primary.opacity(0.15)))
                        .padding(3)
                } else {
                    symbol("paintpalette")
                }
            case .file:
                symbol(item.fileCount > 1 ? "doc.on.doc" : "doc")
            case .link:
                symbol("link")
            case .text:
                symbol("text.alignleft")
            }
        }
        .frame(width: PanelMetrics.badgeSize, height: PanelMetrics.badgeSize)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isSelected ? Color.white : Color.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.18) : Color.primary.opacity(0.06))
            )
    }
}

// MARK: - Footer and empty state

private struct FooterBar: View {
    let model: HistoryModel

    var body: some View {
        HStack(spacing: 14) {
            if model.isConfirmingClearAll {
                Image(systemName: "trash").foregroundStyle(.red)
                Text(model.totalCount > model.unpinnedCount
                     ? "Delete \(model.unpinnedCount.formatted()) items? Pinned items stay. This cannot be undone."
                     : "Delete all \(model.unpinnedCount.formatted()) items? This cannot be undone.")
                Spacer()
                Button("Cancel") { model.cancelClearAll() }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) { model.clearAll() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            } else {
                if let pending = model.pendingUndo {
                    // The undo toast: shown for a few seconds after a delete.
                    Image(systemName: "trash").foregroundStyle(.secondary)
                    Text(pending.count == 1 ? "Deleted 1 item" : "Deleted \(pending.count.formatted()) items")
                    Button("Undo") { model.undoDelete() }
                        .controlSize(.small)
                        .help("Bring the deleted items back (⌘Z)")
                    KeyHint(keys: "⌘Z", label: "")
                } else {
                    Text(model.totalCount == 1 ? "1 item" : "\(model.totalCount.formatted()) items")
                        .foregroundStyle(.secondary)
                }
                if model.unpinnedCount > 0, !model.isEditing, model.pendingUndo == nil {
                    Button("Clear All…") { model.askToClearAll() }
                        .buttonStyle(.link)
                        .foregroundStyle(.secondary)
                        .help("Delete the whole history (⇧⌘⌫)")
                }
                Spacer()
                if model.isEditing {
                    KeyHint(keys: "⌘↩", label: "Save")
                    KeyHint(keys: "esc", label: "Cancel")
                } else if model.isMultiSelected {
                    KeyHint(keys: "⌘⌫", label: "Delete")
                } else if model.selectedItem != nil {
                    KeyHint(keys: "↩", label: "Paste")
                    if model.selectedItem?.kind != .image { KeyHint(keys: "⌥↩", label: "Plain text") }
                    KeyHint(keys: "⌘⌫", label: "Delete")
                }
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 18)
        .frame(height: 32)
        .background(model.isConfirmingClearAll ? Color.red.opacity(0.08) : Color.clear)
    }
}

private struct KeyHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Text(keys)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(.primary.opacity(0.08)))
            if !label.isEmpty { Text(label).foregroundStyle(.secondary) }
        }
    }
}

private struct EmptyState: View {
    let query: String
    let filter: ClipFilter
    let openHint: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: query.isEmpty && filter == .all ? "list.clipboard" : "magnifyingglass")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        if !query.isEmpty { return "No results for “\(query)”" }
        if filter != .all { return "No \(filter.title.lowercased()) yet" }
        return "Nothing copied yet"
    }

    private var detail: String {
        if !query.isEmpty { return "Try fewer words, or look in All Types." }
        if filter != .all { return "Press Tab to see other types." }
        return "Copy text, images or files as usual. They show up here. Open this again anytime by \(openHint)."
    }
}
