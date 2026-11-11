@preconcurrency import AVFoundation
import AppKit
import CoreMedia
import Foundation
import ImageIO
import Testing
@testable import MacarumCore

/// Tiny videos, sound files and documents made in code for the tests (nothing binary is kept in
/// the repository).
extension Samples {
    /// An H.264 video whose colour changes every frame, optionally with an AAC sine tone.
    func video(_ name: String = "clip.mov", width: Int = 320, height: Int = 240, seconds: Double = 1,
               fps: Int = 30, sound: Bool = true, fileType: AVFileType = .mov) async throws -> URL {
        let url = url(name)
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(video)
        let rate = 44_100.0
        var audio: AVAssetWriterInput?
        if sound {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audio = input
        }
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        // Picture and sound go in side by side: the writer interleaves them and stalls one
        // input when the other falls too far behind.
        let frames = max(1, Int(seconds * Double(fps)))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: true)!
        let totalSamples = Int(seconds * rate)
        let chunk = 4096
        var frame = 0, sampleStart = 0
        var videoDone = false, audioDone = audio == nil
        while !videoDone || !audioDone {
            var progressed = false
            if !videoDone, video.isReadyForMoreMediaData {
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
                let pixels = buffer!
                CVPixelBufferLockBaseAddress(pixels, [])
                let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
                let shade = UInt8(truncatingIfNeeded: frame * 255 / max(1, frames - 1))
                for i in stride(from: 0, to: CVPixelBufferGetBytesPerRow(pixels) * height, by: 4) {
                    base[i] = shade; base[i + 1] = 80; base[i + 2] = 255 &- shade; base[i + 3] = 255
                }
                CVPixelBufferUnlockBaseAddress(pixels, [])
                adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
                frame += 1
                progressed = true
                if frame == frames { video.markAsFinished(); videoDone = true }
            }
            if !audioDone, let audio, audio.isReadyForMoreMediaData {
                let count = min(chunk, totalSamples - sampleStart)
                if count > 0 { audio.append(try Self.sineBuffer(format: format, start: sampleStart, count: count)) }
                sampleStart += max(count, 0)
                progressed = true
                if sampleStart >= totalSamples { audio.markAsFinished(); audioDone = true }
            }
            if !progressed { try await Task.sleep(for: .milliseconds(2)) }
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return url
    }

    private static func sineBuffer(format: AVAudioFormat, start: Int, count: Int) throws -> CMSampleBuffer {
        var samples = (0..<count).map { Float(sin(Double(start + $0) * 2 * .pi * 440 / format.sampleRate) * 0.3) }
        var block: CMBlockBuffer?
        let bytes = count * MemoryLayout<Float>.size
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block)
        samples.withUnsafeMutableBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes) }
        var sample: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block!, formatDescription: format.formatDescription, sampleCount: count,
            presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(format.sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw CocoaError(.fileWriteUnknown) }
        return sample
    }

    /// A one second 440 Hz tone as uncompressed sound; the file type follows the extension.
    func tone(_ name: String = "tone.wav", seconds: Double = 1, rate: Double = 44_100, bigEndian: Bool = false) throws -> URL {
        let url = url(name)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: bigEndian,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<2 {
            let data = buffer.floatChannelData![channel]
            for i in 0..<Int(frames) { data[i] = Float(sin(Double(i) * 2 * .pi * 440 / rate) * 0.3) }
        }
        try file.write(from: buffer)
        file.close()
        return url
    }

    /// A document written by AppKit's own writer, so the reader gets a real file.
    func document(_ name: String, text: String, type: NSAttributedString.DocumentType) throws -> URL {
        let url = url(name)
        let body = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)])
        let data = try body.data(from: NSRange(location: 0, length: body.length), documentAttributes: [.documentType: type])
        try data.write(to: url)
        return url
    }

    /// A PDF with real text on each page, drawn by AppKit.
    func textPDF(_ name: String = "letter.pdf", pages: [String]) throws -> URL {
        let url = url(name)
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        for text in pages {
            ctx.beginPDFPage(nil)
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)]).draw(at: CGPoint(x: 72, y: 700))
            NSGraphicsContext.current = previous
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }
}

/// Frame count, frame delay and loop count of a GIF.
struct GIFInfo {
    let frames: Int
    let width: Int
    let height: Int
    let delay: Double
    let loops: Int?

    init(_ url: URL) throws {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == "com.compuserve.gif")
        frames = CGImageSourceGetCount(source)
        let first = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        width = first[kCGImagePropertyPixelWidth] as! Int
        height = first[kCGImagePropertyPixelHeight] as! Int
        let gif = first[kCGImagePropertyGIFDictionary] as? [CFString: Any] ?? [:]
        delay = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif[kCGImagePropertyGIFDelayTime] as? Double) ?? 0
        let container = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        loops = (container?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? Int
    }
}

/// Length, picture size and sound of a finished file, read back with AVFoundation.
func mediaInfo(_ url: URL) async throws -> MediaInfo {
    try #require(await MediaInfo.load(url))
}
