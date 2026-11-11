import Foundation
import Testing
@testable import MacarumCore

private func textSnapshot(_ text: String, html: String? = nil) -> ClipSnapshot {
    var reps = [ClipRepresentation(type: PasteboardType.plainText, data: Data(text.utf8))]
    if let html { reps.append(ClipRepresentation(type: PasteboardType.html, data: Data(html.utf8))) }
    return ClipSnapshot(items: [reps])
}

private func makeStore() throws -> (ClipStore, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macarum-tests-\(UUID().uuidString)")
    return (try ClipStore(directory: dir), dir)
}

private let finder = SourceApp(bundleID: "com.apple.finder", name: "Finder")
private let safari = SourceApp(bundleID: "com.apple.Safari", name: "Safari")

@Suite struct ClipStoreTests {
    @Test func insertsAndListsNewestFirst() async throws {
        let (store, _) = try makeStore()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        try await store.insert(textSnapshot("first"), source: safari, at: t0)
        try await store.insert(textSnapshot("second"), source: safari, at: t0.addingTimeInterval(10))
        let items = try await store.items()
        #expect(items.map(\.title) == ["second", "first"])
        #expect(items[0].source.name == "Safari")
    }

    @Test func sameTextFromAnotherAppBumpsInsteadOfDuplicating() async throws {
        let (store, _) = try makeStore()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let first = try await store.insert(textSnapshot("hello", html: "<b>hello</b>"), source: safari, at: t0)
        try await store.insert(textSnapshot("other"), source: safari, at: t0.addingTimeInterval(5))
        let again = try await store.insert(textSnapshot("hello"), source: finder, at: t0.addingTimeInterval(10))

        guard case .inserted(let id) = first, case .bumped(let bumped) = again else {
            Issue.record("expected insert then bump, got \(first) and \(again)")
            return
        }
        #expect(id == bumped)
        let items = try await store.items()
        #expect(items.map(\.title) == ["hello", "other"])
        #expect(items[0].copyCount == 2)
        #expect(items[0].source.name == "Finder")
        #expect(items[0].firstCopiedAt == t0)
        // The newest copy's formats replace the old ones.
        let snap = try await store.snapshot(for: id)
        #expect(snap.items.first?.map(\.type) == [PasteboardType.plainText])
    }

    @Test func surroundingBlankSpaceDoesNotMakeANewItem() async throws {
        let (store, _) = try makeStore()
        try await store.insert(textSnapshot("same words"), source: nil)
        #expect(try await store.insert(textSnapshot("\nsame words  \n"), source: nil) != .skipped)
        #expect(try await store.items().count == 1)
    }

    @Test func whitespaceOnlyTextIsSkipped() async throws {
        let (store, _) = try makeStore()
        #expect(try await store.insert(textSnapshot("  \n\t "), source: nil) == .skipped)
        #expect(try await store.items().isEmpty)
    }

    @Test func searchMatchesEveryWordIgnoringCaseAndAccents() async throws {
        let (store, _) = try makeStore()
        try await store.insert(textSnapshot("Résumé for the spring release"), source: safari)
        try await store.insert(textSnapshot("grocery list"), source: finder)
        try await store.insert(textSnapshot("100% done_now"), source: finder)

        #expect(try await store.items(matching: "resume SPRING").map(\.title) == ["Résumé for the spring release"])
        #expect(try await store.items(matching: "release resume").count == 1)
        #expect(try await store.items(matching: "resume grocery").isEmpty)
        // Source app names are searchable too.
        #expect(try await store.items(matching: "safari").count == 1)
        // LIKE wildcards in the query are literal.
        #expect(try await store.items(matching: "0%").map(\.title) == ["100% done_now"])
        #expect(try await store.items(matching: "e_n").map(\.title) == ["100% done_now"])
    }

    @Test func filterByKind() async throws {
        let (store, _) = try makeStore()
        try await store.insert(textSnapshot("https://example.com/a"), source: nil)
        try await store.insert(textSnapshot("#FF8800"), source: nil)
        try await store.insert(textSnapshot("plain words"), source: nil)
        #expect(try await store.items(filter: .links).map(\.kind) == [.link])
        #expect(Set(try await store.items(filter: .text).map(\.kind)) == [.text, .color])
        #expect(try await store.items(filter: .all).count == 3)
    }

