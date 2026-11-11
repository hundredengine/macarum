import Foundation

/// What a history entry holds, decided once when it is captured.
public enum ClipKind: String, Sendable, CaseIterable, Codable {
    case text
    case link
    case color
    case image
    case file
}

/// Filters shown in the history panel. Each maps to one or more kinds.
public enum ClipFilter: String, Sendable, CaseIterable {
    case all
    case text
    case links
    case images
    case files

    public var kinds: Set<ClipKind>? {
        switch self {
        case .all: nil
        case .text: [.text, .color]
        case .links: [.link]
        case .images: [.image]
        case .files: [.file]
        }
    }
}

/// One pasteboard type with its raw bytes.
public struct ClipRepresentation: Sendable, Hashable {
    public let type: String
    public let data: Data

    public init(type: String, data: Data) {
        self.type = type
        self.data = data
    }
}

/// Everything read from the pasteboard for one copy: one array per pasteboard item
/// (copying three files in Finder gives three items).
public struct ClipSnapshot: Sendable, Hashable {
    public var items: [[ClipRepresentation]]

    public init(items: [[ClipRepresentation]]) {
        self.items = items
    }

    public var byteSize: Int {
        items.reduce(0) { $0 + $1.reduce(0) { $0 + $1.data.count } }
    }

    public func first(_ type: String) -> Data? {
        for item in items {
            if let rep = item.first(where: { $0.type == type }) { return rep.data }
        }
        return nil
    }

    public func all(_ type: String) -> [Data] {
        items.compactMap { item in item.first(where: { $0.type == type })?.data }
    }
}

/// The app that was in front when something was copied.
public struct SourceApp: Sendable, Hashable {
    public let bundleID: String?
    public let name: String?

    public init(bundleID: String?, name: String?) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// A history row as the UI sees it. Raw data stays in the store until needed.
public struct ClipItem: Identifiable, Sendable, Hashable {
    public let id: Int64
    public let kind: ClipKind
    /// Short display text: first line(s) of text, the URL, the hex code, or file names.
    public let title: String
    public let source: SourceApp
    public let firstCopiedAt: Date
    public let lastCopiedAt: Date
    public let copyCount: Int
    public let byteSize: Int
    public let imageWidth: Int?
    public let imageHeight: Int?
    public let fileCount: Int
    /// Small PNG made at capture time for image rows.
    public let thumbnail: Data?
    /// Pinned items are never removed by the retention period, the size limit or Clear All.
    public let isPinned: Bool

    public init(
        id: Int64, kind: ClipKind, title: String, source: SourceApp,
        firstCopiedAt: Date, lastCopiedAt: Date, copyCount: Int, byteSize: Int,
        imageWidth: Int?, imageHeight: Int?, fileCount: Int, thumbnail: Data?, isPinned: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.source = source
        self.firstCopiedAt = firstCopiedAt
        self.lastCopiedAt = lastCopiedAt
        self.copyCount = copyCount
        self.byteSize = byteSize
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.fileCount = fileCount
        self.thumbnail = thumbnail
        self.isPinned = isPinned
    }
}
