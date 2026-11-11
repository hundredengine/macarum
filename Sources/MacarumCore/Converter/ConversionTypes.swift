import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What kind of file came in, as far as converting goes (docs/specs/2026-11-07-converter.md).
public enum InputKind: String, Sendable, CaseIterable {
    /// Anything ImageIO reads: HEIC, JPG, PNG, WebP, TIFF, GIF, BMP, camera RAW.
    case image
    case svg
    case pdf
    /// A movie AVFoundation opens: MOV, MP4, M4V.
    case video
    /// A sound file AVFoundation opens: M4A, WAV, AIFF, MP3, CAF.
    case audio
    /// Word (.docx, .doc), RTF or HTML, read by AppKit's text readers.
    case document
}

/// A dropped or chosen file Macarum knows how to convert.
public struct InputFile: Sendable, Hashable {
    public let url: URL
    public let kind: InputKind
    /// The file's type identifier, for example `public.heic`.
    public let typeIdentifier: String

    public init(url: URL, kind: InputKind, typeIdentifier: String) {
        self.url = url
        self.kind = kind
        self.typeIdentifier = typeIdentifier
    }

    /// Size on disk in bytes (0 when unknown).
    public var byteCount: Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }

    /// The file name without its extension, used to name the results.
    public var baseName: String { url.deletingPathExtension().lastPathComponent }

    /// Nil when Macarum cannot convert this file.
    public static func detect(_ url: URL) -> InputFile? {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        guard let type else { return nil }
        if type.conforms(to: .svg) { return InputFile(url: url, kind: .svg, typeIdentifier: type.identifier) }
        if type.conforms(to: .pdf) { return InputFile(url: url, kind: .pdf, typeIdentifier: type.identifier) }
        if type.conforms(to: .image), readableImageTypes.contains(type.identifier) {
            return InputFile(url: url, kind: .image, typeIdentifier: type.identifier)
        }
        if readableMediaTypes.contains(type.identifier) {
            if type.conforms(to: .movie) || type.conforms(to: .video) {
                return InputFile(url: url, kind: .video, typeIdentifier: type.identifier)
            }
            if type.conforms(to: .audio) { return InputFile(url: url, kind: .audio, typeIdentifier: type.identifier) }
        }
        if DocumentFormat.readableTypes.contains(where: { type.conforms(to: $0) }) {
            return InputFile(url: url, kind: .document, typeIdentifier: type.identifier)
        }
        return nil
    }

    static let readableImageTypes = Set(CGImageSourceCopyTypeIdentifiers() as? [String] ?? [])
    static let readableMediaTypes = Set(AVURLAsset.audiovisualTypes().map(\.rawValue))
}

/// Image formats Macarum writes. WebP is not here: macOS reads it but cannot write it
/// (ADR-0004).
public enum ImageFormat: String, Sendable, CaseIterable {
    case jpeg
    case png
    case heic
    case tiff

    public var typeIdentifier: String {
        switch self {
        case .jpeg: UTType.jpeg.identifier
        case .png: UTType.png.identifier
        case .heic: UTType.heic.identifier
        case .tiff: UTType.tiff.identifier
        }
    }

    public var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .png: "png"
        case .heic: "heic"
        case .tiff: "tiff"
        }
    }

    /// What the person reads on a button.
    public var title: String {
        switch self {
        case .jpeg: "JPG"
        case .png: "PNG"
        case .heic: "HEIC"
        case .tiff: "TIFF"
        }
    }

    public var keepsTransparency: Bool { self == .png || self == .tiff || self == .heic }
    public var isLossy: Bool { self == .jpeg || self == .heic }

    /// The format of an input file, when Macarum can also write it.
    public init?(typeIdentifier: String) {
        guard let match = Self.allCases.first(where: { $0.typeIdentifier == typeIdentifier }) else { return nil }
        self = match
    }
}

/// JPG (and HEIC) quality, picked in the panel and remembered.
public enum JPEGQuality: String, Sendable, CaseIterable {
    case best
    case good
    case small

    public static let `default` = JPEGQuality.good

    public var value: Double {
        switch self {
        case .best: 0.95
        case .good: 0.85
        case .small: 0.7
        }
    }

    public var title: String {
        switch self {
        case .best: "Best"
        case .good: "Good"
        case .small: "Small"
        }
    }
}

/// How much bigger than its own size an SVG is drawn.
public enum SVGScale: Int, Sendable, CaseIterable {
    case x1 = 1
    case x2 = 2
    case x4 = 4

