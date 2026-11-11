import Foundation

/// Decides what is read from the pasteboard and whether a copy is saved at all.
public struct CaptureRules: Sendable {
    /// A single representation larger than this is dropped (a 50 MB TIFF is not worth keeping).
    public var maxRepresentationBytes: Int
    public var ignoredBundleIDs: Set<String>

    public init(maxRepresentationBytes: Int = 50 * 1024 * 1024, ignoredBundleIDs: Set<String> = []) {
        self.maxRepresentationBytes = maxRepresentationBytes
        self.ignoredBundleIDs = ignoredBundleIDs.union(DefaultIgnoredApps.bundleIDs)
    }

    /// Checked against the type list alone, before any data is read.
    public func shouldIgnore(types: [String], source: SourceApp?) -> Bool {
        if types.contains(where: PasteboardType.sensitive.contains) { return true }
        if let id = source?.bundleID, ignoredBundleIDs.contains(id) { return true }
        return false
    }

    /// The types worth reading from one pasteboard item, in a stable order.
    public func typesToRead(from available: [String]) -> [String] {
        PasteboardType.kept.filter(available.contains)
    }

    /// Adds a plain text version to items that only carry rich text (some apps copy RTF or
    /// HTML alone), so they can be listed, searched and pasted as plain text.
    /// `extract` turns rich text data of the given type into plain text.
    public func addingPlainText(to snapshot: ClipSnapshot, extract: (String, Data) -> String?) -> ClipSnapshot {
        ClipSnapshot(items: snapshot.items.map { item in
            guard !item.contains(where: { $0.type == PasteboardType.plainText }) else { return item }
            for type in [PasteboardType.rtf, PasteboardType.rtfd, PasteboardType.html] {
                if let rep = item.first(where: { $0.type == type }), let text = extract(type, rep.data),
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return item + [ClipRepresentation(type: PasteboardType.plainText, data: Data(text.utf8))]
                }
            }
            return item
        })
    }

    /// Drops oversized representations and empty items.
    public func trim(_ snapshot: ClipSnapshot) -> ClipSnapshot {
        let items = snapshot.items
            .map { $0.filter { !$0.data.isEmpty && $0.data.count <= maxRepresentationBytes } }
            .filter { !$0.isEmpty }
        return ClipSnapshot(items: items)
    }
}
