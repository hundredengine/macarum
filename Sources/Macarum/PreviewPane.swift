import AppKit
import MacarumCore
import QuickLookThumbnailing
import SwiftUI

/// Icons for apps and files, looked up once and kept small in memory.
@MainActor
enum IconCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 200
        return c
    }()

    static func app(_ bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        let key = "app:" + bundleID as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(icon, forKey: key)
        return icon
    }

    static func file(_ url: URL) -> NSImage {
        let key = "file:" + url.path as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(icon, forKey: key)
        return icon
    }
}

struct PreviewPane: View {
    @Bindable var model: HistoryModel

    var body: some View {
        if model.isMultiSelected {
            MultiSelectionSummary(model: model)
        } else {
            single
        }
    }

    private var single: some View {
        VStack(spacing: 0) {
            if let item = model.selectedItem {
                ActionBar(model: model, item: item)
                Divider()
            }
            Group {
                if model.isEditing {
                    TextEditorPane(text: $model.editDraft)
                } else {
                    content
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let item = model.selectedItem, !model.isEditing {
                Divider()
                MetadataView(item: item, content: model.preview)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.preview {
        case .text(let text, _, _, let looksLikeCode):
            TextPreview(text: text, monospaced: looksLikeCode)
        case .link(let url):
            LinkPreview(url: url)
        case .color(let hex, let color):
            ColorPreview(hex: hex, color: color)
        case .image(let image):
            ImagePreview(image: image)
        case .files(let urls) where urls.count == 1:
            SingleFilePreview(url: urls[0])
        case .files(let urls):
            FilesPreview(urls: urls)
        case .unavailable:
            Text("This item can no longer be shown.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case nil:
            Color.clear
        }
    }
}

/// Copy, Edit and Delete for the selected item; Cancel and Save while editing.
private struct ActionBar: View {
    let model: HistoryModel
    let item: ClipItem

    var body: some View {
        HStack(spacing: 6) {
            if model.isEditing {
                Text("Editing")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.cancelEditing() }
                    .help("Discard the changes (esc)")
                Button("Save") { model.saveEditing() }
                    .buttonStyle(.borderedProminent)
                    .help("Save the edited text (⌘↩)")
            } else {
                Spacer()
                Button { model.togglePin(item) } label: {
                    Label(item.isPinned ? "Unpin" : "Pin", systemImage: item.isPinned ? "pin.slash" : "pin")
                }
                .help(item.isPinned ? "Let this item expire like the rest (⌘P)"
                                    : "Keep this item: it is never deleted automatically (⌘P)")
                Button { model.choose(item, mode: .copy) } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .help("Copy to the clipboard without pasting (⌘↩)")
                if model.canEditSelected {
                    Button { model.startEditing() } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .help("Edit the text before using it (⌘E)")
                }
                Button(role: .destructive) { model.deleteSelected() } label: {
                    Label("Delete", systemImage: "trash")
                }
                .help("Delete this item from the history (⌘⌫)")
            }
        }
        .controlSize(.small)
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .frame(height: 40)
    }
}

/// Several rows selected: how many, and what can be done to all of them at once.
private struct MultiSelectionSummary: View {
    let model: HistoryModel

    var body: some View {
        let items = model.selectedItems
        let allPinned = model.selectionIsAllPinned
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Spacer()
                Button { model.togglePinSelected() } label: {
                    Label(allPinned ? "Unpin" : "Pin", systemImage: allPinned ? "pin.slash" : "pin")
                }
                .help(allPinned ? "Let these items expire like the rest (⌘P)"
                                : "Keep these items: they are never deleted automatically (⌘P)")
                Button(role: .destructive) { model.deleteSelected() } label: {
                    Label("Delete", systemImage: "trash")
                }
                .help("Delete these items from the history (⌘⌫)")
            }
            .controlSize(.small)
            .font(.system(size: 12))
            .padding(.horizontal, 14)
            .frame(height: 40)
            Divider()
            VStack(spacing: 10) {
                Image(systemName: "square.on.square")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("\(items.count.formatted()) items selected")
                    .font(.system(size: 15, weight: .semibold))
                let pinned = items.filter(\.isPinned).count
                if pinned > 0 {
                    Text(pinned == items.count ? "All pinned" : "\(pinned.formatted()) pinned")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct TextEditorPane: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .focused($focused)
            .onAppear { focused = true }
    }
}

private struct TextPreview: View {
    let text: String
    let monospaced: Bool

    var body: some View {
        ScrollView {
            Text(text)
                .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 13))
                .lineSpacing(monospaced ? 2 : 3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(18)
        }
    }
}

private struct LinkPreview: View {
    let url: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(url.host(percentEncoded: false) ?? url.absoluteString)
                .font(.system(size: 20, weight: .semibold))
                .lineLimit(2)
            Text(url.absoluteString)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(8)
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Label("Open in Browser", systemImage: "arrow.up.right.square")
            }
            .controlSize(.small)
            .padding(.top, 6)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
    }
}

private struct ColorPreview: View {
    let hex: String
    let color: NSColor

    var body: some View {
        VStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: color))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.primary.opacity(0.12)))
                .frame(width: 140, height: 140)
            Text(hex.uppercased())
                .font(.system(size: 17, weight: .semibold).monospaced())
                .textSelection(.enabled)
            Text(rgb)
                .font(.system(size: 12).monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var rgb: String {
        let c = color.usingColorSpace(.sRGB) ?? color
        let r = Int((c.redComponent * 255).rounded()), g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return c.alphaComponent < 1
            ? "rgba(\(r), \(g), \(b), \(String(format: "%.2f", c.alphaComponent)))"
            : "rgb(\(r), \(g), \(b))"
    }
}

