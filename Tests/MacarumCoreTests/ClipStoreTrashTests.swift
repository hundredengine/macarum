import Foundation
import Testing
@testable import MacarumCore

private func text(_ s: String, html: String? = nil) -> ClipSnapshot {
    var reps = [ClipRepresentation(type: PasteboardType.plainText, data: Data(s.utf8))]
    if let html { reps.append(ClipRepresentation(type: PasteboardType.html, data: Data(html.utf8))) }
    return ClipSnapshot(items: [reps])
}

private func newDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("macarum-tests-\(UUID().uuidString)")
}

private func blobCount(_ dir: URL) throws -> Int {
    try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("blobs").path).count
}

private let safari = SourceApp(bundleID: "com.apple.Safari", name: "Safari")
private let big = String(repeating: "b", count: ClipStore.inlineLimit + 10)

/// Delete with undo: deleted items are hidden first and only removed for real later.
@Suite struct ClipStoreTrashTests {
    /// Four items a, b, c, d (d newest) with "a" big enough to live in a blob file.
    private func seeded() async throws -> (ClipStore, URL, [String: Int64]) {
        let dir = newDirectory()
        let store = try ClipStore(directory: dir)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var ids: [String: Int64] = [:]
        for (i, name) in ["a", "b", "c", "d"].enumerated() {
            let content = name == "a" ? text("a" + big) : text(name, html: "<i>\(name)</i>")
            guard case .inserted(let id) = try await store.insert(content, source: safari, at: t0.addingTimeInterval(Double(i)))
            else { throw CancellationError() }
            ids[name] = id
        }
        return (store, dir, ids)
    }

    @Test func trashedItemsAreHiddenFromListAndStats() async throws {
        let (store, dir, ids) = try await seeded()
        let batch = try await store.trash([ids["a"]!, ids["c"]!])
        #expect(try await store.items().map(\.title) == ["d", "b"])
        #expect(try await store.items(matching: "c").isEmpty)
        #expect(try await store.stats().itemCount == 2)
        #expect(try await store.trashedCount(batch) == 2)
        // The blob file stays until the trash is emptied, so undo can bring it back.
        #expect(try blobCount(dir) == 1)
    }

    @Test func undoRestoresContentPinTimestampsAndPosition() async throws {
        let (store, _, ids) = try await seeded()
        try await store.setPinned(ids["b"]!, true)
        let before = try await store.items()
        let snapshotA = try await store.snapshot(for: ids["a"]!)
        let snapshotB = try await store.snapshot(for: ids["b"]!)

        let batch = try await store.trash([ids["a"]!, ids["b"]!])
        #expect(try await store.items().map(\.title) == ["d", "c"])
        let restored = try await store.restore(batch)

        #expect(Set(restored) == [ids["a"]!, ids["b"]!])
        #expect(try await store.items() == before)
        #expect(try await store.items().first?.isPinned == true)
        #expect(try await store.snapshot(for: ids["a"]!) == snapshotA)
        #expect(try await store.snapshot(for: ids["b"]!) == snapshotB)
        #expect(try await store.trashedCount(batch) == 0)
    }

    @Test func secondDeleteJoinsTheSameBatch() async throws {
        let (store, _, ids) = try await seeded()
        let batch = try await store.trash([ids["a"]!])
        let same = try await store.trash([ids["d"]!], into: batch)
        #expect(same == batch)
        #expect(try await store.trashedCount(batch) == 2)
        try await store.restore(batch)
        #expect(try await store.items().map { $0.title.prefix(1) } == ["d", "c", "b", "a"])
    }

    @Test func emptyingTheTrashRemovesRowsAndBlobs() async throws {
        let (store, dir, ids) = try await seeded()
        let batch = try await store.trash([ids["a"]!, ids["b"]!])
        let removed = try await store.emptyTrash(batch)
        #expect(removed == 2)
        #expect(try blobCount(dir) == 0)
        // Undo after the window has nothing left to bring back.
        #expect(try await store.restore(batch).isEmpty)
        #expect(try await store.items().map(\.title) == ["d", "c"])
        // The same text copied again is a fresh item, not a bump of the deleted one.
        #expect(try await store.insert(text("b"), source: nil) != .bumped(ids["b"]!))
    }

