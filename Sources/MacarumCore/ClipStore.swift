import CryptoKit
import Foundation

public enum InsertResult: Sendable, Equatable {
    case inserted(Int64)
    /// The same content was already saved; it moved to the top instead.
    case bumped(Int64)
    case skipped
}

public struct StoreStats: Sendable, Equatable {
    public let itemCount: Int
    public let byteSize: Int
    public let pinnedCount: Int

    public init(itemCount: Int, byteSize: Int, pinnedCount: Int = 0) {
        self.itemCount = itemCount
        self.byteSize = byteSize
        self.pinnedCount = pinnedCount
    }
}

/// The clipboard history on disk: one SQLite file plus a folder for large blobs.
/// Lives in an actor so hashing, image thumbnails and disk writes stay off the main thread.
public actor ClipStore {
    /// Representations bigger than this go to their own file instead of the database.
    static let inlineLimit = 256 * 1024

    private let db: SQLiteDatabase
    private let blobDirectory: URL

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        blobDirectory = directory.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: blobDirectory, withIntermediateDirectories: true)
        db = try SQLiteDatabase(path: directory.appendingPathComponent("history.sqlite").path)
        try db.execute("""
            PRAGMA journal_mode = WAL;
            PRAGMA foreign_keys = ON;
            PRAGMA synchronous = NORMAL;
            CREATE TABLE IF NOT EXISTS items (
                id INTEGER PRIMARY KEY,
                hash TEXT NOT NULL UNIQUE,
                kind TEXT NOT NULL,
                title TEXT NOT NULL,
                search TEXT NOT NULL,
                source_bundle TEXT,
                source_name TEXT,
                first_at REAL NOT NULL,
                last_at REAL NOT NULL,
                copy_count INTEGER NOT NULL DEFAULT 1,
                byte_size INTEGER NOT NULL,
                img_w INTEGER,
                img_h INTEGER,
                file_count INTEGER NOT NULL DEFAULT 0,
                thumb BLOB
            );
            CREATE INDEX IF NOT EXISTS items_last ON items(last_at DESC);
            CREATE TABLE IF NOT EXISTS reps (
                item_id INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
                item_index INTEGER NOT NULL,
                position INTEGER NOT NULL,
                type TEXT NOT NULL,
                data BLOB,
                file TEXT
            );
            CREATE INDEX IF NOT EXISTS reps_item ON reps(item_id);
            """)
        // Added after 0.1.0 build 6 (pinned) and build 13 (trash_batch); older files get them here.
        var columns: Set<String> = []
        try db.prepare("PRAGMA table_info(items)").rows { if let name = $0.text(1) { columns.insert(name) } }
        if !columns.contains("pinned") { try db.execute("ALTER TABLE items ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0") }
        if !columns.contains("trash_batch") { try db.execute("ALTER TABLE items ADD COLUMN trash_batch INTEGER") }
        // Deletes whose undo window was cut short by a quit or crash are finished now.
        try Self.emptyTrash(nil, db: db, blobDirectory: blobDirectory)
    }

    // MARK: Writing

    /// Saves a copy, or moves an identical earlier copy to the top.
    @discardableResult
    public func insert(_ snapshot: ClipSnapshot, source: SourceApp?, at now: Date = Date()) throws -> InsertResult {
        guard let summary = ClipClassifier.summarize(snapshot) else { return .skipped }
        let hash = Self.contentHash(snapshot, kind: summary.kind)
        let search = summary.searchText + "\n" + ClipClassifier.fold(source?.name ?? "")

        var newFiles: [String] = []
        do {
            let result: InsertResult = try db.transaction {
                var existing: Int64?
                try db.prepare("SELECT id FROM items WHERE hash = ?").rows([.text(hash)]) { existing = $0.int(0) }

                let itemID: Int64
                if let existing {
                    try db.prepare("""
                        UPDATE items SET last_at = ?, copy_count = copy_count + 1, source_bundle = ?,
                            source_name = ?, search = ?, byte_size = ?, trash_batch = NULL WHERE id = ?
                        """).run([
                        .double(now.timeIntervalSince1970), Self.text(source?.bundleID), Self.text(source?.name),
                        .text(search), .int(Int64(snapshot.byteSize)), .int(existing),
                    ])
                    try removeRepresentations(of: [existing])
                    itemID = existing
                } else {
                    try db.prepare("""
                        INSERT INTO items (hash, kind, title, search, source_bundle, source_name, first_at, last_at,
                            byte_size, img_w, img_h, file_count, thumb)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """).run([
                        .text(hash), .text(summary.kind.rawValue), .text(summary.title), .text(search),
                        Self.text(source?.bundleID), Self.text(source?.name),
                        .double(now.timeIntervalSince1970), .double(now.timeIntervalSince1970),
                        .int(Int64(snapshot.byteSize)),
                        summary.imageWidth.map { .int(Int64($0)) } ?? .null,
                        summary.imageHeight.map { .int(Int64($0)) } ?? .null,
                        .int(Int64(summary.fileCount)),
                        summary.thumbnail.map { .blob($0) } ?? .null,
                    ])
                    itemID = db.lastInsertRowID
                }

                try writeRepresentations(of: snapshot, to: itemID, newFiles: &newFiles)
                return existing == nil ? .inserted(itemID) : .bumped(itemID)
            }
            return result
        } catch {
            for name in newFiles { try? FileManager.default.removeItem(at: blobDirectory.appendingPathComponent(name)) }
            throw error
        }
    }

    /// Replaces an item's content with edited text and moves it to the top. Rich formats are
    /// dropped, since they no longer match the text. If the edit makes it equal to another
    /// item, that other item is removed so the history keeps one copy.
    public func replaceText(of id: Int64, with text: String, at now: Date = Date()) throws {
        let snapshot = ClipSnapshot(items: [[ClipRepresentation(type: PasteboardType.plainText, data: Data(text.utf8))]])
        guard let summary = ClipClassifier.summarize(snapshot) else { return }
        let hash = Self.contentHash(snapshot, kind: summary.kind)
        var newFiles: [String] = []
        do {
            try db.transaction {
                var sourceName: String?
                try db.prepare("SELECT source_name FROM items WHERE id = ?").rows([.int(id)]) { sourceName = $0.text(0) }
                var duplicates: [Int64] = []
                try db.prepare("SELECT id FROM items WHERE hash = ? AND id != ?").rows([.text(hash), .int(id)]) {
                    duplicates.append($0.int(0))
                }
                var keepPin = false
                if !duplicates.isEmpty {
                    let marks = duplicates.map { _ in "?" }.joined(separator: ",")
                    try db.prepare("SELECT 1 FROM items WHERE pinned = 1 AND trash_batch IS NULL AND id IN (\(marks))")
                        .rows(duplicates.map { .int($0) }) { _ in keepPin = true }
                }
                if keepPin { try db.prepare("UPDATE items SET pinned = 1 WHERE id = ?").run([.int(id)]) }
                try removeRepresentations(of: duplicates)
                for duplicate in duplicates {
                    try db.prepare("DELETE FROM items WHERE id = ?").run([.int(duplicate)])
                }
                try db.prepare("""
                    UPDATE items SET hash = ?, kind = ?, title = ?, search = ?, last_at = ?, byte_size = ?,
                        img_w = NULL, img_h = NULL, file_count = 0, thumb = NULL WHERE id = ?
                    """).run([
                    .text(hash), .text(summary.kind.rawValue), .text(summary.title),
                    .text(summary.searchText + "\n" + ClipClassifier.fold(sourceName ?? "")),
                    .double(now.timeIntervalSince1970), .int(Int64(snapshot.byteSize)), .int(id),
                ])
                try removeRepresentations(of: [id])
                try writeRepresentations(of: snapshot, to: id, newFiles: &newFiles)
            }
        } catch {
            for name in newFiles { try? FileManager.default.removeItem(at: blobDirectory.appendingPathComponent(name)) }
            throw error
        }
    }

    /// Moves an item to the top after it was pasted from the history.
    public func markUsed(_ id: Int64, at now: Date = Date()) throws {
        try db.prepare("UPDATE items SET last_at = ?, copy_count = copy_count + 1 WHERE id = ?")
            .run([.double(now.timeIntervalSince1970), .int(id)])
    }

    public func delete(_ id: Int64) throws {
        try db.transaction {
            try removeRepresentations(of: [id])
            try db.prepare("DELETE FROM items WHERE id = ?").run([.int(id)])
        }
    }

    public func setPinned(_ id: Int64, _ pinned: Bool) throws {
        try setPinned([id], pinned)
    }

    public func setPinned(_ ids: [Int64], _ pinned: Bool) throws {
        guard !ids.isEmpty else { return }
        let marks = ids.map { _ in "?" }.joined(separator: ",")
        try db.prepare("UPDATE items SET pinned = ? WHERE id IN (\(marks))").run([.int(pinned ? 1 : 0)] + ids.map { .int($0) })
    }

    // MARK: Delete with undo

    /// Hides items as one undoable delete. Nothing leaves the disk until `emptyTrash`, so
    /// `restore` brings back the exact items: content, blobs, pin, timestamps and so their
    /// place in the list. Pass `into` to add to a delete that can still be undone.
    @discardableResult
    public func trash(_ ids: [Int64], into batch: Int64? = nil) throws -> Int64 {
        var target = batch ?? 0
        try db.transaction {
            if batch == nil {
                try db.prepare("SELECT COALESCE(MAX(trash_batch), 0) + 1 FROM items").rows { target = $0.int(0) }
            }
            for chunk in Self.chunks(ids) {
                let marks = chunk.map { _ in "?" }.joined(separator: ",")
                try db.prepare("UPDATE items SET trash_batch = ? WHERE trash_batch IS NULL AND id IN (\(marks))")
                    .run([.int(target)] + chunk.map { .int($0) })
            }
        }
        return target
    }

    /// Undo: shows a trashed batch again. Returns the ids that came back.
    @discardableResult
    public func restore(_ batch: Int64) throws -> [Int64] {
        var ids: [Int64] = []
        try db.transaction {
            try db.prepare("SELECT id FROM items WHERE trash_batch = ?").rows([.int(batch)]) { ids.append($0.int(0)) }
            try db.prepare("UPDATE items SET trash_batch = NULL WHERE trash_batch = ?").run([.int(batch)])
        }
        return ids
    }

    /// How many items a batch still holds.
    public func trashedCount(_ batch: Int64) throws -> Int {
        var count = 0
        try db.prepare("SELECT COUNT(*) FROM items WHERE trash_batch = ?").rows([.int(batch)]) { count = Int($0.int(0)) }
        return count
    }

    /// Deletes trashed items for real, with their blob files: one batch, or all when nil.
    @discardableResult
    public func emptyTrash(_ batch: Int64? = nil) throws -> Int {
        try Self.emptyTrash(batch, db: db, blobDirectory: blobDirectory)
    }

    @discardableResult
    private static func emptyTrash(_ batch: Int64?, db: SQLiteDatabase, blobDirectory: URL) throws -> Int {
        var ids: [Int64] = []
        if let batch {
            try db.prepare("SELECT id FROM items WHERE trash_batch = ?").rows([.int(batch)]) { ids.append($0.int(0)) }
        } else {
            try db.prepare("SELECT id FROM items WHERE trash_batch IS NOT NULL").rows { ids.append($0.int(0)) }
        }
        try deleteItems(ids, db: db, blobDirectory: blobDirectory)
        return ids.count
    }

    /// Empties the history except pinned items. Items waiting in the trash for undo stay there.
    public func deleteAll() throws {
        try db.transaction {
            try db.execute("""
                DELETE FROM reps WHERE item_id IN (SELECT id FROM items WHERE pinned = 0 AND trash_batch IS NULL);
                DELETE FROM items WHERE pinned = 0 AND trash_batch IS NULL;
                """)
        }
        try removeOrphanBlobs()
        try? db.execute("PRAGMA wal_checkpoint(TRUNCATE); VACUUM;")
    }

    /// Deletes everything not pinned and last copied before `date`. Returns how many items went.
    @discardableResult
    public func purge(lastCopiedBefore date: Date) throws -> Int {
        var ids: [Int64] = []
        try db.prepare("SELECT id FROM items WHERE last_at < ? AND pinned = 0 AND trash_batch IS NULL").rows([.double(date.timeIntervalSince1970)]) {
            ids.append($0.int(0))
        }
        try deleteItems(ids)
        return ids.count
    }

    /// Deletes the oldest unpinned items until the history fits in `maxBytes`. Pinned items
    /// count toward the size but are never removed.
    @discardableResult
    public func enforceSizeLimit(_ maxBytes: Int) throws -> Int {
        var total = 0
        var ids: [Int64] = []
        try db.prepare("SELECT id, byte_size, pinned FROM items WHERE trash_batch IS NULL ORDER BY pinned DESC, last_at DESC").rows { row in
            total += Int(row.int(1))
            if total > maxBytes, row.int(2) == 0 { ids.append(row.int(0)) }
        }
        try deleteItems(ids)
        return ids.count
    }

    // MARK: Reading

    /// Pinned items first, then newest first. Every word in `query` must appear (in any order); case and accents are ignored.
    public func items(matching query: String = "", filter: ClipFilter = .all, limit: Int = 1000) throws -> [ClipItem] {
        var conditions = ["trash_batch IS NULL"]
        var values: [Statement.Value] = []
        for word in ClipClassifier.fold(query).split(whereSeparator: \.isWhitespace) {
            conditions.append("search LIKE ? ESCAPE '\\'")
            values.append(.text("%" + Self.escapeLike(String(word)) + "%"))
        }
        if let kinds = filter.kinds {
            conditions.append("kind IN (" + kinds.map { _ in "?" }.joined(separator: ",") + ")")
            values.append(contentsOf: kinds.sorted { $0.rawValue < $1.rawValue }.map { .text($0.rawValue) })
        }
        let whereClause = "WHERE " + conditions.joined(separator: " AND ")
        values.append(.int(Int64(limit)))

        var result: [ClipItem] = []
        try db.prepare("""
            SELECT id, kind, title, source_bundle, source_name, first_at, last_at, copy_count, byte_size,
                img_w, img_h, file_count, thumb, pinned
            FROM items \(whereClause) ORDER BY pinned DESC, last_at DESC LIMIT ?
            """).rows(values) { row in
            result.append(ClipItem(
                id: row.int(0),
                kind: ClipKind(rawValue: row.text(1) ?? "") ?? .text,
                title: row.text(2) ?? "",
                source: SourceApp(bundleID: row.text(3), name: row.text(4)),
                firstCopiedAt: Date(timeIntervalSince1970: row.double(5)),
                lastCopiedAt: Date(timeIntervalSince1970: row.double(6)),
                copyCount: Int(row.int(7)),
                byteSize: Int(row.int(8)),
                imageWidth: row.isNull(9) ? nil : Int(row.int(9)),
                imageHeight: row.isNull(10) ? nil : Int(row.int(10)),
                fileCount: Int(row.int(11)),
                thumbnail: row.blob(12),
                isPinned: row.int(13) != 0
            ))
        }
        return result
    }

    /// The saved pasteboard content of one item, ready to write back.
    public func snapshot(for id: Int64) throws -> ClipSnapshot {
        var grouped: [Int: [ClipRepresentation]] = [:]
        try db.prepare("SELECT item_index, type, data, file FROM reps WHERE item_id = ? ORDER BY item_index, position")
            .rows([.int(id)]) { row in
                let data: Data
                if let file = row.text(3) {
                    data = (try? Data(contentsOf: blobDirectory.appendingPathComponent(file), options: .mappedIfSafe)) ?? Data()
                } else {
                    data = row.blob(2) ?? Data()
                }
                grouped[Int(row.int(0)), default: []].append(ClipRepresentation(type: row.text(1) ?? "", data: data))
            }
        return ClipSnapshot(items: grouped.keys.sorted().compactMap { grouped[$0] })
    }

    public func stats() throws -> StoreStats {
        var stats = StoreStats(itemCount: 0, byteSize: 0)
        try db.prepare("SELECT COUNT(*), COALESCE(SUM(byte_size), 0), COALESCE(SUM(pinned), 0) FROM items WHERE trash_batch IS NULL").rows { row in
            stats = StoreStats(itemCount: Int(row.int(0)), byteSize: Int(row.int(1)), pinnedCount: Int(row.int(2)))
        }
        return stats
    }

    /// Blob files no row points to (left by a crash mid-write). Removed at launch.
    @discardableResult
    public func removeOrphanBlobs() throws -> Int {
        var referenced: Set<String> = []
        try db.prepare("SELECT file FROM reps WHERE file IS NOT NULL").rows { if let f = $0.text(0) { referenced.insert(f) } }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: blobDirectory.path)) ?? []
        var removed = 0
        for name in names where !referenced.contains(name) {
            try? FileManager.default.removeItem(at: blobDirectory.appendingPathComponent(name))
            removed += 1
        }
        return removed
    }

    // MARK: Helpers

    /// Large representations go to blob files (listed in `newFiles` so a failed transaction
    /// can remove them), small ones stay inline.
    private func writeRepresentations(of snapshot: ClipSnapshot, to itemID: Int64, newFiles: inout [String]) throws {
        let insertRep = try db.prepare(
            "INSERT INTO reps (item_id, item_index, position, type, data, file) VALUES (?, ?, ?, ?, ?, ?)")
        for (index, item) in snapshot.items.enumerated() {
            for (position, rep) in item.enumerated() {
                if rep.data.count > Self.inlineLimit {
                    let name = UUID().uuidString + ".bin"
                    try rep.data.write(to: blobDirectory.appendingPathComponent(name), options: .atomic)
                    newFiles.append(name)
                    try insertRep.run([
                        .int(itemID), .int(Int64(index)), .int(Int64(position)), .text(rep.type), .null, .text(name),
                    ])
                } else {
                    try insertRep.run([
                        .int(itemID), .int(Int64(index)), .int(Int64(position)), .text(rep.type), .blob(rep.data), .null,
                    ])
                }
            }
        }
    }

    private func deleteItems(_ ids: [Int64]) throws {
        try Self.deleteItems(ids, db: db, blobDirectory: blobDirectory)
    }

    private static func deleteItems(_ ids: [Int64], db: SQLiteDatabase, blobDirectory: URL) throws {
        for chunk in chunks(ids) {
            try db.transaction {
                try removeRepresentations(of: chunk, db: db, blobDirectory: blobDirectory)
                let marks = chunk.map { _ in "?" }.joined(separator: ",")
                try db.prepare("DELETE FROM items WHERE id IN (\(marks))").run(chunk.map { .int($0) })
            }
        }
    }

    /// Splits ids so a statement stays under SQLite's bound-parameter limit.
    private static func chunks(_ ids: [Int64]) -> [[Int64]] {
        stride(from: 0, to: ids.count, by: 500).map { Array(ids[$0..<min($0 + 500, ids.count)]) }
    }

    private func removeRepresentations(of ids: [Int64]) throws {
        try Self.removeRepresentations(of: ids, db: db, blobDirectory: blobDirectory)
    }

    private static func removeRepresentations(of ids: [Int64], db: SQLiteDatabase, blobDirectory: URL) throws {
        let marks = ids.map { _ in "?" }.joined(separator: ",")
        let values = ids.map { Statement.Value.int($0) }
        try db.prepare("SELECT file FROM reps WHERE file IS NOT NULL AND item_id IN (\(marks))").rows(values) { row in
            if let file = row.text(0) { try? FileManager.default.removeItem(at: blobDirectory.appendingPathComponent(file)) }
        }
        try db.prepare("DELETE FROM reps WHERE item_id IN (\(marks))").run(values)
    }

    /// Identity of a copy: the content a person sees, not app specific extras, so the same
    /// text copied from two apps is one entry.
    static func contentHash(_ snapshot: ClipSnapshot, kind: ClipKind) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(kind.rawValue.utf8))
        let keyTypes: [String] = switch kind {
        case .file: [PasteboardType.fileURL]
        case .image: PasteboardType.images
        case .text, .link, .color: [PasteboardType.plainText]
        }
        for item in snapshot.items {
            if let rep = item.first(where: { keyTypes.contains($0.type) }) {
                hasher.update(data: Data([0]))
                // Text that differs only by surrounding blank space is the same copy to a person.
                if rep.type == PasteboardType.plainText, let text = String(data: rep.data, encoding: .utf8) {
                    hasher.update(data: Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
                } else {
                    hasher.update(data: rep.data)
                }
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func text(_ value: String?) -> Statement.Value {
        value.map { .text($0) } ?? .null
    }

    private static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
