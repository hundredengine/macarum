import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What the store needs to know about a snapshot before saving it.
public struct ClipSummary: Sendable, Equatable {
    public var kind: ClipKind
    public var title: String
    /// Lowercased, diacritic-folded text used for search.
    public var searchText: String
    public var imageWidth: Int? = nil
    public var imageHeight: Int? = nil
    public var fileCount: Int
    public var thumbnail: Data? = nil
}

public enum ClipClassifier {
    static let titleLimit = 300
    static let searchLimit = 20_000
    static let thumbnailMaxPixels = 96

    /// Returns nil when there is nothing worth saving (empty text, no known types).
    public static func summarize(_ snapshot: ClipSnapshot) -> ClipSummary? {
        let text = snapshot.first(PasteboardType.plainText).flatMap { String(data: $0, encoding: .utf8) }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let fileURLs = snapshot.all(PasteboardType.fileURL)
            .compactMap { String(data: $0, encoding: .utf8) }
            .compactMap { URL(string: $0) }
            .filter(\.isFileURL)
        if !fileURLs.isEmpty {
            let names = fileURLs.map(\.lastPathComponent)
            let title = names.count == 1 ? names[0] : names.joined(separator: ", ")
            return ClipSummary(
                kind: .file,
                title: clip(title, titleLimit),
                searchText: fold(fileURLs.map(\.path).joined(separator: "\n")),
                fileCount: fileURLs.count
            )
        }

        let imageData = PasteboardType.images.lazy.compactMap { snapshot.first($0) }.first
        if let imageData, trimmed.isEmpty || isWebURL(trimmed) {
            let size = pixelSize(of: imageData)
            let label = size.map { "Image \($0.width) × \($0.height)" } ?? "Image"
            return ClipSummary(
                kind: .image,
                title: label,
                searchText: fold(label + (trimmed.isEmpty ? "" : "\n" + trimmed)),
                imageWidth: size?.width,
                imageHeight: size?.height,
                fileCount: 0,
                thumbnail: thumbnail(of: imageData)
            )
        }

        guard !trimmed.isEmpty else { return nil }
        let kind: ClipKind = isWebURL(trimmed) ? .link : (isHexColor(trimmed) ? .color : .text)
        return ClipSummary(
            kind: kind,
            title: clip(collapseWhitespace(trimmed), titleLimit),
            searchText: fold(String(trimmed.prefix(searchLimit))),
            fileCount: 0
        )
    }

    public static func isWebURL(_ string: String) -> Bool {
        guard !string.contains(where: \.isWhitespace),
              let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return false }
        return true
    }

    public static func isHexColor(_ string: String) -> Bool {
        hexColorComponents(string) != nil
    }

    /// RGBA in 0...1 for `#RGB`, `#RRGGBB` or `#RRGGBBAA`.
    public static func hexColorComponents(_ string: String) -> (r: Double, g: Double, b: Double, a: Double)? {
        guard string.hasPrefix("#") else { return nil }
        var hex = String(string.dropFirst())
        guard [3, 6, 8].contains(hex.count), hex.allSatisfy(\.isHexDigit) else { return nil }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        if hex.count == 6 { hex += "FF" }
        guard let value = UInt32(hex, radix: 16) else { return nil }
        return (
            Double((value >> 24) & 0xFF) / 255,
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        )
    }

    public static func fold(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    static func collapseWhitespace(_ string: String) -> String {
        string.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func clip(_ string: String, _ limit: Int) -> String {
        string.count <= limit ? string : String(string.prefix(limit)) + "…"
    }

    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    /// Decodes only as many pixels as the thumbnail needs, so big screenshots stay cheap.
    static func thumbnail(of data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixels,
            kCGImageSourceShouldCacheImmediately: false,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
