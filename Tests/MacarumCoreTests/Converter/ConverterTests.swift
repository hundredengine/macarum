import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MacarumCore

private func files(_ urls: URL...) -> [InputFile] { InputSelection(urls: urls).files }

private func run(_ conversion: Conversion, _ files: [InputFile], _ settings: ConversionSettings = ConversionSettings()) async -> ConversionOutcome {
    await ConverterRegistry.run(conversion, files: files, settings: settings)
}

@Suite struct ConverterOfferTests {
    @Test func detectsKinds() async throws {
        let s = try Samples()
        let png = try s.image("a.png", type: .png, Samples.picture(width: 4, height: 4))
        let zip = s.url("a.zip")
        try Data("x".utf8).write(to: zip)
        let selection = InputSelection(urls: [try s.heic(), png, try s.webp(), try s.svg(), try s.pdf(pages: [CGSize(width: 10, height: 10)]), zip, png])
        #expect(selection.files.map(\.kind) == [.image, .image, .image, .svg, .pdf])
        #expect(selection.files.map(\.typeIdentifier).prefix(3) == ["public.heic", "public.png", "org.webmproject.webp"])
        #expect(selection.unsupported == [zip])
        #expect(selection.title == "5 files")
    }

    @Test func smallHEICOffersJPGPNGPDFAndNoSizeLimit() async throws {
        let s = try Samples()
        let offers = await ConverterRegistry.offers(for: files(try s.heic()))
        #expect(offers.map(\.title) == ["JPG", "PNG", "PDF"])
        #expect(offers.allSatisfy { $0.group == .to })
    }

    @Test func pngIsNotOfferedToPNG() async throws {
        let s = try Samples()
        let png = try s.image("a.png", type: .png, Samples.picture(width: 4, height: 4))
        #expect(await ConverterRegistry.offers(for: files(png)).map(\.title) == ["JPG", "PDF"])
    }

    @Test func offersOnlyLimitsTheFileIsOver() async throws {
        let s = try Samples()
        let file = s.url("big.jpg")
        try Data(count: 1_400_000).write(to: file)
        let offers = ImageConverter().offers(for: [InputFile(url: file, kind: .image, typeIdentifier: "public.jpeg")])
        #expect(offers.filter { $0.group == .maxSize }.map(\.title) == ["1 MB", "500 KB"])
        #expect(OfferGroup.maxSize.title == "Max file size")
    }

    @Test func severalImagesOfferEachToAndOnePDF() async throws {
        let s = try Samples()
        let png = try s.image("a.png", type: .png, Samples.picture(width: 4, height: 4))
        let offers = await ConverterRegistry.offers(for: files(try s.heic(), png))
        #expect(offers.filter { $0.group == .eachTo }.map(\.title) == ["JPG", "PNG"])
        // Several images can also become one animated GIF (5 photos once offered no GIF).
        #expect(offers.filter { $0.group == .combine }.map(\.conversion) == [.combinePDF, .animatedGIF])
    }

    @Test func svgPDFAndMixedOffers() async throws {
        let s = try Samples()
        let pdf = try s.pdf(pages: [CGSize(width: 10, height: 10)])
        #expect(await ConverterRegistry.offers(for: files(try s.svg())).map(\.conversion) == [.convert(.png)])
        #expect(await ConverterRegistry.offers(for: files(pdf)).map(\.conversion) == [.pdfToWord, .pdfPages(.png), .pdfPages(.jpeg)])
        #expect(await ConverterRegistry.offers(for: files(pdf, try s.heic())).isEmpty)
        #expect(await ConverterRegistry.offers(for: files(try s.svg(), try s.heic())).map(\.conversion) == [.convert(.png)])
    }

    @Test func everyOfferHasAConverter() async throws {
        let s = try Samples()
        let png = try s.image("a.png", type: .png, Samples.picture(width: 4, height: 4))
        for set in [files(try s.heic()), files(try s.heic(), png), files(try s.svg()), files(try s.pdf(pages: [CGSize(width: 9, height: 9)]))] {
            for offer in await ConverterRegistry.offers(for: set) {
                #expect(ConverterRegistry.converter(for: offer.conversion) != nil)
            }
        }
    }
}

