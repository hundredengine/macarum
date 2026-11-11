import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MacarumCore

/// A solid PNG of the given size, made in memory.
private func pngData(width: Int, height: Int) -> Data {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    return out as Data
}

private func snap(_ reps: [(String, Data)]) -> ClipSnapshot {
    ClipSnapshot(items: [reps.map { ClipRepresentation(type: $0.0, data: $0.1) }])
}

@Suite struct ClassifierTests {
    @Test(arguments: [
        ("https://example.com/path?q=1", ClipKind.link),
        ("http://localhost:8080", .link),
        ("example.com", .text),
        ("ftp://example.com", .text),
        ("https://a.com and more words", .text),
        ("#fff", .color),
        ("#FF8800", .color),
        ("#ff880080", .color),
        ("#ff88", .text),
        ("#GGGGGG", .text),
        ("just some text", .text),
    ])
    func textKinds(text: String, kind: ClipKind) throws {
        let summary = try #require(ClipClassifier.summarize(snap([(PasteboardType.plainText, Data(text.utf8))])))
        #expect(summary.kind == kind)
    }

    @Test func titleCollapsesWhitespaceAndIsCapped() throws {
        let long = "line one\n\n   line two\t" + String(repeating: "w", count: 1000)
        let summary = try #require(ClipClassifier.summarize(snap([(PasteboardType.plainText, Data(long.utf8))])))
        #expect(summary.title.hasPrefix("line one line two w"))
        #expect(summary.title.count == ClipClassifier.titleLimit + 1)
        #expect(summary.title.hasSuffix("…"))
    }

    @Test func imageGetsSizeAndSmallThumbnail() throws {
        let summary = try #require(ClipClassifier.summarize(snap([(PasteboardType.png, pngData(width: 1200, height: 600))])))
        #expect(summary.kind == .image)
        #expect(summary.imageWidth == 1200)
        #expect(summary.imageHeight == 600)
        #expect(summary.title == "Image 1200 × 600")
        let thumb = try #require(summary.thumbnail)
        let size = try #require(ClipClassifier.pixelSize(of: thumb))
        #expect(max(size.width, size.height) == ClipClassifier.thumbnailMaxPixels)
    }

    @Test func imageWithUrlTextIsStillAnImage() throws {
        let summary = try #require(ClipClassifier.summarize(snap([
            (PasteboardType.plainText, Data("https://example.com/cat.png".utf8)),
            (PasteboardType.tiff, pngData(width: 10, height: 10)),
        ])))
        #expect(summary.kind == .image)
    }

    @Test func imageWithRealTextIsText() throws {
        let summary = try #require(ClipClassifier.summarize(snap([
            (PasteboardType.plainText, Data("A table cell".utf8)),
            (PasteboardType.png, pngData(width: 10, height: 10)),
        ])))
        #expect(summary.kind == .text)
    }

    @Test func hexColorComponents() throws {
        let c = try #require(ClipClassifier.hexColorComponents("#FF000080"))
        #expect(c.r == 1 && c.g == 0 && c.b == 0)
        #expect(abs(c.a - 128.0 / 255) < 0.0001)
    }

    @Test func nothingKnownGivesNil() {
        #expect(ClipClassifier.summarize(ClipSnapshot(items: [])) == nil)
        #expect(ClipClassifier.summarize(snap([(PasteboardType.html, Data("<p></p>".utf8))])) == nil)
    }
}

@Suite struct CaptureRulesTests {
    let rules = CaptureRules(maxRepresentationBytes: 100, ignoredBundleIDs: ["com.example.secret"])

    @Test func concealedCopiesAreIgnored() {
        #expect(rules.shouldIgnore(types: [PasteboardType.plainText, "org.nspasteboard.ConcealedType"], source: nil))
        #expect(rules.shouldIgnore(types: [PasteboardType.plainText, PasteboardType.macarumRestored], source: nil))
        #expect(!rules.shouldIgnore(types: [PasteboardType.plainText], source: nil))
    }

    @Test func ignoredAppsIncludeDefaultsAndUserList() {
        #expect(rules.shouldIgnore(types: [], source: SourceApp(bundleID: "com.example.secret", name: nil)))
        #expect(rules.shouldIgnore(types: [], source: SourceApp(bundleID: "com.1password.1password", name: nil)))
        #expect(!rules.shouldIgnore(types: [], source: SourceApp(bundleID: "com.apple.Safari", name: nil)))
    }

    @Test func readsOnlyKeptTypesInStableOrder() {
        let available = ["com.private.thing", PasteboardType.html, PasteboardType.plainText]
        #expect(rules.typesToRead(from: available) == [PasteboardType.plainText, PasteboardType.html])
    }

    @Test func richTextOnlyGetsPlainText() {
        let rtf = ClipSnapshot(items: [[ClipRepresentation(type: PasteboardType.rtf, data: Data("{rtf}".utf8))]])
        let out = rules.addingPlainText(to: rtf) { type, _ in type == PasteboardType.rtf ? "Bold words" : nil }
        #expect(out.first(PasteboardType.plainText) == Data("Bold words".utf8))

        // Items that already have plain text are left alone.
        let both = ClipSnapshot(items: [[ClipRepresentation(type: PasteboardType.plainText, data: Data("x".utf8)),
                                         ClipRepresentation(type: PasteboardType.rtf, data: Data("{rtf}".utf8))]])
        #expect(rules.addingPlainText(to: both) { _, _ in "y" } == both)
    }

    @Test func trimDropsOversizedAndEmpty() {
        let s = ClipSnapshot(items: [
            [ClipRepresentation(type: PasteboardType.plainText, data: Data("ok".utf8)),
             ClipRepresentation(type: PasteboardType.png, data: Data(count: 500))],
            [ClipRepresentation(type: PasteboardType.plainText, data: Data())],
        ])
        #expect(rules.trim(s).items == [[ClipRepresentation(type: PasteboardType.plainText, data: Data("ok".utf8))]])
    }
}