    @Test func purgeRemovesItemsOlderThanCutoffAndTheirBlobs() async throws {
        let (store, dir) = try makeStore()
        let old = Date(timeIntervalSince1970: 1_000_000)
        let big = String(repeating: "x", count: ClipStore.inlineLimit + 10)
        try await store.insert(textSnapshot(big), source: nil, at: old)
        try await store.insert(textSnapshot("fresh"), source: nil, at: old.addingTimeInterval(40 * 86_400))
        let blobs = dir.appendingPathComponent("blobs")
        #expect(try FileManager.default.contentsOfDirectory(atPath: blobs.path).count == 1)

        let removed = try await store.purge(lastCopiedBefore: old.addingTimeInterval(30 * 86_400))
        #expect(removed == 1)
        #expect(try await store.items().map(\.title) == ["fresh"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: blobs.path).isEmpty)
    }

    @Test func largeRepresentationRoundTripsThroughBlobFile() async throws {
        let (store, _) = try makeStore()
        let big = String(repeating: "abc", count: 200_000)
        guard case .inserted(let id) = try await store.insert(textSnapshot(big), source: nil) else {
            Issue.record("not inserted")
            return
        }
        let snap = try await store.snapshot(for: id)
        #expect(snap.first(PasteboardType.plainText).flatMap { String(data: $0, encoding: .utf8) } == big)
    }

    @Test func sizeLimitDropsOldestFirst() async throws {
        let (store, _) = try makeStore()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<5 {
            try await store.insert(textSnapshot("item \(i) " + String(repeating: "y", count: 1000)), source: nil,
                                   at: t0.addingTimeInterval(Double(i)))
        }
        try await store.enforceSizeLimit(2500)
        let titles = try await store.items().map { String($0.title.prefix(6)) }
        #expect(titles == ["item 4", "item 3"])
    }

    @Test func markUsedMovesToTop() async throws {
        let (store, _) = try makeStore()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        guard case .inserted(let a) = try await store.insert(textSnapshot("a"), source: nil, at: t0) else { return }
        try await store.insert(textSnapshot("b"), source: nil, at: t0.addingTimeInterval(1))
        try await store.markUsed(a, at: t0.addingTimeInterval(2))
        #expect(try await store.items().map(\.title) == ["a", "b"])
    }

    @Test func deleteAllEmptiesEverything() async throws {
        let (store, dir) = try makeStore()
        try await store.insert(textSnapshot(String(repeating: "z", count: ClipStore.inlineLimit + 1)), source: nil)
        try await store.insert(textSnapshot("small"), source: nil)
        try await store.deleteAll()
        #expect(try await store.stats() == StoreStats(itemCount: 0, byteSize: 0))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("blobs").path).isEmpty)
    }

    @Test func multipleFilesKeepTheirOrder() async throws {
        let (store, _) = try makeStore()
        let urls = ["file:///tmp/a.txt", "file:///tmp/b.png", "file:///tmp/c.pdf"]
        let snap = ClipSnapshot(items: urls.map { [ClipRepresentation(type: PasteboardType.fileURL, data: Data($0.utf8))] })
        guard case .inserted(let id) = try await store.insert(snap, source: finder) else {
            Issue.record("not inserted")
            return
        }
        let item = try #require(try await store.items().first)
        #expect(item.kind == .file)
        #expect(item.fileCount == 3)
        #expect(item.title == "a.txt, b.png, c.pdf")
        #expect(try await store.snapshot(for: id) == snap)
    }