@Suite struct ImageConversionTests {
    @Test func heicToJPGIsUprightKeepsP3AndEXIF() async throws {
        let s = try Samples()
        let outcome = await run(.convert(.jpeg), files(try s.heic()))
        #expect(outcome.failures.isEmpty)
        let url = try #require(outcome.saved.first)
        #expect(url.lastPathComponent == "photo.jpg")
        let info = try ImageInfo(url)
        #expect(info.type == "public.jpeg")
        #expect((info.width, info.height) == (300, 400))
        #expect(info.orientation == 1)
        #expect(info.properties[kCGImagePropertyProfileName] as? String == "Display P3")
        let exif = info.properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifDateTimeOriginal] as? String == "2026:11:07 10:00:00")
        // Orientation 6 turns the picture clockwise: the stored top left corner is now top right.
        #expect(near(info.pixel(info.width - 5, 5), [0, 0, 255, 255], tolerance: 60))
        #expect(info.pixel(5, 5)[0] > 200)
    }

    @Test func heicToPNG() async throws {
        let s = try Samples()
        let info = try ImageInfo(try #require(await run(.convert(.png), files(try s.heic())).saved.first))
        #expect(info.type == "public.png")
        #expect((info.width, info.height) == (300, 400))
    }

    @Test func opaqueSourceToPNGHasNoAlphaChannel() async throws {
        let s = try Samples()
        let jpg = try s.image("photo.jpg", type: .jpeg, Samples.picture(width: 60, height: 40, opaque: true))
        let info = try ImageInfo(try #require(await run(.convert(.png), files(jpg)).saved.first))
        #expect(info.properties[kCGImagePropertyHasAlpha] as? Bool != true)
        #expect(!ImagePipeline.hasAlpha(info.image))
    }

    @Test func transparentPNGToJPGGetsWhiteBackground() async throws {
        let s = try Samples()
        let png = try s.image("cut.png", type: .png, Samples.picture(width: 40, height: 20, transparentRightHalf: true))
        let info = try ImageInfo(try #require(await run(.convert(.jpeg), files(png)).saved.first))
        #expect(info.type == "public.jpeg")
        #expect(near(info.pixel(35, 10), [255, 255, 255, 255]))
        #expect(near(info.pixel(15, 15), [255, 0, 0, 255], tolerance: 40))
    }

    @Test func jpgToPNGUsesQualityAndBack() async throws {
        let s = try Samples()
        let jpg = try s.image("noise.jpg", type: .jpeg, Samples.picture(width: 200, height: 100, noise: true),
                              properties: [kCGImageDestinationLossyCompressionQuality: 1.0])
        let png = try #require(await run(.convert(.png), files(jpg)).saved.first)
        #expect(try ImageInfo(png).type == "public.png")
        let best = try #require(await run(.convert(.jpeg), files(png), ConversionSettings(quality: .best)).saved.first)
        let small = try #require(await run(.convert(.jpeg), files(png), ConversionSettings(quality: .small)).saved.first)
        #expect(best.lastPathComponent == "noise (1).jpg")
        #expect(small.lastPathComponent == "noise (2).jpg")
        #expect(try Data(contentsOf: small).count < Data(contentsOf: best).count)
    }

    @Test func webpReadsToPNGWithAlphaAndJPGOnWhite() async throws {
        let s = try Samples()
        let webp = try s.webp()
        let png = try ImageInfo(try #require(await run(.convert(.png), files(webp)).saved.first))
        #expect((png.width, png.height) == (8, 4))
        #expect(png.pixel(6, 1)[3] == 0)
        #expect(near(png.pixel(1, 1), [0, 172, 255, 255], tolerance: 2))
        let jpg = try ImageInfo(try #require(await run(.convert(.jpeg), files(webp)).saved.first))
        #expect(near(jpg.pixel(6, 1), [255, 255, 255, 255], tolerance: 40))
    }

    @Test func fitUnderKeepsFullSizeWhenQualityIsEnough() async throws {
        let s = try Samples()
        let heavy = try s.image("heavy.jpg", type: .jpeg, Samples.picture(width: 1200, height: 900, noise: true),
                                properties: [kCGImageDestinationLossyCompressionQuality: 1.0])
        let before = try Data(contentsOf: heavy).count
        let limit = SizeLimit(bytes: before * 6 / 10)
        let url = try #require(await run(.fitUnder(limit), files(heavy)).saved.first)
        #expect(url.lastPathComponent.hasPrefix("heavy under "))
        #expect(try Data(contentsOf: url).count <= limit.bytes)
        #expect((try ImageInfo(url).width, try ImageInfo(url).height) == (1200, 900))
    }

    @Test func fitUnderMakesItSmallerWhenItHasTo() async throws {
        let s = try Samples()
        let heavy = try s.image("noise.png", type: .png, Samples.picture(width: 1600, height: 1200, noise: true, opaque: true))
        let limit = SizeLimit(bytes: 250_000)
        let url = try #require(await run(.fitUnder(limit), files(heavy)).saved.first)
        let info = try ImageInfo(url)
        #expect(try Data(contentsOf: url).count <= limit.bytes)
        #expect(info.type == "public.jpeg")
        #expect(info.width < 1600 && abs(Double(info.width) / Double(info.height) - 4.0 / 3.0) < 0.02)
    }

    @Test func fitUnderKeepsTransparencyAsPNG() async throws {
        let s = try Samples()
        let url = try #require(await run(.fitUnder(SizeLimit(bytes: 1)), files(try s.webp())).failures.first)
        #expect(url.message == ConversionError.cannotFit("0 KB").errorDescription!)
        let sticker = try s.webp()
        let size = try Data(contentsOf: sticker).count
        let copy = try #require(await run(.fitUnder(SizeLimit(bytes: size + 10)), files(sticker)).saved.first)
        #expect(copy.pathExtension == "webp")
    }

    @Test func sizeLimitTitles() {
        #expect(SizeLimit.presets.map(\.title) == ["5 MB", "2 MB", "1 MB", "500 KB"])
        #expect(SizeLimit(bytes: 2_000_000).nameSuffix == " under 2MB")
    }

    @Test func svgToPNGAtScale() async throws {
        let s = try Samples()
        let info = try ImageInfo(try #require(await run(.convert(.png), files(try s.svg()), ConversionSettings(svgScale: .x2)).saved.first))
        #expect((info.width, info.height, info.type) == (240, 120, "public.png"))
        #expect(near(info.pixel(100, 60), [255, 0, 0, 255], tolerance: 2))
        let x4 = try ImageInfo(try #require(await run(.convert(.png), files(try s.svg()), ConversionSettings(svgScale: .x4)).saved.first))
        #expect((x4.width, x4.height) == (480, 240))
    }

    @Test func brokenFilesFailWithAReadableMessageAndOthersStillSave() async throws {
        let s = try Samples()
        let broken = s.url("broken.png")
        try Data("not a png".utf8).write(to: broken)
        let good = try s.image("good.png", type: .png, Samples.picture(width: 4, height: 4))
        let selection = [InputFile(url: broken, kind: .image, typeIdentifier: "public.png")] + files(good)
        let outcome = await run(.convert(.jpeg), selection)
        #expect(outcome.saved.map(\.lastPathComponent) == ["good.jpg"])
        #expect(outcome.failures == [ConversionFailure(fileName: "broken.png", message: "Macarum couldn't read this image.")])
    }

    @Test func savesInTheChosenFolderAndReportsAMissingOne() async throws {
        let s = try Samples()
        let out = s.url("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let saved = await run(.convert(.png), files(try s.heic()), ConversionSettings(destination: .folder(out)))
        #expect(saved.saved.first?.deletingLastPathComponent().lastPathComponent == "out")
        let missing = await run(.convert(.png), files(try s.heic()), ConversionSettings(destination: .folder(s.url("gone"))))
        #expect(missing.saved.isEmpty)
        #expect(missing.failures.first?.message == ConversionError.folderMissing("gone").errorDescription)
    }

    @Test func cancelledRunStopsBeforeTheNextFile() async throws {
        let s = try Samples()
        let selection = files(try s.heic("a.heic"), try s.heic("b.heic"))
        let task = Task { await run(.convert(.jpeg), selection) }
        task.cancel()
        let outcome = await task.value
        #expect(outcome.cancelled)
        #expect(outcome.saved.isEmpty)
    }
}

@Suite struct PDFConversionTests {
    @Test func imagesBecomeOnePDFInOrder() async throws {
        let s = try Samples()
        let jpg = try s.image("one.jpg", type: .jpeg, Samples.picture(width: 2000, height: 1500, noise: true))
        let png = try s.image("two.png", type: .png, Samples.picture(width: 300, height: 200, transparentRightHalf: true),
                              properties: [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144])
        let heic = try s.heic()
        let outcome = await run(.combinePDF, files(jpg, png, heic))
        let url = try #require(outcome.saved.first)
        #expect(outcome.failures.isEmpty)
        #expect(url.lastPathComponent == "one.pdf")
        let document = try #require(CGPDFDocument(url as CFURL))
        #expect(document.numberOfPages == 3)
        #expect(document.page(at: 1)?.getBoxRect(.mediaBox).size == CGSize(width: 2000, height: 1500))
        #expect(document.page(at: 2)?.getBoxRect(.mediaBox).size == CGSize(width: 150, height: 100))
        #expect(document.page(at: 3)?.getBoxRect(.mediaBox).size == CGSize(width: 300, height: 400))
        // The JPG is embedded as it is, not decoded into a much bigger image.
        let jpgBytes = try Data(contentsOf: jpg).count
        #expect(try Data(contentsOf: url).count < jpgBytes + 600_000)
    }

    @Test func opaqueImagesAreEmbeddedAsJPGAndTransparentOnesLossless() async throws {
        let s = try Samples()
        let opaque = try s.image("flat.png", type: .png, Samples.picture(width: 300, height: 300, opaque: true))
        let clear = try s.image("cut.png", type: .png, Samples.picture(width: 300, height: 300, transparentRightHalf: true))
        let first = try #require(await run(.combinePDF, files(opaque)).saved.first)
        let second = try #require(await run(.combinePDF, files(clear)).saved.first)
        // A JPG inside a PDF is a /DCTDecode stream; lossless pixels are /FlateDecode only.
        #expect(try Data(contentsOf: first).range(of: Data("DCTDecode".utf8)) != nil)
        #expect(try Data(contentsOf: second).range(of: Data("DCTDecode".utf8)) == nil)
    }

    @Test func oneImageToPDF() async throws {
        let s = try Samples()
        let url = try #require(await run(.combinePDF, files(try s.heic())).saved.first)
        #expect(CGPDFDocument(url as CFURL)?.numberOfPages == 1)
    }

    @Test func multipagePDFToPNGPagesInAFolder() async throws {
        let s = try Samples()
        let pdf = try s.pdf(pages: [CGSize(width: 595, height: 842), CGSize(width: 842, height: 595), CGSize(width: 100, height: 50)])
        let outcome = await run(.pdfPages(.png), files(pdf))
        #expect(outcome.failures.isEmpty)
        #expect(outcome.saved.map(\.lastPathComponent) == ["report 01.png", "report 02.png", "report 03.png"])
        #expect(outcome.saved.allSatisfy { $0.deletingLastPathComponent().lastPathComponent == "report" })
        let first = try ImageInfo(outcome.saved[0])
        #expect((first.width, first.height) == (1190, 1684))
        #expect(near(first.pixel(10, 10), [0, 0, 255, 255], tolerance: 2))
        #expect(near(first.pixel(500, 800), [255, 255, 255, 255], tolerance: 0))
        let second = try ImageInfo(outcome.saved[1])
        #expect((second.width, second.height) == (1684, 1190))
        // A second run never touches the first folder.
        let again = await run(.pdfPages(.png), files(pdf))
        #expect(again.saved.first?.deletingLastPathComponent().lastPathComponent == "report (1)")
    }

    @Test func onePagePDFToJPGNextToIt() async throws {
        let s = try Samples()
        let pdf = try s.pdf("card.pdf", pages: [CGSize(width: 200, height: 100)])
        let outcome = await run(.pdfPages(.jpeg), files(pdf))
        let url = try #require(outcome.saved.first)
        #expect(url.lastPathComponent == "card.jpg")
        #expect(url.deletingLastPathComponent() == s.folder.resolvingSymlinksInPath() || url.deletingLastPathComponent() == s.folder)
        let info = try ImageInfo(url)
        #expect((info.width, info.height, info.type) == (400, 200, "public.jpeg"))
    }

    @Test func lockedPDFIsRefused() async throws {
        let s = try Samples()
        let pdf = try s.pdf("secret.pdf", pages: [CGSize(width: 100, height: 100)], password: "pw")
        let outcome = await run(.pdfPages(.png), files(pdf))
        #expect(outcome.saved.isEmpty)
        #expect(outcome.failures == [ConversionFailure(fileName: "secret.pdf", message: "This PDF is locked with a password.")])
    }
}

@Suite struct OutputWriterTests {
    @Test func namesCountUp() {
        #expect(OutputWriter.name(base: "photo", ext: "jpg", index: 0) == "photo.jpg")
        #expect(OutputWriter.name(base: "photo", ext: "jpg", index: 2) == "photo (2).jpg")
        #expect(OutputWriter.name(base: "report", ext: nil, index: 1) == "report (1)")
    }

    @Test func neverOverwrites() throws {
        let s = try Samples()
        let first = try OutputWriter.write(Data("a".utf8), base: "x", ext: "txt", in: s.folder)
        let second = try OutputWriter.write(Data("b".utf8), base: "x", ext: "txt", in: s.folder)
        #expect(first.lastPathComponent == "x.txt")
        #expect(second.lastPathComponent == "x (1).txt")
        #expect(try String(contentsOf: first, encoding: .utf8) == "a")
    }

    @Test func unwritableFolderSaysWhy() throws {
        let s = try Samples()
        let locked = s.url("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        #expect(throws: ConversionError.cannotWrite(folder: "locked", reason: "permission denied")) {
            try OutputWriter.write(Data("a".utf8), base: "x", ext: "txt", in: locked)
        }
    }
}

@Suite struct ConversionClipboardTests {
    @Test func oneImageGoesAsFileAndPicture() throws {
        let s = try Samples()
        let jpg = try s.image("pic.jpg", type: .jpeg, Samples.picture(width: 10, height: 10))
        let snapshot = ConversionClipboard.snapshot(for: [jpg])
        #expect(snapshot.items.count == 1)
        #expect(snapshot.items[0].map(\.type) == [PasteboardType.fileURL, PasteboardType.jpeg])
        #expect(snapshot.first(PasteboardType.jpeg) == (try Data(contentsOf: jpg)))
        // The history lists it as the file, once.
        #expect(ClipClassifier.summarize(snapshot)?.kind == .file)
        #expect(ClipClassifier.summarize(snapshot)?.title == "pic.jpg")
    }

    @Test func severalResultsAndPDFsGoAsFiles() throws {
        let s = try Samples()
        let a = try s.image("a.png", type: .png, Samples.picture(width: 4, height: 4))
        let pdf = try s.pdf(pages: [CGSize(width: 9, height: 9)])
        #expect(ConversionClipboard.snapshot(for: [a, pdf]).items.map { $0.map(\.type) } == [[PasteboardType.fileURL], [PasteboardType.fileURL]])
        #expect(ConversionClipboard.snapshot(for: [pdf]).items.map { $0.map(\.type) } == [[PasteboardType.fileURL]])
        #expect(ClipClassifier.summarize(ConversionClipboard.snapshot(for: [a, pdf]))?.fileCount == 2)
    }

    @Test func copyingTheSameResultTwiceKeepsOneHistoryEntry() async throws {
        let s = try Samples()
        let png = try s.image("a.png", type: .png, Samples.picture(width: 4, height: 4))
        let store = try ClipStore(directory: s.url("store"))
        let macarum = SourceApp(bundleID: "id.hundredengine.macarum", name: "Macarum")
        let first = try await store.insert(ConversionClipboard.snapshot(for: [png]), source: macarum)
        let second = try await store.insert(ConversionClipboard.snapshot(for: [png]), source: macarum)
        guard case .inserted(let id) = first else { Issue.record("not inserted"); return }
        #expect(second == .bumped(id))
        #expect(try await store.items().count == 1)
    }
}
