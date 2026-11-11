import Foundation

/// Images and SVG to JPG or PNG, and images saved under a file size.
public struct ImageConverter: FileConverter {
    public init() {}

    public let accepts: Set<InputKind> = [.image, .svg]

    public func handles(_ conversion: Conversion) -> Bool {
        switch conversion {
        case .convert, .fitUnder: true
        default: false
        }
    }

    public func offers(for files: [InputFile]) -> [ConversionOffer] {
        let group: OfferGroup = files.count == 1 ? .to : .eachTo
        let kinds = Set(files.map(\.kind))
        guard kinds == [.image] else {
            // SVG alone or mixed with images: PNG keeps transparency and works for both.
            return [ConversionOffer(.convert(.png), group: group, title: ImageFormat.png.title)]
        }
        let types = Set(files.map(\.typeIdentifier))
        var offers = [ImageFormat.jpeg, .png]
            .filter { types != [$0.typeIdentifier] } // a PNG is not offered "to PNG"
            .map { ConversionOffer(.convert($0), group: group, title: $0.title) }
        // Only limits the biggest file is over: a 1.4 MB photo offers 1 MB and 500 KB.
        let biggest = files.map(\.byteCount).max() ?? 0
        offers += SizeLimit.presets.filter { $0.bytes < biggest }
            .map { ConversionOffer(.fitUnder($0), group: .maxSize, title: $0.title) }
        return offers
    }

    public func run(_ conversion: Conversion, files: [InputFile], settings: ConversionSettings,
                    progress: @escaping ConversionProgress) async -> ConversionOutcome {
        var outcome = ConversionOutcome()
        progress(0, files.count)
        for (index, file) in files.enumerated() {
            if Task.isCancelled {
                outcome.cancelled = true
                break
            }
            do {
                outcome.saved.append(try convert(file, conversion, settings))
            } catch {
                outcome.fail(file, error)
            }
            progress(Double(index + 1), files.count)
        }
        return outcome
    }

    func convert(_ file: InputFile, _ conversion: Conversion, _ settings: ConversionSettings) throws -> URL {
        let directory = try OutputWriter.directory(for: file.url, destination: settings.destination)
        switch conversion {
        case .convert(let format):
            if file.kind == .svg {
                let image = try ImagePipeline.loadSVG(file.url, scale: settings.svgScale.rawValue)
                let data = try ImagePipeline.encode(image, as: format, quality: settings.quality.value)
                return try OutputWriter.write(data, base: file.baseName, ext: format.fileExtension, in: directory)
            }
            let loaded = try ImagePipeline.load(file.url)
            let data = try ImagePipeline.encode(loaded.image, as: format, quality: settings.quality.value,
                                                properties: loaded.properties, sourceHasAlpha: loaded.hasAlpha)
            return try OutputWriter.write(data, base: file.baseName, ext: format.fileExtension, in: directory)

        case .fitUnder(let limit):
            let suffix = limit.nameSuffix
            if file.byteCount <= limit.bytes {
                // Already under: a copy keeps the set complete when several files were picked.
                return try OutputWriter.write(try Data(contentsOf: file.url), base: file.baseName + suffix,
                                              ext: file.url.pathExtension.lowercased(), in: directory)
            }
            let (data, format) = try Self.fit(file.url, under: limit)
            return try OutputWriter.write(data, base: file.baseName + suffix, ext: format.fileExtension, in: directory)

        default:
            preconditionFailure("not an image conversion")
        }
    }

    /// The best-looking file under the limit: JPG (PNG when the image is transparent), at the
    /// highest quality that fits; only when even plain quality is too big, fewer pixels.
    static func fit(_ url: URL, under limit: SizeLimit) throws -> (Data, ImageFormat) {
        var loaded = try ImagePipeline.load(url)
        let format: ImageFormat = loaded.hasAlpha ? .png : .jpeg
        func encode(_ quality: Double) throws -> Data {
            try ImagePipeline.encode(loaded.image, as: format, quality: quality,
                                     properties: loaded.properties, sourceHasAlpha: loaded.hasAlpha)
        }
        for _ in 0..<10 {
            let size: Int
            if format == .jpeg {
                let top = try encode(Self.topQuality)
                if top.count <= limit.bytes { return (top, format) }
                var low = Self.lowestQuality, high = Self.topQuality
                var best = try encode(low)
                size = best.count
                if best.count <= limit.bytes {
                    for _ in 0..<5 {
                        let mid = (low + high) / 2
                        let data = try encode(mid)
                        if data.count <= limit.bytes { best = data; low = mid } else { high = mid }
                    }
                    return (best, format)
                }
            } else {
                let data = try encode(1)
                if data.count <= limit.bytes { return (data, format) }
                size = data.count
            }
            // Bytes go with the pixel count, so the side scales with the square root.
            let factor = min(0.9, (Double(limit.bytes) / Double(size)).squareRoot() * 0.95)
            let width = Int(Double(loaded.image.width) * factor)
            guard width >= Self.smallestWidth else { break }
            loaded = try ImagePipeline.load(url, maxWidth: width)
        }
        throw ConversionError.cannotFit(limit.title)
    }

    static let topQuality = 0.92
    static let lowestQuality = 0.6
    static let smallestWidth = 200
}
