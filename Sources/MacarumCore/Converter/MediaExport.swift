@preconcurrency import AVFoundation
import Foundation

/// What the converter needs to know about a video or sound file before offering anything.
public struct MediaInfo: Sendable, Equatable {
    /// Length in seconds.
    public var duration: Double
    /// The picture as it is shown (rotation applied); nil when there is no picture.
    public var pictureSize: CGSize?
    public var hasSound: Bool
    /// False for copy protected files, which AVFoundation refuses to export.
    public var isExportable: Bool

    public static func load(_ url: URL) async -> MediaInfo? {
        let asset = AVURLAsset(url: url)
        guard let (duration, exportable) = try? await asset.load(.duration, .isExportable),
              let videoTracks = try? await asset.loadTracks(withMediaType: .video),
              let audioTracks = try? await asset.loadTracks(withMediaType: .audio) else { return nil }
        var picture: CGSize?
        if let track = videoTracks.first, let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform) {
            let turned = natural.applying(transform)
            picture = CGSize(width: abs(turned.width).rounded(), height: abs(turned.height).rounded())
        }
        let seconds = duration.seconds.isFinite ? duration.seconds : 0
        return MediaInfo(duration: seconds, pictureSize: picture, hasSound: !audioTracks.isEmpty, isExportable: exportable)
    }
}

/// Runs an `AVAssetExportSession` into the temporary folder, reports its progress, then moves the
/// result to its free name. Cancelling the task stops the export and leaves nothing behind.
enum MediaExport {
    static func export(_ asset: AVURLAsset, preset: String, as fileType: AVFileType, ext: String,
                       base: String, in directory: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try OutputWriter.checkWritable(directory)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConversionError.encodingFailed(ext.uppercased())
        }
        session.shouldOptimizeForNetworkUse = true
        let temporary = OutputWriter.temporaryURL(ext: ext)
        // The session is only read from the watcher (its state stream), never changed there.
        let watched = UncheckedBox(session)
        let watcher = Task {
            for await state in watched.value.states(updateInterval: 0.2) {
                if case .exporting(let report) = state { progress(report.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        do {
            try await session.export(to: temporary, as: fileType)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            if Task.isCancelled { throw CancellationError() }
            throw ConversionError.encodingFailed(ext.uppercased())
        }
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: temporary)
            throw CancellationError()
        }
        progress(1)
        return try OutputWriter.move(temporary, base: base, ext: ext, in: directory)
    }
}

/// Hands a non-Sendable value to another task that only reads it.
struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Runs a per-file media job over every file: progress counts files, with the running file's
/// fraction added, and a cancel stops it after keeping what is done.
func runEach(_ files: [InputFile], progress: @escaping ConversionProgress,
             _ job: (InputFile, _ fraction: @escaping @Sendable (Double) -> Void) async throws -> URL) async -> ConversionOutcome {
    var outcome = ConversionOutcome()
    let total = files.count
    progress(0, total)
    for (index, file) in files.enumerated() {
        if Task.isCancelled {
            outcome.cancelled = true
            break
        }
        do {
            let url = try await job(file) { fraction in progress(Double(index) + min(max(fraction, 0), 1), total) }
            outcome.saved.append(url)
        } catch is CancellationError {
            outcome.cancelled = true
            break
        } catch {
            outcome.fail(file, error)
        }
        progress(Double(index + 1), total)
    }
    return outcome
}

/// MOV to MP4, smaller videos, video to GIF and the sound out of a video.
public struct VideoConverter: FileConverter {
    public init() {}

    /// A video GIF covers at most this many seconds from the start, at `gifFrameRate` frames a
    /// second and at most `gifMaxWidth` pixels wide, so the file stays a size chats accept.
    public static let gifMaxSeconds = 15.0
    public static let gifFrameRate = 10.0
    public static let gifMaxWidth = 480

    public let accepts: Set<InputKind> = [.video]

    public func handles(_ conversion: Conversion) -> Bool {
        switch conversion {
        case .videoToMP4, .videoResize, .videoToGIF, .extractAudio: true
        default: false
        }
    }