private struct ImagePreview: View {
    let image: NSImage

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: min(image.size.width, .infinity), maxHeight: min(image.size.height, .infinity))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One file: a Quick Look thumbnail (falls back to the Finder icon), its name and place.
private struct SingleFilePreview: View {
    let url: URL
    @State private var thumbnail: NSImage?

    var body: some View {
        let exists = FileManager.default.fileExists(atPath: url.path)
        VStack(spacing: 12) {
            Image(nsImage: thumbnail ?? IconCache.file(url))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 220, maxHeight: 180)
                .shadow(color: .black.opacity(thumbnail == nil ? 0 : 0.15), radius: 3, y: 1)
                .opacity(exists ? 1 : 0.4)
            VStack(spacing: 3) {
                Text(url.lastPathComponent)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(exists ? url.deletingLastPathComponent().path(percentEncoded: false) : "Moved or deleted")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if exists {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .controlSize(.small)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            thumbnail = nil
            guard exists else { return }
            let request = QLThumbnailGenerator.Request(
                fileAt: url, size: CGSize(width: 220, height: 180), scale: 2, representationTypes: .thumbnail)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                thumbnail = rep.nsImage
            }
        }
    }
}

private struct FilesPreview: View {
    let urls: [URL]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(urls, id: \.self) { url in
                    let exists = FileManager.default.fileExists(atPath: url.path)
                    HStack(spacing: 10) {
                        Image(nsImage: IconCache.file(url))
                            .resizable()
                            .frame(width: 32, height: 32)
                            .opacity(exists ? 1 : 0.4)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(url.lastPathComponent)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            Text(exists ? url.deletingLastPathComponent().path(percentEncoded: false) : "Moved or deleted")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        if exists {
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            } label: {
                                Image(systemName: "magnifyingglass")
                            }
                            .buttonStyle(.borderless)
                            .help("Show in Finder")
                        }
                    }
                    .padding(.vertical, 5)
                }
            }
            .padding(18)
        }
    }
}

private struct MetadataView: View {
    let item: ClipItem
    let content: PreviewContent?

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
            GridRow {
                label("Source")
                HStack(spacing: 5) {
                    if let icon = IconCache.app(item.source.bundleID) {
                        Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                    }
                    Text(item.source.name ?? "Unknown")
                }
            }
            GridRow {
                label("Copied")
                Text(copiedText)
            }
            if let detail {
                GridRow {
                    label("Content")
                    Text(detail)
                }
            }
        }
        .font(.system(size: 11))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    private var copiedText: String {
        let when = item.lastCopiedAt.formatted(date: .abbreviated, time: .shortened)
        return item.copyCount > 1 ? "\(when) · \(item.copyCount) times" : when
    }

    private var detail: String? {
        let size = ByteCountFormatter.string(fromByteCount: Int64(item.byteSize), countStyle: .file)
        switch content {
        case .text(_, let lines, let chars, _):
            let l = lines == 1 ? "1 line" : "\(lines.formatted()) lines"
            return "\(chars.formatted()) characters · \(l) · \(size)"
        case .image:
            if let w = item.imageWidth, let h = item.imageHeight { return "\(w) × \(h) pixels · \(size)" }
            return size
        case .files(let urls):
            return urls.count == 1 ? "1 file" : "\(urls.count) files"
        default:
            return nil
        }
    }
}
