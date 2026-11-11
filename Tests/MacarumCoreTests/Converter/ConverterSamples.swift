import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MacarumCore

/// Real sample files, made by the system encoders in a fresh temporary folder per test.
struct Samples {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("macarum-convert-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func url(_ name: String) -> URL { folder.appendingPathComponent(name) }

    /// A solid image with a blue square in the top left corner (as stored, before orientation).
    static func picture(width: Int, height: Int, space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!,
                        transparentRightHalf: Bool = false, noise: Bool = false, opaque: Bool = false) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue)!
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(colorSpace: space, components: [1, 0, 0, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: transparentRightHalf ? width / 2 : width, height: height))
        ctx.setFillColor(CGColor(colorSpace: space, components: [0, 0, 1, 1])!)
        let side = min(width, height) / 4
        ctx.fill(CGRect(x: 0, y: height - side, width: side, height: side))
        if noise {
            let pixels = ctx.data!.assumingMemoryBound(to: UInt8.self)
            for i in 0..<(ctx.bytesPerRow * height) where i % 4 != 3 {
                pixels[i] = UInt8(truncatingIfNeeded: (i &* 2_654_435_761) >> 13)
            }
        }
        return ctx.makeImage()!
    }

    @discardableResult
    func image(_ name: String, type: UTType, _ image: CGImage, properties: [CFString: Any] = [:]) throws -> URL {
        let url = url(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    /// A HEIC from the system encoder: 400 × 300 stored, orientation 6 (seen as 300 × 400),
    /// Display P3, with an EXIF date.
    func heic(_ name: String = "photo.heic") throws -> URL {
        try image(name, type: .heic, Self.picture(width: 400, height: 300, space: CGColorSpace(name: CGColorSpace.displayP3)!), properties: [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:11:07 10:00:00"],
        ])
    }

    /// 8 × 4 lossless WebP made for these tests with cwebp from a PNG drawn here: left half
    /// opaque blue (0, 172, 255 in sRGB), right half transparent.
    func webp(_ name: String = "sticker.webp") throws -> URL {
        let url = url(name)
        try Data(base64Encoded: "UklGRh4AAABXRUJQVlA4TBIAAAAvB8AAEA8wrDH/8x84+hDR/wA=")!.write(to: url)
        return url
    }

    func svg(_ name: String = "logo.svg") throws -> URL {
        let url = url(name)
        try Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="120" height="60"><rect width="120" height="60" fill="#ff0000"/></svg>"##.utf8).write(to: url)
        return url
    }

    /// A PDF with pages of the given sizes in points; `password` locks it.
    func pdf(_ name: String = "report.pdf", pages: [CGSize], password: String? = nil) throws -> URL {
        let url = url(name)
        var info: [CFString: Any] = [:]
        if let password {
            info[kCGPDFContextUserPassword] = password
            info[kCGPDFContextOwnerPassword] = password
        }
        let ctx = CGContext(url as CFURL, mediaBox: nil, info as CFDictionary)!
        for size in pages {
            var box = CGRect(origin: .zero, size: size)
            ctx.beginPage(mediaBox: &box)
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: size.height - 20, width: 20, height: 20)) // top left
            ctx.endPage()
        }
        ctx.closePDF()
        return url
    }
}

struct ImageInfo {
    let width: Int
    let height: Int
    let type: String
    let orientation: Int?
    let properties: [CFString: Any]
    let image: CGImage

    init(_ url: URL) throws {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        type = CGImageSourceGetType(source)! as String
        properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        width = properties[kCGImagePropertyPixelWidth] as! Int
        height = properties[kCGImagePropertyPixelHeight] as! Int
        orientation = properties[kCGImagePropertyOrientation] as? Int
        image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    }

    /// RGBA in sRGB at a point measured from the top left.
    func pixel(_ x: Int, _ y: Int) -> [UInt8] {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let i = y * width * 4 + x * 4
        return [p[i], p[i + 1], p[i + 2], p[i + 3]]
    }
}

/// Close enough for lossy formats.
func near(_ a: [UInt8], _ b: [UInt8], tolerance: Int = 24) -> Bool {
    zip(a, b).allSatisfy { abs(Int($0) - Int($1)) <= tolerance }
}
