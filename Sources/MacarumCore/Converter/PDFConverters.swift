import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Images, in order, as the pages of one PDF. Each page is the image's own size at its
/// own resolution, no margins.
public struct ImagesToPDFConverter: FileConverter {
    public init() {}

    public let accepts: Set<InputKind> = [.image]

    public func handles(_ conversion: Conversion) -> Bool { conversion == .combinePDF }

    public func offers(for files: [InputFile]) -> [ConversionOffer] {
        files.count == 1
            ? [ConversionOffer(.combinePDF, group: .to, title: "PDF")]
            : [ConversionOffer(.combinePDF, group: .combine, title: "One PDF")]
    }

    public func run(_ conversion: Conversion, files: [InputFile], settings: ConversionSettings,
                    progress: @escaping ConversionProgress) async -> ConversionOutcome {
        var outcome = ConversionOutcome()
        guard let first = files.first else { return outcome }
        let directory: URL
        do {
            directory = try OutputWriter.directory(for: first.url, destination: settings.destination)
        } catch {
            outcome.fail(first, error)
            return outcome
        }

        let data = NSMutableData()
        let info: [CFString: Any] = [kCGPDFContextTitle: first.baseName, kCGPDFContextCreator: "Macarum"]
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: nil, info as CFDictionary) else {
            outcome.fail(first, ConversionError.encodingFailed("PDF"))
            return outcome
        }
        progress(0, files.count)
        var pages = 0
        for (index, file) in files.enumerated() {
            if Task.isCancelled {
                outcome.cancelled = true
                break
            }
            do {
                let page = try Self.pageImage(file, quality: settings.quality.value)
                var box = CGRect(origin: .zero, size: page.size)
                context.beginPage(mediaBox: &box)
                context.draw(page.image, in: box)
                context.endPage()
                pages += 1
            } catch {
                outcome.fail(file, error)
            }
            progress(Double(index + 1), files.count)
        }
        context.closePDF()
        guard pages > 0, !outcome.cancelled else { return outcome }
        do {
            outcome.saved.append(try OutputWriter.write(data as Data, base: first.baseName, ext: "pdf", in: directory))
        } catch {
            outcome.fail(first, error)
        }
        return outcome
    }

    /// The image to draw and its page size in points. A JPG already upright is embedded as it
    /// is (Quartz keeps its JPG data); other opaque images are embedded as JPG at the chosen
    /// quality, and transparent ones stay lossless.
    static func pageImage(_ file: InputFile, quality: Double) throws -> (image: CGImage, size: CGSize) {
        guard let source = CGImageSourceCreateWithURL(file.url as CFURL, nil) else { throw ConversionError.unreadableImage }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1

        let image: CGImage
        if file.typeIdentifier == UTType.jpeg.identifier, orientation == 1,
           let original = CGImageSourceCreateImageAtIndex(source, index, nil) {
            image = original
        } else {
            let loaded = try ImagePipeline.load(file.url)
            if loaded.hasAlpha {
                image = loaded.image
            } else {
                let jpeg = try ImagePipeline.encode(loaded.image, as: .jpeg, quality: quality)
                guard let provider = CGDataProvider(data: jpeg as CFData),
                      let embedded = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
                else { throw ConversionError.encodingFailed("PDF") }
                image = embedded
            }
        }
        let dpiX = (properties[kCGImagePropertyDPIWidth] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 72
        let dpiY = (properties[kCGImagePropertyDPIHeight] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? dpiX
        // DPI belongs to the stored axes; a quarter turn swaps them.
        let turned = (5...8).contains(orientation)
        let size = CGSize(width: Double(image.width) * 72 / (turned ? dpiY : dpiX),
                          height: Double(image.height) * 72 / (turned ? dpiX : dpiY))
        return (image, size)
    }
}

/// Every page of a PDF as an image, at 144 dpi on white.
public struct PDFPagesConverter: FileConverter {
    public init() {}

    /// Pixels per point: 2 is 144 dpi, an A4 page becomes 1191 × 1684 px.
    public static let scale: CGFloat = 2

    public let accepts: Set<InputKind> = [.pdf]

    public func handles(_ conversion: Conversion) -> Bool {
        if case .pdfPages = conversion { return true }
        return false
    }

    public func offers(for files: [InputFile]) -> [ConversionOffer] {
        [ImageFormat.png, .jpeg].map { ConversionOffer(.pdfPages($0), group: .pagesTo, title: $0.title) }
    }

    public func run(_ conversion: Conversion, files: [InputFile], settings: ConversionSettings,
                    progress: @escaping ConversionProgress) async -> ConversionOutcome {
        guard case .pdfPages(let format) = conversion else { return ConversionOutcome() }
        var outcome = ConversionOutcome()
        var documents: [(InputFile, CGPDFDocument)] = []
        for file in files {
            do { documents.append((file, try Self.open(file.url))) } catch { outcome.fail(file, error) }
        }
        let total = documents.reduce(0) { $0 + $1.1.numberOfPages }
        var done = 0
        progress(0, total)
        for (file, document) in documents {
            do {
                let directory = try OutputWriter.directory(for: file.url, destination: settings.destination)
                let count = document.numberOfPages
                // One page: a file next to the PDF. More: a new folder named after the PDF.
                let folder = count == 1 ? directory : try OutputWriter.makeFolder(base: file.baseName, in: directory)
                let digits = String(count).count
                for number in 1...count {
                    if Task.isCancelled {
                        outcome.cancelled = true
                        return outcome
                    }
                    guard let page = document.page(at: number) else { continue }
                    let data = try ImagePipeline.encode(try Self.render(page),
                                                        as: format, quality: settings.quality.value)
                    let base = count == 1 ? file.baseName : file.baseName + " " + Self.padded(number, digits: max(2, digits))
                    outcome.saved.append(try OutputWriter.write(data, base: base, ext: format.fileExtension, in: folder))
                    done += 1
                    progress(Double(done), total)
                }
            } catch {
                outcome.fail(file, error)
            }
        }
        return outcome
    }

    static func padded(_ number: Int, digits: Int) -> String {
        let text = String(number)
        return String(repeating: "0", count: max(0, digits - text.count)) + text
    }

    static func open(_ url: URL) throws -> CGPDFDocument {
        guard let document = CGPDFDocument(url as CFURL) else { throw ConversionError.unreadablePDF }
        if document.isEncrypted, !document.isUnlocked, !document.unlockWithPassword("") {
            throw ConversionError.lockedPDF
        }
        guard document.numberOfPages > 0 else { throw ConversionError.emptyPDF }
        return document
    }

    /// The page as seen in Preview: crop box, page rotation applied, on white.
    static func render(_ page: CGPDFPage) throws -> CGImage {
        let box = page.getBoxRect(.cropBox)
        let turned = abs(page.rotationAngle) % 180 == 90
        let size = turned ? CGSize(width: box.height, height: box.width) : box.size
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ConversionError.unreadablePDF }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { throw ConversionError.unreadablePDF }
        return image
    }
}
