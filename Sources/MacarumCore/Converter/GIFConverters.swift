import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes a looping GIF in memory, frame by frame (ImageIO).
struct GIFWriter {
    private let data = NSMutableData()
    private let destination: CGImageDestination
    private let frameProperties: CFDictionary
    let frameCount: Int

    /// `frameCount` is fixed up front (ImageIO needs it); `delay` is seconds per frame.
    init(frameCount: Int, delay: Double) throws {
        guard frameCount > 0,
              let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frameCount, nil)
        else { throw ConversionError.encodingFailed("GIF") }
        self.destination = destination
        self.frameCount = frameCount
        let loop: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
        CGImageDestinationSetProperties(destination, loop as CFDictionary)
        frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay,
                                                           kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary
    }

    func add(_ image: CGImage) {
        CGImageDestinationAddImage(destination, image, frameProperties)
    }

    func finish() throws -> Data {
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.encodingFailed("GIF") }
        return data as Data
    }
}

/// Several images, in order, as one looping GIF: each picture shows for half a second.
/// Every frame is the size of the biggest picture (at most 1200 px on its long side); smaller
/// or differently shaped pictures are fitted in, centred on white.
public struct ImagesToGIFConverter: FileConverter {
    public init() {}

    public static let frameDelay = 0.5
    public static let maxSide = 1200

    public let accepts: Set<InputKind> = [.image]

    public func handles(_ conversion: Conversion) -> Bool { conversion == .animatedGIF }

    public func offers(for files: [InputFile]) -> [ConversionOffer] {
        guard files.count > 1 else { return [] }
        return [ConversionOffer(.animatedGIF, group: .combine, title: "Animated GIF",
                                note: "Each picture shows for half a second, then it starts over.")]
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
        // Only pictures that can be read become frames; the rest are named as failures.
        var readable: [(InputFile, CGSize)] = []
        for file in files {
            if let size = ImagePipeline.orientedPixelSize(of: file.url) { readable.append((file, size)) } else {
                outcome.fail(file, ConversionError.unreadableImage)
            }
        }
        guard !readable.isEmpty else { return outcome }
        let canvas = Self.canvasSize(for: readable.map(\.1))
        progress(0, files.count)
        do {
            let writer = try GIFWriter(frameCount: readable.count, delay: Self.frameDelay)
            for (index, (file, _)) in readable.enumerated() {
                if Task.isCancelled {
                    outcome.cancelled = true
                    return outcome
                }
                let loaded = try ImagePipeline.load(file.url, maxWidth: nil)
                writer.add(try Self.frame(loaded.image, canvas: canvas))
                progress(Double(index + 1), files.count)
            }
            outcome.saved.append(try OutputWriter.write(try writer.finish(), base: first.baseName, ext: "gif", in: directory))
        } catch {
            outcome.fail(first, error)
        }
        return outcome
    }

    /// The biggest picture's size (by area), scaled down to `maxSide` on its long side.
    static func canvasSize(for sizes: [CGSize]) -> CGSize {
        let biggest = sizes.max { $0.width * $0.height < $1.width * $1.height } ?? CGSize(width: 1, height: 1)
        let scale = min(1, CGFloat(maxSide) / max(biggest.width, biggest.height))
        return CGSize(width: max(1, (biggest.width * scale).rounded()), height: max(1, (biggest.height * scale).rounded()))
    }

    /// The picture fitted into the canvas, keeping its shape, centred on white.
    static func frame(_ image: CGImage, canvas: CGSize) throws -> CGImage {
        let width = Int(canvas.width), height = Int(canvas.height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw ConversionError.encodingFailed("GIF") }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        let scale = min(canvas.width / CGFloat(image.width), canvas.height / CGFloat(image.height))
        let drawn = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.draw(image, in: CGRect(x: (canvas.width - drawn.width) / 2, y: (canvas.height - drawn.height) / 2,
                                       width: drawn.width, height: drawn.height))
        guard let frame = context.makeImage() else { throw ConversionError.encodingFailed("GIF") }
        return frame
    }
}
