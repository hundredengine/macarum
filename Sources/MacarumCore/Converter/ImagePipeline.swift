import AppKit
import CoreGraphics
import Foundation
import ImageIO

/// Reading, drawing and writing images with ImageIO and CoreGraphics (ADR-0004).
/// Everything here is safe off the main thread: each call uses its own sources and contexts.
public enum ImagePipeline {
    /// A decoded image, upright, plus the metadata to carry over.
    struct Loaded {
        var image: CGImage
        var properties: [CFString: Any]
        var typeIdentifier: String
        /// From the file, not the decoded image: ImageIO hands back an alpha channel even for
        /// opaque photos (a HEIC thumbnail came back premultiplied).
        var hasAlpha: Bool { properties[kCGImagePropertyHasAlpha] as? Bool ?? false }
    }

    /// Decodes the main frame with its EXIF orientation applied to the pixels, at most
    /// `maxWidth` wide (as seen); never enlarged. The colour space stays the source's.
    static func load(_ url: URL, maxWidth: Int? = nil) throws -> Loaded {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source) as String? else { throw ConversionError.unreadableImage }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw ConversionError.unreadableImage }
        let size = orientedSize(width: width, height: height, orientation: properties[kCGImagePropertyOrientation] as? Int)
        var maxSide = max(size.width, size.height)
        if let maxWidth, maxWidth < size.width {
            maxSide = Int((Double(maxSide) * Double(maxWidth) / Double(size.width)).rounded())
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            throw ConversionError.unreadableImage
        }
        return Loaded(image: image, properties: properties, typeIdentifier: type)
    }

    /// A small upright preview for the panel (decodes only what it needs).
    public static func thumbnail(of url: URL, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), options as CFDictionary)
    }

    /// The size in pixels as the image is seen (orientation applied), without decoding it.
    static func orientedPixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return nil }
        let size = orientedSize(width: width, height: height, orientation: properties[kCGImagePropertyOrientation] as? Int)
        return CGSize(width: size.width, height: size.height)
    }

    /// Width and height as the image is seen: orientations 5 to 8 turn it a quarter.
    static func orientedSize(width: Int, height: Int, orientation: Int?) -> (width: Int, height: Int) {
        (5...8).contains(orientation ?? 1) ? (height, width) : (width, height)
    }

    /// Draws an SVG with the system's renderer (the one Preview uses) at `scale` times its size.
    static func loadSVG(_ url: URL, scale: Int) throws -> CGImage {
        guard let data = try? Data(contentsOf: url), let svg = NSImage(data: data),
              svg.size.width > 0, svg.size.height > 0 else { throw ConversionError.unreadableSVG }
        let width = Int((svg.size.width * CGFloat(scale)).rounded(.up))
        let height = Int((svg.size.height * CGFloat(scale)).rounded(.up))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ConversionError.unreadableSVG }
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        svg.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.current = previous
        guard let image = context.makeImage() else { throw ConversionError.unreadableSVG }
        return image
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    /// The same picture on white, without an alpha channel, in the image's own colour space
    /// when it is an RGB one (so a Display P3 photo stays P3).
    static func flattenedOnWhite(_ image: CGImage) -> CGImage? {
        let space = image.colorSpace.flatMap { $0.model == .rgb && $0.supportsOutput ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }

    /// The source's metadata for a new, upright file of this size: EXIF, GPS and the rest stay;
    /// orientation becomes 1 because the pixels are already turned.
    static func outputProperties(from source: [CFString: Any], width: Int, height: Int, format: ImageFormat, quality: Double) -> [CFString: Any] {
        var properties = source
        for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyDepth,
                    kCGImagePropertyHasAlpha, kCGImagePropertyColorModel, kCGImagePropertyProfileName,
                    kCGImagePropertyFileSize] {
            properties.removeValue(forKey: key)
        }
        properties[kCGImagePropertyOrientation] = 1
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = width
            exif[kCGImagePropertyExifPixelYDimension] = height
            properties[kCGImagePropertyExifDictionary] = exif
        }
        if format.isLossy { properties[kCGImageDestinationLossyCompressionQuality] = quality }
        return properties
    }

    /// Encodes in memory; transparent images going to JPG get a white background first, and an
    /// alpha channel the source never had (`sourceHasAlpha: false`) is dropped.
    static func encode(_ image: CGImage, as format: ImageFormat, quality: Double, properties: [CFString: Any] = [:],
                       sourceHasAlpha: Bool = true) throws -> Data {
        var image = image
        if hasAlpha(image), !format.keepsTransparency || !sourceHasAlpha {
            guard let flat = flattenedOnWhite(image) else { throw ConversionError.encodingFailed(format.title) }
            image = flat
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, format.typeIdentifier as CFString, 1, nil) else {
            throw ConversionError.encodingFailed(format.title)
        }
        let props = outputProperties(from: properties, width: image.width, height: image.height, format: format, quality: quality)
        CGImageDestinationAddImage(destination, image, props as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.encodingFailed(format.title) }
        return output as Data
    }
}
