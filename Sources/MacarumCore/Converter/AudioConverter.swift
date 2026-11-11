@preconcurrency import AVFoundation
import Foundation

/// Sound files between M4A, WAV and AIFF. M4A is AAC through AVFoundation's Apple M4A
/// export; WAV and AIFF are uncompressed 16-bit (24-bit stays 24-bit), same rate and channels.
public struct AudioConverter: FileConverter {
    public init() {}

    public let accepts: Set<InputKind> = [.audio]

    public func handles(_ conversion: Conversion) -> Bool {
        if case .audio = conversion { return true }
        return false
    }

    public func offers(for files: [InputFile]) -> [ConversionOffer] {
        let group: OfferGroup = files.count == 1 ? .to : .eachTo
        let types = Set(files.map(\.typeIdentifier))
        return AudioFormat.allCases
            .filter { !types.isSubset(of: $0.sameTypes) } // a WAV is not offered "to WAV"
            .map { ConversionOffer(.audio($0), group: group, title: $0.title) }
    }

    public func run(_ conversion: Conversion, files: [InputFile], settings: ConversionSettings,
                    progress: @escaping ConversionProgress) async -> ConversionOutcome {
        guard case .audio(let format) = conversion else { return ConversionOutcome() }
        return await runEach(files, progress: progress) { file, fraction in
            let directory = try OutputWriter.directory(for: file.url, destination: settings.destination)
            if format == .m4a {
                guard let info = await MediaInfo.load(file.url), info.hasSound else { throw ConversionError.unreadableAudio }
                guard info.isExportable else { throw ConversionError.protectedMedia }
                return try await MediaExport.export(AVURLAsset(url: file.url), preset: AVAssetExportPresetAppleM4A, as: .m4a,
                                                    ext: format.fileExtension, base: file.baseName, in: directory, progress: fraction)
            }
            try OutputWriter.checkWritable(directory)
            let temporary = OutputWriter.temporaryURL(ext: format.fileExtension)
            do {
                try Self.writePCM(from: file.url, to: temporary, bigEndian: format == .aiff, fraction: fraction)
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
            return try OutputWriter.move(temporary, base: file.baseName, ext: format.fileExtension, in: directory)
        }
    }

    /// Decodes the whole file and writes it as linear PCM; the file type follows the extension.
    static func writePCM(from source: URL, to destination: URL, bigEndian: Bool, fraction: @Sendable (Double) -> Void) throws {
        let input: AVAudioFile
        do { input = try AVAudioFile(forReading: source) } catch { throw ConversionError.unreadableAudio }
        let sourceFormat = input.fileFormat.streamDescription.pointee
        let isPCM = sourceFormat.mFormatID == kAudioFormatLinearPCM
        let bits = isPCM && sourceFormat.mBitsPerChannel >= 24 ? 24 : 16
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: input.fileFormat.sampleRate,
            AVNumberOfChannelsKey: input.fileFormat.channelCount,
            AVLinearPCMBitDepthKey: bits,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: bigEndian,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output: AVAudioFile
        do {
            output = try AVAudioFile(forWriting: destination, settings: settings, commonFormat: input.processingFormat.commonFormat,
                                     interleaved: input.processingFormat.isInterleaved)
        } catch { throw ConversionError.encodingFailed(bigEndian ? "AIFF" : "WAV") }
        let chunk: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: chunk) else {
            throw ConversionError.unreadableAudio
        }
        let length = max(1, input.length)
        while input.framePosition < input.length {
            if Task.isCancelled { throw CancellationError() }
            do { try input.read(into: buffer, frameCount: chunk) } catch { throw ConversionError.unreadableAudio }
            if buffer.frameLength == 0 { break }
            do { try output.write(from: buffer) } catch { throw ConversionError.encodingFailed(bigEndian ? "AIFF" : "WAV") }
            fraction(Double(input.framePosition) / Double(length))
        }
        output.close()
    }
}