    @Test func editedTextReplacesContentAndMovesToTop() async throws {
        let (store, _) = try makeStore()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        guard case .inserted(let id) = try await store.insert(textSnapshot("helo wrld", html: "<b>helo</b>"), source: safari, at: t0)
        else { return }
        try await store.insert(textSnapshot("newer"), source: nil, at: t0.addingTimeInterval(5))
        try await store.replaceText(of: id, with: "hello world", at: t0.addingTimeInterval(10))

        let items = try await store.items()
        #expect(items.map(\.title) == ["hello world", "newer"])
        #expect(try await store.snapshot(for: id).items == [[ClipRepresentation(type: PasteboardType.plainText, data: Data("hello world".utf8))]])
        #expect(try await store.items(matching: "hello safari").count == 1)
        // Copying the edited text again bumps it instead of adding a duplicate.
        #expect(try await store.insert(textSnapshot("hello world"), source: nil) == .bumped(id))
    }

    @Test func editMatchingAnotherItemKeepsOneCopy() async throws {
        let (store, _) = try makeStore()
        try await store.insert(textSnapshot("same"), source: nil)
        guard case .inserted(let id) = try await store.insert(textSnapshot("draft"), source: nil) else { return }
        try await store.replaceText(of: id, with: "same")
        #expect(try await store.items().map(\.id) == [id])
    }

    @Test func editCanTurnTextIntoALink() async throws {
        let (store, _) = try makeStore()
        guard case .inserted(let id) = try await store.insert(textSnapshot("example"), source: nil) else { return }
        try await store.replaceText(of: id, with: "https://example.com")
        #expect(try await store.items().first?.kind == .link)
    }

    @Test func pinnedItemsSurviveRetentionSizeLimitAndClearAll() async throws {
        let (store, _) = try makeStore()
        let old = Date(timeIntervalSince1970: 1_000_000)
        guard case .inserted(let keep) = try await store.insert(textSnapshot("keep " + String(repeating: "k", count: 2000)),
                                                                source: nil, at: old) else { return }
        try await store.insert(textSnapshot("old"), source: nil, at: old.addingTimeInterval(1))
        try await store.insert(textSnapshot("new"), source: nil, at: old.addingTimeInterval(50 * 86_400))
        try await store.setPinned(keep, true)

        #expect(try await store.items().map(\.isPinned) == [true, false, false])
        try await store.purge(lastCopiedBefore: old.addingTimeInterval(30 * 86_400))
        #expect(try await store.items().map(\.title.first) == ["k", "n"])
        try await store.enforceSizeLimit(100)
        #expect(try await store.items().map(\.id) == [keep])
        try await store.insert(textSnapshot("again"), source: nil)
        try await store.deleteAll()
        #expect(try await store.items().map(\.id) == [keep])
        #expect(try await store.stats().pinnedCount == 1)

        try await store.setPinned(keep, false)
        try await store.deleteAll()
        #expect(try await store.items().isEmpty)
    }

    @Test func editMergingIntoPinnedItemKeepsThePin() async throws {
        let (store, _) = try makeStore()
        guard case .inserted(let pinned) = try await store.insert(textSnapshot("same"), source: nil) else { return }
        try await store.setPinned(pinned, true)
        guard case .inserted(let id) = try await store.insert(textSnapshot("draft"), source: nil) else { return }
        try await store.replaceText(of: id, with: "same")
        #expect(try await store.items().map(\.isPinned) == [true])
    }

    @Test func olderHistoryFileGetsThePinnedColumn() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macarum-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try SQLiteDatabase(path: dir.appendingPathComponent("history.sqlite").path)
        try db.execute("""
            CREATE TABLE items (id INTEGER PRIMARY KEY, hash TEXT NOT NULL UNIQUE, kind TEXT NOT NULL,
                title TEXT NOT NULL, search TEXT NOT NULL, source_bundle TEXT, source_name TEXT,
                first_at REAL NOT NULL, last_at REAL NOT NULL, copy_count INTEGER NOT NULL DEFAULT 1,
                byte_size INTEGER NOT NULL, img_w INTEGER, img_h INTEGER, file_count INTEGER NOT NULL DEFAULT 0,
                thumb BLOB);
            INSERT INTO items (hash, kind, title, search, first_at, last_at, byte_size)
                VALUES ('h', 'text', 'from 0.1.0', 'from 0.1.0', 1, 1, 10);
            """)
        let store = try ClipStore(directory: dir)
        #expect(try await store.items().map(\.title) == ["from 0.1.0"])
        #expect(try await store.items().first?.isPinned == false)
    }
}