    public func offers(for files: [InputFile]) async -> [ConversionOffer] {
        var infos: [MediaInfo] = []
        for file in files {
            guard let info = await MediaInfo.load(file.url), info.isExportable else { return [] }
            infos.append(info)
        }
        let group: OfferGroup = files.count == 1 ? .to : .eachTo
        var offers: [ConversionOffer] = []
        let pictures = infos.compactMap(\.pictureSize)
        let allHavePicture = pictures.count == infos.count
        if allHavePicture, files.contains(where: { $0.typeIdentifier != AVFileType.mp4.rawValue }) {
            offers.append(ConversionOffer(.videoToMP4, group: group, title: "MP4"))
        }
        if allHavePicture {
            let long = infos.contains { $0.duration > Self.gifMaxSeconds + 0.05 }
            offers.append(ConversionOffer(.videoToGIF, group: group, title: "GIF",
                                          note: long ? "Only the first 15 seconds go into the GIF, at most 480 px wide."
                                                     : "At most 480 px wide, 10 frames a second, without sound."))
        }
        if infos.allSatisfy(\.hasSound) {
            offers.append(ConversionOffer(.extractAudio, group: .soundOnly, title: "M4A"))
        }
        if allHavePicture {
            offers += VideoSize.allCases.filter { size in pictures.contains { size.isSmaller(than: $0) } }
                .map { ConversionOffer(.videoResize($0), group: .videoSize, title: $0.title) }
        }
        return offers
    }

    public func run(_ conversion: Conversion, files: [InputFile], settings: ConversionSettings,
                    progress: @escaping ConversionProgress) async -> ConversionOutcome {
        await runEach(files, progress: progress) { file, fraction in
            try await convert(file, conversion, settings, fraction)
        }
    }

    func convert(_ file: InputFile, _ conversion: Conversion, _ settings: ConversionSettings,
                 _ fraction: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let directory = try OutputWriter.directory(for: file.url, destination: settings.destination)
        guard let info = await MediaInfo.load(file.url) else { throw ConversionError.unreadableVideo }
        guard info.isExportable else { throw ConversionError.protectedMedia }
        let asset = AVURLAsset(url: file.url)
        switch conversion {
        case .videoToMP4:
            guard info.pictureSize != nil else { throw ConversionError.noPicture }
            // Copy picture and sound as they are when MP4 can hold them (fast, no quality loss).
            let passthrough = await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetPassthrough,
                                                                       with: asset, outputFileType: .mp4)
            return try await MediaExport.export(asset, preset: passthrough ? AVAssetExportPresetPassthrough : AVAssetExportPresetHighestQuality,
                                                as: .mp4, ext: "mp4", base: file.baseName, in: directory, progress: fraction)
        case .videoResize(let size):
            guard info.pictureSize != nil else { throw ConversionError.noPicture }
            return try await MediaExport.export(asset, preset: size.preset, as: .mp4, ext: "mp4",
                                                base: file.baseName + " " + size.title, in: directory, progress: fraction)
        case .extractAudio:
            guard info.hasSound else { throw ConversionError.noSound }
            return try await MediaExport.export(asset, preset: AVAssetExportPresetAppleM4A, as: .m4a, ext: "m4a",
                                                base: file.baseName, in: directory, progress: fraction)
        case .videoToGIF:
            guard let picture = info.pictureSize else { throw ConversionError.noPicture }
            let data = try await Self.gif(asset, duration: info.duration, picture: picture, fraction: fraction)
            return try OutputWriter.write(data, base: file.baseName, ext: "gif", in: directory)
        default:
            preconditionFailure("not a video conversion")
        }
    }

    /// Frame times for a GIF of a video this long: every tenth of a second from the start, up
    /// to `gifMaxSeconds`; at least one frame.
    static func gifTimes(duration: Double) -> [CMTime] {
        let length = min(duration, gifMaxSeconds)
        let count = max(1, Int((length * gifFrameRate).rounded(.down)))
        return (0..<count).map { CMTime(seconds: Double($0) / gifFrameRate, preferredTimescale: 600) }
    }

    /// The GIF's frame size: the picture, at most `gifMaxWidth` wide, never enlarged.
    static func gifSize(for picture: CGSize) -> CGSize {
        guard picture.width > CGFloat(gifMaxWidth) else { return picture }
        let scale = CGFloat(gifMaxWidth) / picture.width
        return CGSize(width: CGFloat(gifMaxWidth), height: (picture.height * scale).rounded())
    }

    static func gif(_ asset: AVURLAsset, duration: Double, picture: CGSize,
                    fraction: @escaping @Sendable (Double) -> Void) async throws -> Data {
        let times = gifTimes(duration: duration)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = gifSize(for: picture)
        // Half a frame either way: close enough to look smooth, much faster than exact times.
        let tolerance = CMTime(seconds: 0.5 / gifFrameRate, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let writer = try GIFWriter(frameCount: times.count, delay: 1 / gifFrameRate)
        var previous: CGImage?
        var done = 0
        for await result in generator.images(for: times) {
            if Task.isCancelled { throw CancellationError() }
            // A frame that cannot be read repeats the one before, so the timing stays right.
            if let image = try? result.image { previous = image }
            guard let frame = previous else { continue }
            writer.add(frame)
            done += 1
            fraction(Double(done) / Double(times.count))
        }
        if Task.isCancelled { throw CancellationError() }
        guard done == times.count else { throw ConversionError.unreadableVideo }
        return try writer.finish()
    }
}