    public static let `default` = SVGScale.x2
    public var title: String { "\(rawValue)×" }
}

/// A file size the result must stay under. "2 MB" is 2,000,000 bytes, so it also fits a form
/// that counts 2 × 1024 × 1024.
public struct SizeLimit: Hashable, Sendable {
    public let bytes: Int

    public init(bytes: Int) { self.bytes = bytes }

    public static let presets = [5_000_000, 2_000_000, 1_000_000, 500_000].map(SizeLimit.init(bytes:))

    public var title: String { bytes >= 1_000_000 ? "\(bytes / 1_000_000) MB" : "\(bytes / 1000) KB" }

    /// Added to the result's name: "photo under 2MB.jpg".
    var nameSuffix: String { " under " + title.replacingOccurrences(of: " ", with: "") }
}

/// A smaller size for a video. Only sizes below the source are offered; nothing is enlarged.
public enum VideoSize: Int, Sendable, CaseIterable {
    case p1080 = 1080
    case p720 = 720

    public var title: String { "\(rawValue)p" }
    /// The box the picture has to fit in, long side by short side.
    public var longSide: Int { self == .p1080 ? 1920 : 1280 }
    public var shortSide: Int { rawValue }
    var preset: String { self == .p1080 ? AVAssetExportPreset1920x1080 : AVAssetExportPreset1280x720 }

    /// True when a picture of this size is bigger than the box, so making it this size helps.
    public func isSmaller(than size: CGSize) -> Bool {
        let long = max(size.width, size.height), short = min(size.width, size.height)
        return long > CGFloat(longSide) || short > CGFloat(shortSide)
    }
}

/// Sound formats Macarum writes.
public enum AudioFormat: String, Sendable, CaseIterable {
    case m4a
    case wav
    case aiff

    public var title: String { self == .m4a ? "M4A" : self == .wav ? "WAV" : "AIFF" }
    public var fileExtension: String { rawValue }
    /// The input types that already are this format, so it is not offered for them.
    var sameTypes: Set<String> {
        switch self {
        case .m4a: ["com.apple.m4a-audio"]
        case .wav: ["com.microsoft.waveform-audio"]
        case .aiff: ["public.aiff-audio", "public.aifc-audio"]
        }
    }
}

/// What a Word, RTF or HTML document becomes.
public enum DocumentOutput: String, Sendable, CaseIterable {
    case pdf
    case plainText

    public var title: String { self == .pdf ? "PDF" : "Text" }
    public var fileExtension: String { self == .pdf ? "pdf" : "txt" }
}

/// The documents AppKit reads (`NSAttributedString` readers).
enum DocumentFormat {
    static let docx = UTType("org.openxmlformats.wordprocessingml.document")!
    static let doc = UTType("com.microsoft.word.doc")!
    static let readableTypes: [UTType] = [docx, doc, .rtf, .html]
}

/// One thing a set of files can become.
public enum Conversion: Hashable, Sendable {
    /// Each file to this format (images and SVG).
    case convert(ImageFormat)
    /// Each image saved under a file size: the best quality that fits, smaller only if needed.
    case fitUnder(SizeLimit)
    /// All images, in order, as the pages of one PDF.
    case combinePDF
    /// All images, in order, as the frames of one looping GIF.
    case animatedGIF
    /// Each page of each PDF as an image.
    case pdfPages(ImageFormat)
    /// The text of each PDF as a Word document (layout and images are not kept).
    case pdfToWord
    /// Each video as MP4 (the picture and sound are copied as they are when MP4 can hold them).
    case videoToMP4
    /// Each video made smaller, as MP4.
    case videoResize(VideoSize)
    /// The start of each video as a small looping GIF.
    case videoToGIF
    /// The sound of each video as M4A.
    case extractAudio
    /// Each sound file to this format.
    case audio(AudioFormat)
    /// Each document as PDF or plain text.
    case document(DocumentOutput)
}

/// The row an offer is shown in.
public enum OfferGroup: Int, Sendable, CaseIterable, Comparable {
    case to
    case eachTo
    case combine
    case pagesTo
    case soundOnly
    case videoSize
    case maxSize

    public var title: String {
        switch self {
        case .to: "Convert to"
        case .eachTo: "Each to"
        case .combine: "Combine"
        case .pagesTo: "Pages to"
        case .soundOnly: "Sound only"
        case .videoSize: "Video size"
        case .maxSize: "Max file size"
        }
    }