    @Test func emptyingOneBatchLeavesOthers() async throws {
        let (store, _, ids) = try await seeded()
        let first = try await store.trash([ids["a"]!])
        let second = try await store.trash([ids["b"]!])
        #expect(first != second)
        try await store.emptyTrash(first)
        try await store.restore(second)
        #expect(try await store.items().map(\.title) == ["d", "c", "b"])
    }

    @Test func reopeningTheStoreEmptiesLeftoverTrash() async throws {
        let (store, dir, ids) = try await seeded()
        try await store.trash([ids["a"]!, ids["c"]!])
        // A crash or quit before the undo window ended: the next launch finishes the delete.
        let reopened = try ClipStore(directory: dir)
        #expect(try await reopened.items().map(\.title) == ["d", "b"])
        #expect(try await reopened.stats().itemCount == 2)
        #expect(try blobCount(dir) == 0)
        #expect(try await reopened.emptyTrash() == 0)
    }

    @Test func copyingTrashedContentAgainBringsItBack() async throws {
        let (store, _, ids) = try await seeded()
        let batch = try await store.trash([ids["c"]!, ids["d"]!])
        #expect(try await store.insert(text("c"), source: nil, at: Date(timeIntervalSince1970: 2_000_000)) == .bumped(ids["c"]!))
        try await store.emptyTrash(batch)
        #expect(try await store.items().map { $0.title.prefix(1) } == ["c", "b", "a"])
    }

    @Test func maintenanceAndClearAllLeaveTrashedItemsForUndo() async throws {
        let (store, _, ids) = try await seeded()
        let batch = try await store.trash([ids["a"]!, ids["b"]!])
        try await store.purge(lastCopiedBefore: Date(timeIntervalSince1970: 3_000_000))
        try await store.enforceSizeLimit(0)
        try await store.deleteAll()
        #expect(try await store.items().isEmpty)
        try await store.restore(batch)
        #expect(try await store.items().map { $0.title.prefix(1) } == ["b", "a"])
    }

    @Test func editMatchingATrashedItemStillSaves() async throws {
        let (store, _, ids) = try await seeded()
        try await store.setPinned(ids["b"]!, true)
        try await store.trash([ids["b"]!])
        // The trashed twin is dropped for real; its pin does not move to the edited item.
        try await store.replaceText(of: ids["c"]!, with: "b")
        #expect(try await store.items().map { $0.title.prefix(1) } == ["b", "d", "a"])
        #expect(try await store.items().first?.isPinned == false)
    }

    @Test func setPinnedForSeveralItems() async throws {
        let (store, _, ids) = try await seeded()
        try await store.setPinned([ids["a"]!, ids["c"]!], true)
        #expect(try await store.items().filter(\.isPinned).map(\.id).sorted() == [ids["a"]!, ids["c"]!].sorted())
    }

    @Test func deleteAndUndoDuringASearchKeepTheResultsFiltered() async throws {
        let dir = newDirectory()
        let store = try ClipStore(directory: dir)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var ids: [String: Int64] = [:]
        for (i, name) in ["red apple", "green apple", "blue sky", "apple pie"].enumerated() {
            guard case .inserted(let id) = try await store.insert(text(name), source: nil, at: t0.addingTimeInterval(Double(i)))
            else { return }
            ids[name] = id
        }
        // Search "apple", select two results, delete them: the rest of the search stays.
        let batch = try await store.trash([ids["apple pie"]!, ids["red apple"]!])
        #expect(try await store.items(matching: "apple").map(\.title) == ["green apple"])
        #expect(try await store.items().map(\.title) == ["blue sky", "green apple"])
        // Undo puts them back into the filtered list at their old places.
        try await store.restore(batch)
        #expect(try await store.items(matching: "apple").map(\.title) == ["apple pie", "green apple", "red apple"])
    }
}
