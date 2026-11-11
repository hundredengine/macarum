import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Word (.docx, .doc), RTF and HTML to PDF or plain text, read by AppKit's own text
/// readers. The PDF is the text laid out on pages of the document's paper size (A4 with 2.5 cm
/// margins when it has none), like printing it from TextEdit.
public struct DocumentConverter: FileConverter {
    public init() {}

    /// A4 in points.
    static let a4 = CGSize(width: 595.28, height: 841.89)
    static let defaultMargin: CGFloat = 72

    public let accepts: Set<InputKind> = [.document]

    public func handles(_ conversion: Conversion) -> Bool {
        if case .document = conversion { return true }
        return false
    }

    public func offers(for files: [InputFile]) -> [ConversionOffer] {
        let group: OfferGroup = files.count == 1 ? .to : .eachTo
        return [
            ConversionOffer(.document(.pdf), group: group, title: DocumentOutput.pdf.title),
            ConversionOffer(.document(.plainText), group: group, title: DocumentOutput.plainText.title,
                            note: "Only the words, without fonts, pictures or layout."),
        ]
    }

    public func run(_ conversion: Conversion, files: [InputFile], settings: ConversionSettings,
                    progress: @escaping ConversionProgress) async -> ConversionOutcome {
        guard case .document(let output) = conversion else { return ConversionOutcome() }
        return await runEach(files, progress: progress) { file, _ in
            let directory = try OutputWriter.directory(for: file.url, destination: settings.destination)
            let document = try await Self.read(file)
            guard !document.text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConversionError.emptyDocument
            }
            let data: Data
            switch output {
            case .plainText: data = Data(document.text.string.utf8)
            case .pdf: data = try Self.pdf(document.text, layout: document.layout, title: file.baseName)
            }
            return try OutputWriter.write(data, base: file.baseName, ext: output.fileExtension, in: directory)
        }
    }

    /// Paper and margins in points.
    struct PageLayout: Equatable {
        var paper = DocumentConverter.a4
        var margins = NSEdgeInsets(top: defaultMargin, left: defaultMargin, bottom: defaultMargin, right: defaultMargin)

        static func == (a: PageLayout, b: PageLayout) -> Bool {
            a.paper == b.paper && a.margins.top == b.margins.top && a.margins.left == b.margins.left
                && a.margins.bottom == b.margins.bottom && a.margins.right == b.margins.right
        }

        /// The document's own paper and margins when it says them and they leave room for text.
        init(attributes: [NSAttributedString.DocumentAttributeKey: Any] = [:]) {
            if let size = (attributes[.paperSize] as? NSValue)?.sizeValue, size.width >= 144, size.height >= 144 {
                paper = size
            }
            func margin(_ key: NSAttributedString.DocumentAttributeKey) -> CGFloat? {
                (attributes[key] as? NSNumber).map { CGFloat($0.doubleValue) }.flatMap { $0 >= 0 ? $0 : nil }
            }
            let proposed = NSEdgeInsets(top: margin(.topMargin) ?? defaultMargin, left: margin(.leftMargin) ?? defaultMargin,
                                        bottom: margin(.bottomMargin) ?? defaultMargin, right: margin(.rightMargin) ?? defaultMargin)
            if paper.width - proposed.left - proposed.right >= 72, paper.height - proposed.top - proposed.bottom >= 72 {
                margins = proposed
            }
        }

        var textSize: CGSize {
            CGSize(width: paper.width - margins.left - margins.right, height: paper.height - margins.top - margins.bottom)
        }
    }

    struct Document: @unchecked Sendable {
        let text: NSAttributedString
        let layout: PageLayout
    }

    /// Reads the file with AppKit. HTML goes through WebKit, which wants the main thread; it does
    /// not load anything from the internet (checked with a local server on macOS 27.0.1).
    static func read(_ file: InputFile) async throws -> Document {
        let url = file.url
        if UTType(file.typeIdentifier)?.conforms(to: .html) == true {
            return try await MainActor.run { try readNow(url, type: .html) }
        }
        let type: NSAttributedString.DocumentType? = switch file.typeIdentifier {
        case DocumentFormat.docx.identifier: .officeOpenXML
        case DocumentFormat.doc.identifier: .docFormat
        default: nil // RTF and others: AppKit tells by itself
        }
        return try readNow(url, type: type)
    }

    private static func readNow(_ url: URL, type: NSAttributedString.DocumentType?) throws -> Document {
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
        if let type { options[.documentType] = type }
        var attributes: NSDictionary?
        guard let text = try? NSAttributedString(url: url, options: options, documentAttributes: &attributes) else {
            throw ConversionError.unreadableDocument
        }
        return Document(text: text, layout: PageLayout(attributes: attributes as? [NSAttributedString.DocumentAttributeKey: Any] ?? [:]))
    }

    /// Lays the text out page after page (TextKit, one text container per page) into a PDF.
    static func pdf(_ text: NSAttributedString, layout page: PageLayout, title: String) throws -> Data {
        let storage = NSTextStorage(attributedString: text)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)

        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: page.paper)
        let info: [CFString: Any] = [kCGPDFContextTitle: title, kCGPDFContextCreator: "Macarum"]
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary) else {
            throw ConversionError.encodingFailed("PDF")
        }
        let previous = NSGraphicsContext.current
        defer { NSGraphicsContext.current = previous }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let origin = CGPoint(x: page.margins.left, y: page.margins.top)
        var pages = 0
        while true {
            let container = NSTextContainer(size: page.textSize)
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            let range = layoutManager.glyphRange(for: container)
            if range.length == 0, pages > 0 { break }
            context.beginPDFPage(nil)
            context.saveGState()
            // AppKit text draws top down; flip the PDF page to match.
            context.translateBy(x: 0, y: page.paper.height)
            context.scaleBy(x: 1, y: -1)
            layoutManager.drawBackground(forGlyphRange: range, at: origin)
            layoutManager.drawGlyphs(forGlyphRange: range, at: origin)
            context.restoreGState()
            context.endPDFPage()
            pages += 1
            if NSMaxRange(range) >= layoutManager.numberOfGlyphs || pages > 10_000 { break }
        }
        context.closePDF()
        return data as Data
    }
}