    public static func < (a: OfferGroup, b: OfferGroup) -> Bool { a.rawValue < b.rawValue }
}

/// A choice in the panel: pick it, then Convert runs it.
public struct ConversionOffer: Hashable, Sendable, Identifiable {
    public let conversion: Conversion
    public let group: OfferGroup
    public let title: String
    /// A sentence shown once the offer is picked, for what it does not do or how it works.
    public let note: String?
    public var id: Conversion { conversion }

    public init(_ conversion: Conversion, group: OfferGroup, title: String, note: String? = nil) {
        self.conversion = conversion
        self.group = group
        self.title = title
        self.note = note
    }

    /// Whether the JPG quality choice matters for this offer.
    public var usesQuality: Bool {
        switch conversion {
        case .convert(let format), .pdfPages(let format): format.isLossy
        case .combinePDF: true
        case .fitUnder, .animatedGIF, .pdfToWord, .videoToMP4, .videoResize, .videoToGIF, .extractAudio, .audio, .document: false
        }
    }

    /// Long jobs (video and sound) report progress within a file, so the panel shows a percentage.
    public var reportsPartialProgress: Bool {
        switch conversion {
        case .videoToMP4, .videoResize, .videoToGIF, .extractAudio, .audio: true
        default: false
        }
    }
}

/// Where results go.
public enum OutputDestination: Sendable, Equatable {
    case nextToOriginal
    case folder(URL)
}

public struct ConversionSettings: Sendable, Equatable {
    public var quality: JPEGQuality
    public var svgScale: SVGScale
    public var destination: OutputDestination

    public init(quality: JPEGQuality = .default, svgScale: SVGScale = .default, destination: OutputDestination = .nextToOriginal) {
        self.quality = quality
        self.svgScale = svgScale
        self.destination = destination
    }
}

/// One file that could not be converted, with a sentence the person can act on.
public struct ConversionFailure: Sendable, Equatable {
    public let fileName: String
    public let message: String

    public init(fileName: String, message: String) {
        self.fileName = fileName
        self.message = message
    }
}

public struct ConversionOutcome: Sendable, Equatable {
    public var saved: [URL] = []
    public var failures: [ConversionFailure] = []
    /// True when the person stopped it; the files in `saved` were finished before that.
    public var cancelled = false

    public init(saved: [URL] = [], failures: [ConversionFailure] = [], cancelled: Bool = false) {
        self.saved = saved
        self.failures = failures
        self.cancelled = cancelled
    }
}

public enum ConversionError: LocalizedError, Equatable {
    case unreadableImage
    case unreadableSVG
    case unreadablePDF
    case lockedPDF
    case emptyPDF
    case unreadableVideo
    case unreadableAudio
    case unreadableDocument
    case protectedMedia
    case noSound
    case noPicture
    case emptyDocument
    case noTextInPDF
    case encodingFailed(String)
    case cannotFit(String)
    case folderMissing(String)
    case cannotWrite(folder: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .unreadableImage: "Macarum couldn't read this image."
        case .unreadableSVG: "Macarum couldn't draw this SVG."
        case .unreadablePDF: "Macarum couldn't open this PDF."
        case .lockedPDF: "This PDF is locked with a password."
        case .emptyPDF: "This PDF has no pages."
        case .unreadableVideo: "Macarum couldn't open this video."
        case .unreadableAudio: "Macarum couldn't open this sound file."
        case .unreadableDocument: "Macarum couldn't read this document."
        case .protectedMedia: "This file is copy protected, so it can't be converted."
        case .noSound: "This video has no sound."
        case .noPicture: "This file has no picture to make a GIF from."
        case .emptyDocument: "This document has no text."
        case .noTextInPDF: "This PDF has no text to copy. It may be scanned pages."
        case .encodingFailed(let format): "Macarum couldn't save it as \(format)."
        case .cannotFit(let limit): "Couldn't get it under \(limit) without making it tiny; nothing was saved."
        case .folderMissing(let name): "The folder “\(name)” is gone. Choose another one in Settings."
        case .cannotWrite(let folder, let reason): "Can't save in “\(folder)”: \(reason). Choose another folder in Settings."
        }
    }
}

/// Lets a converter report how far it got: `done` of `total` units (files or pages). Video and
/// sound converters also report part of a file, so `done` can be 2.4 of 3.
public typealias ConversionProgress = @Sendable (_ done: Double, _ total: Int) -> Void
