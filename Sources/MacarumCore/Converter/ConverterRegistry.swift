import Foundation

/// One family of conversions. The panel never knows about formats: it asks the registry what
/// a set of files can become and runs the offer that was clicked. A video or document
/// converter later is one more type in `ConverterRegistry.converters`.
public protocol FileConverter: Sendable {
    /// The input kinds this converter takes. It is asked only when every file is one of them.
    var accepts: Set<InputKind> { get }
    /// What it offers for these files (empty when nothing fits). Async because video offers
    /// depend on the picture size and length, which AVFoundation loads off the main thread.
    func offers(for files: [InputFile]) async -> [ConversionOffer]
    func handles(_ conversion: Conversion) -> Bool
    /// Converts and saves. Per-file problems go into the outcome's failures; it throws only
    /// when nothing at all can be done. Checks for cancellation between files or pages.
    func run(_ conversion: Conversion, files: [InputFile], settings: ConversionSettings,
             progress: @escaping ConversionProgress) async -> ConversionOutcome
}

/// The files that came in, split into those Macarum can convert and those it cannot.
public struct InputSelection: Sendable, Equatable {
    public let files: [InputFile]
    public let unsupported: [URL]

    public init(urls: [URL]) {
        var files: [InputFile] = []
        var unsupported: [URL] = []
        var seen = Set<URL>()
        for url in urls where seen.insert(url.standardizedFileURL).inserted {
            if let file = InputFile.detect(url) { files.append(file) } else { unsupported.append(url) }
        }
        self.files = files
        self.unsupported = unsupported
    }

    /// "IMG_2041.heic", "3 images", "2 PDFs", "2 videos", "4 files".
    public var title: String {
        if files.count == 1 { return files[0].url.lastPathComponent }
        let kinds = Set(files.map(\.kind))
        guard kinds.count == 1, let kind = kinds.first else { return "\(files.count) files" }
        let noun = switch kind {
        case .image: "images"
        case .svg: "SVGs"
        case .pdf: "PDFs"
        case .video: "videos"
        case .audio: "sound files"
        case .document: "documents"
        }
        return "\(files.count) \(noun)"
    }
}

public enum ConverterRegistry {
    public static let converters: [any FileConverter] = [
        ImageConverter(),
        ImagesToPDFConverter(),
        ImagesToGIFConverter(),
        PDFToWordConverter(),
        PDFPagesConverter(),
        VideoConverter(),
        AudioConverter(),
        DocumentConverter(),
    ]

    /// Everything these files can become, ordered by row (`OfferGroup`) and then as each
    /// converter listed them.
    public static func offers(for files: [InputFile]) async -> [ConversionOffer] {
        guard !files.isEmpty else { return [] }
        let kinds = Set(files.map(\.kind))
        var all: [ConversionOffer] = []
        for converter in converters where kinds.isSubset(of: converter.accepts) {
            all += await converter.offers(for: files)
        }
        return all.enumerated().sorted { ($0.element.group, $0.offset) < ($1.element.group, $1.offset) }.map(\.element)
    }

    public static func converter(for conversion: Conversion) -> (any FileConverter)? {
        converters.first { $0.handles(conversion) }
    }

    public static func run(_ conversion: Conversion, files: [InputFile], settings: ConversionSettings,
                           progress: @escaping ConversionProgress = { _, _ in }) async -> ConversionOutcome {
        guard let converter = converter(for: conversion) else { return ConversionOutcome() }
        return await converter.run(conversion, files: files, settings: settings, progress: progress)
    }
}

extension ConversionOutcome {
    mutating func fail(_ file: InputFile, _ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        failures.append(ConversionFailure(fileName: file.url.lastPathComponent, message: message))
    }
}