/// The text of a PDF as a Word document. macOS has no way to rebuild a PDF's layout,
/// so only the text comes over, page after page; layout and images are not kept, and the offer
/// says so.
public struct PDFToWordConverter: FileConverter {
    public init() {}

    public let accepts: Set<InputKind> = [.pdf]

    public func handles(_ conversion: Conversion) -> Bool { conversion == .pdfToWord }

    public func offers(for files: [InputFile]) -> [ConversionOffer] {
        [ConversionOffer(.pdfToWord, group: files.count == 1 ? .to : .eachTo, title: "Word, text only",
                         note: "Only the text comes over. The layout and images are not kept.")]
    }

    public func run(_ conversion: Conversion, files: [InputFile], settings: ConversionSettings,
                    progress: @escaping ConversionProgress) async -> ConversionOutcome {
        await runEach(files, progress: progress) { file, _ in
            let directory = try OutputWriter.directory(for: file.url, destination: settings.destination)
            let data = try Self.word(from: file.url)
            return try OutputWriter.write(data, base: file.baseName, ext: "docx", in: directory)
        }
    }

    static func text(of url: URL) throws -> NSAttributedString {
        guard let document = PDFDocument(url: url) else { throw ConversionError.unreadablePDF }
        if document.isLocked, !document.unlock(withPassword: "") { throw ConversionError.lockedPDF }
        guard document.pageCount > 0 else { throw ConversionError.emptyPDF }
        let text = NSMutableAttributedString()
        for index in 0..<document.pageCount {
            if Task.isCancelled { throw CancellationError() }
            guard let page = document.page(at: index)?.attributedString, page.length > 0 else { continue }
            if text.length > 0 { text.append(NSAttributedString(string: "\n\n")) }
            text.append(page)
        }
        guard !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConversionError.noTextInPDF }
        return text
    }

    static func word(from url: URL) throws -> Data {
        let text = try text(of: url)
        do {
            return try text.data(from: NSRange(location: 0, length: text.length),
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        } catch {
            throw ConversionError.encodingFailed("Word")
        }
    }
}
