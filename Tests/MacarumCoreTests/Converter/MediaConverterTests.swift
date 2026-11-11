@preconcurrency import AVFoundation
import AppKit
import Foundation
import PDFKit
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import MacarumCore

private func files(_ urls: URL...) -> [InputFile] { InputSelection(urls: urls).files }

private func run(_ conversion: Conversion, _ files: [InputFile], _ settings: ConversionSettings = ConversionSettings(),
                 progress: @escaping ConversionProgress = { _, _ in }) async -> ConversionOutcome {
    await ConverterRegistry.run(conversion, files: files, settings: settings, progress: progress)
}

private func magic(_ url: URL, _ count: Int = 4) throws -> String {
    String(decoding: try Data(contentsOf: url).prefix(count), as: UTF8.self)
}

private func offers(_ files: [InputFile]) async -> [Conversion] {
    await ConverterRegistry.offers(for: files).map(\.conversion)
}

@Suite struct AnimatedGIFTests {
    @Test func onlySeveralImagesOfferAGIF() async throws {
        let s = try Samples()
        let a = try s.image("a.png", type: .png, Samples.picture(width: 4, height: 4))
        #expect(!(await offers(files(a))).contains(.animatedGIF))
        let offer = try #require(await ConverterRegistry.offers(for: files(a, try s.heic())).first { $0.conversion == .animatedGIF })
        #expect(offer.title == "Animated GIF")
        #expect(offer.group == .combine)
        #expect(offer.note?.contains("half a second") == true)
    }

    @Test func imagesBecomeOneLoopingGIFTheSizeOfTheBiggest() async throws {
        let s = try Samples()
        let small = try s.image("first.png", type: .png, Samples.picture(width: 40, height: 30))
        let big = try s.image("big.jpg", type: .jpeg, Samples.picture(width: 80, height: 60, opaque: true))
        let tall = try s.image("tall.png", type: .png, Samples.picture(width: 30, height: 40))
        let outcome = await run(.animatedGIF, files(small, big, tall))
        #expect(outcome.failures.isEmpty)
        let gif = try #require(outcome.saved.first)
        #expect(gif.lastPathComponent == "first.gif")
        let info = try GIFInfo(gif)
        #expect(info.frames == 3)
        #expect((info.width, info.height) == (80, 60))
        #expect(info.delay == 0.5)
        #expect(info.loops == 0) // 0 is forever
    }

    @Test func bigPhotosAreScaledDownAndOddSizesFitted() throws {
        #expect(ImagesToGIFConverter.canvasSize(for: [CGSize(width: 4000, height: 3000), CGSize(width: 100, height: 900)])
            == CGSize(width: 1200, height: 900))
        let frame = try ImagesToGIFConverter.frame(Samples.picture(width: 10, height: 40, opaque: true), canvas: CGSize(width: 80, height: 40))
        #expect((frame.width, frame.height) == (80, 40))
    }

    @Test func anUnreadableImageIsNamedAndTheRestStillMakeTheGIF() async throws {
        let s = try Samples()
        let a = try s.image("a.png", type: .png, Samples.picture(width: 20, height: 20))
        let b = try s.image("b.png", type: .png, Samples.picture(width: 20, height: 20))
        let broken = s.url("broken.jpg")
        try Data("not a picture".utf8).write(to: broken)
        let selection = [InputFile(url: broken, kind: .image, typeIdentifier: UTType.jpeg.identifier)] + files(a, b)
        let outcome = await run(.animatedGIF, selection)
        #expect(outcome.failures.map(\.fileName) == ["broken.jpg"])
        #expect(try GIFInfo(try #require(outcome.saved.first)).frames == 2)
    }
}

@Suite struct DetectionTests {
    @Test func detectsVideoSoundAndDocuments() async throws {
        let s = try Samples()
        let selection = InputSelection(urls: [
            try await s.video(seconds: 0.2), try s.tone(),
            try s.document("letter.docx", text: "Hi", type: .officeOpenXML), try s.document("notes.rtf", text: "Hi", type: .rtf),
            try s.document("page.html", text: "Hi", type: .html), try s.document("old.doc", text: "Hi", type: .docFormat),
        ])
        #expect(selection.files.map(\.kind) == [.video, .audio, .document, .document, .document, .document])
        #expect(selection.unsupported.isEmpty)
        #expect(InputSelection(urls: [try await s.video("a.mov", seconds: 0.2), try await s.video("b.mov", seconds: 0.2)]).title == "2 videos")
        #expect(InputSelection(urls: [try s.tone("a.wav"), try s.tone("b.aiff", bigEndian: true)]).title == "2 sound files")
    }

    @Test func everyNewOfferHasAConverter() async throws {
        let s = try Samples()
        let sets = [files(try await s.video(seconds: 0.2)), files(try s.tone()), files(try s.document("a.rtf", text: "x", type: .rtf)),
                    files(try s.textPDF(pages: ["x"]))]
        for set in sets {
            let list = await ConverterRegistry.offers(for: set)
            #expect(!list.isEmpty)
            for offer in list { #expect(ConverterRegistry.converter(for: offer.conversion) != nil) }
        }
    }

    @Test func videosAndImagesTogetherOfferNothing() async throws {
        let s = try Samples()
        #expect(await offers(files(try await s.video(seconds: 0.2), try s.heic())).isEmpty)
    }
}

@Suite(.serialized) struct VideoConverterTests {
    @Test func movOffersMP4GIFSoundAndNoBiggerSizes() async throws {
        let s = try Samples()
        let list = await ConverterRegistry.offers(for: files(try await s.video(seconds: 0.5)))
        #expect(list.map(\.conversion) == [.videoToMP4, .videoToGIF, .extractAudio])
        #expect(list.map(\.title) == ["MP4", "GIF", "M4A"])
        #expect(list.map(\.group) == [.to, .to, .soundOnly])
        #expect(OfferGroup.soundOnly.title == "Sound only")
    }

    @Test func mp4IsNotOfferedToMP4AndSilentVideoHasNoSoundOffer() async throws {
        let s = try Samples()
        let mp4 = try await s.video("clip.mp4", seconds: 0.3, sound: false, fileType: .mp4)
        #expect(await offers(files(mp4)) == [.videoToGIF])
    }

    @Test func onlySizesSmallerThanTheVideoAreOffered() async throws {
        let s = try Samples()
        let wide = try await s.video("wide.mov", width: 1600, height: 900, seconds: 0.2, sound: false)
        #expect(await offers(files(wide)).filter { if case .videoResize = $0 { true } else { false } } == [.videoResize(.p720)])
        #expect(VideoSize.p1080.isSmaller(than: CGSize(width: 2160, height: 3840)))
        #expect(!VideoSize.p1080.isSmaller(than: CGSize(width: 1080, height: 1920)))
        #expect(VideoSize.p720.isSmaller(than: CGSize(width: 1080, height: 1920)))
        #expect(OfferGroup.videoSize.title == "Video size")
    }

    @Test func movBecomesMP4WithPictureAndSound() async throws {
        let s = try Samples()
        let mov = try await s.video(seconds: 1)
        let seen = Mutex<[Double]>([])
        let outcome = await run(.videoToMP4, files(mov)) { done, _ in seen.withLock { $0.append(done) } }
        #expect(outcome.failures.isEmpty)
        let mp4 = try #require(outcome.saved.first)
        #expect(mp4.lastPathComponent == "clip.mp4")
        #expect(try magic(mp4, 8).hasSuffix("ftyp"))
        let info = try await mediaInfo(mp4)
        #expect(info.pictureSize == CGSize(width: 320, height: 240))
        #expect(info.hasSound)
        #expect(abs(info.duration - 1) < 0.1)
        #expect(FileManager.default.fileExists(atPath: mov.path))
        #expect(seen.withLock { $0.last } == 1)
    }

    @Test func aBigVideoIsMadeSmaller() async throws {
        let s = try Samples()
        let wide = try await s.video("wide.mov", width: 1600, height: 900, seconds: 0.4, sound: false)
        let outcome = await run(.videoResize(.p720), files(wide))
        let out = try #require(outcome.saved.first)
        #expect(out.lastPathComponent == "wide 720p.mp4")
        #expect(try await mediaInfo(out).pictureSize == CGSize(width: 1280, height: 720))
    }

    @Test func videoBecomesASmallLoopingGIF() async throws {
        let s = try Samples()
        let clip = try await s.video("clip.mov", width: 640, height: 360, seconds: 2, sound: false)
        let outcome = await run(.videoToGIF, files(clip))
        #expect(outcome.failures.isEmpty)
        let info = try GIFInfo(try #require(outcome.saved.first))
        #expect(info.frames == 20)
        #expect((info.width, info.height) == (480, 270))
        #expect(abs(info.delay - 0.1) < 0.001)
        #expect(info.loops == 0)
    }

    @Test func longVideosGiveOnlyTheFirstFifteenSecondsAndSaySo() async throws {
        #expect(VideoConverter.gifTimes(duration: 40).count == 150)
        #expect(VideoConverter.gifTimes(duration: 0.05).count == 1)
        #expect(VideoConverter.gifSize(for: CGSize(width: 320, height: 240)) == CGSize(width: 320, height: 240))
        let s = try Samples()
        let long = try await s.video("long.mov", width: 64, height: 48, seconds: 16, fps: 2, sound: false)
        let gif = try #require(await ConverterRegistry.offers(for: files(long)).first { $0.conversion == .videoToGIF })
        #expect(gif.note?.contains("first 15 seconds") == true)
        let outcome = await run(.videoToGIF, files(long))
        #expect(try GIFInfo(try #require(outcome.saved.first)).frames == 150)
    }

    @Test func theSoundComesOutAsM4A() async throws {
        let s = try Samples()
        let outcome = await run(.extractAudio, files(try await s.video(seconds: 1)))
        let m4a = try #require(outcome.saved.first)
        #expect(m4a.pathExtension == "m4a")
        let info = try await mediaInfo(m4a)
        #expect(info.hasSound)
        #expect(info.pictureSize == nil)
        #expect(abs(info.duration - 1) < 0.1)
    }

    @Test func aSilentVideoSaysItHasNoSound() async throws {
        let s = try Samples()
        let outcome = await run(.extractAudio, files(try await s.video(seconds: 0.3, sound: false)))
        #expect(outcome.saved.isEmpty)
        #expect(outcome.failures.first?.message == "This video has no sound.")
    }

    @Test func cancellingStopsAndLeavesNoFile() async throws {
        let s = try Samples()
        let clip = try await s.video("clip.mov", width: 1600, height: 900, seconds: 2, sound: false)
        let task = Task { await run(.videoResize(.p720), files(clip)) }
        task.cancel()
        let outcome = await task.value
        #expect(outcome.cancelled)
        #expect(outcome.saved.isEmpty)
        let left = try FileManager.default.contentsOfDirectory(atPath: s.folder.path)
        #expect(left == ["clip.mov"])
    }

    @Test func cancellingDuringAnExportStopsItEarly() async throws {
        let s = try Samples()
        let clip = try await s.video("clip.mov", width: 1920, height: 1080, seconds: 4, sound: false)
        let started = ContinuousClock.now
        let full = await run(.videoResize(.p720), files(clip))
        let fullTime = ContinuousClock.now - started
        try FileManager.default.removeItem(at: try #require(full.saved.first))

        let task = Task { await run(.videoResize(.p720), files(clip)) }
        try await Task.sleep(for: fullTime / 4)
        let cancelledAt = ContinuousClock.now
        task.cancel()
        let outcome = await task.value
        #expect(outcome.cancelled)
        #expect(ContinuousClock.now - cancelledAt < fullTime / 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.folder.path) == ["clip.mov"])
    }

    @Test func aFolderThatCannotTakeFilesFailsBeforeConverting() async throws {
        let s = try Samples()
        let clip = try await s.video(seconds: 0.3)
        let locked = s.url("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        let outcome = await run(.videoToMP4, files(clip), ConversionSettings(destination: .folder(locked)))
        #expect(outcome.failures.first?.message == "Can't save in “locked”: permission denied. Choose another folder in Settings.")
    }
}

@Suite struct AudioConverterTests {
    @Test func offersTheOtherFormats() async throws {
        let s = try Samples()
        #expect(await offers(files(try s.tone())) == [.audio(.m4a), .audio(.aiff)])
        #expect(await offers(files(try s.tone("a.aiff", bigEndian: true))) == [.audio(.m4a), .audio(.wav)])
        #expect(await offers(files(try s.tone("a.wav"), try s.tone("b.aiff", bigEndian: true))) == [.audio(.m4a), .audio(.wav), .audio(.aiff)])
    }

    @Test func wavToM4AAndBack() async throws {
        let s = try Samples()
        let m4a = try #require(await run(.audio(.m4a), files(try s.tone())).saved.first)
        #expect(m4a.lastPathComponent == "tone.m4a")
        #expect(try magic(m4a, 8).hasSuffix("ftyp"))
        #expect(abs(try await mediaInfo(m4a).duration - 1) < 0.1)

        let wavBack = try #require(await run(.audio(.wav), files(m4a)).saved.first)
        #expect(wavBack.lastPathComponent == "tone (1).wav") // the original tone.wav stays
        #expect(try magic(wavBack) == "RIFF")
        let file = try AVAudioFile(forReading: wavBack)
        #expect(abs(Double(file.length) / file.fileFormat.sampleRate - 1) < 0.1)
        #expect(file.fileFormat.channelCount == 2)
    }

    @Test func wavToAIFF() async throws {
        let s = try Samples()
        let aiff = try #require(await run(.audio(.aiff), files(try s.tone(rate: 48_000))).saved.first)
        #expect(try magic(aiff) == "FORM")
        let file = try AVAudioFile(forReading: aiff)
        #expect(file.length == 48_000)
        #expect(file.fileFormat.sampleRate == 48_000)
    }

    @Test func aBrokenSoundFileSaysSo() async throws {
        let s = try Samples()
        let broken = s.url("broken.wav")
        try Data("RIFF nope".utf8).write(to: broken)
        let outcome = await run(.audio(.aiff), [InputFile(url: broken, kind: .audio, typeIdentifier: "com.microsoft.waveform-audio")])
        #expect(outcome.failures.first?.message == "Macarum couldn't open this sound file.")
    }
}

@Suite struct DocumentConverterTests {
    @Test func offersPDFAndText() async throws {
        let s = try Samples()
        let list = await ConverterRegistry.offers(for: files(try s.document("a.docx", text: "x", type: .officeOpenXML)))
        #expect(list.map(\.title) == ["PDF", "Text"])
        #expect(list.map(\.conversion) == [.document(.pdf), .document(.plainText)])
    }

    @Test func wordBecomesAPDFWithItsTextOverSeveralPages() async throws {
        let s = try Samples()
        let long = (1...400).map { "Line \($0) of the letter." }.joined(separator: "\n")
        let docx = try s.document("letter.docx", text: "Dear Sam,\n" + long, type: .officeOpenXML)
        let outcome = await run(.document(.pdf), files(docx))
        #expect(outcome.failures.isEmpty)
        let pdf = try #require(outcome.saved.first)
        #expect(pdf.lastPathComponent == "letter.pdf")
        let document = try #require(PDFDocument(url: pdf))
        #expect(document.pageCount > 3)
        #expect(document.page(at: 0)?.string?.contains("Dear Sam") == true)
        #expect(document.page(at: document.pageCount - 1)?.string?.contains("Line 400") == true)
        let box = try #require(document.page(at: 0)?.bounds(for: .mediaBox))
        #expect(box.size == CGSize(width: 612, height: 792)) // the file's own paper: AppKit's writer stores US Letter
    }

    @Test func rtfHTMLAndDocBecomePlainText() async throws {
        let s = try Samples()
        for (name, type) in [("notes.rtf", NSAttributedString.DocumentType.rtf), ("page.html", .html), ("old.doc", .docFormat)] {
            let outcome = await run(.document(.plainText), files(try s.document(name, text: "Hello there", type: type)))
            let txt = try #require(outcome.saved.first)
            #expect(txt.pathExtension == "txt")
            #expect(try String(contentsOf: txt, encoding: .utf8).contains("Hello there"))
        }
    }

    @Test func anEmptyOrBrokenDocumentSaysSo() async throws {
        let s = try Samples()
        let empty = try s.document("empty.rtf", text: " ", type: .rtf)
        #expect(await run(.document(.pdf), files(empty)).failures.first?.message == "This document has no text.")
        let broken = s.url("broken.docx")
        try Data("PK nope".utf8).write(to: broken)
        let outcome = await run(.document(.pdf), [InputFile(url: broken, kind: .document, typeIdentifier: DocumentFormat.docx.identifier)])
        #expect(outcome.failures.first?.message == "Macarum couldn't read this document.")
    }

    @Test func pageLayoutUsesTheDocumentsPaperWhenItMakesSense() {
        let letter = DocumentConverter.PageLayout(attributes: [.paperSize: NSValue(size: NSSize(width: 612, height: 792)), .leftMargin: 36])
        #expect(letter.paper == CGSize(width: 612, height: 792))
        #expect(letter.margins.left == 36 && letter.margins.right == 72)
        let silly = DocumentConverter.PageLayout(attributes: [.paperSize: NSValue(size: NSSize(width: 10, height: 10)), .leftMargin: 900])
        #expect(silly == DocumentConverter.PageLayout())
        #expect(DocumentConverter.PageLayout().paper == DocumentConverter.a4) // A4 when the file says nothing
    }
}

@Suite struct PDFToWordTests {
    @Test func offerSaysOnlyTheTextComesOver() async throws {
        let s = try Samples()
        let offer = try #require(await ConverterRegistry.offers(for: files(try s.textPDF(pages: ["x"]))).first)
        #expect(offer.conversion == .pdfToWord)
        #expect(offer.title == "Word, text only")
        #expect(offer.note == "Only the text comes over. The layout and images are not kept.")
    }

    @Test func pdfTextBecomesAWordDocument() async throws {
        let s = try Samples()
        let pdf = try s.textPDF(pages: ["First page words", "Second page words"])
        let outcome = await run(.pdfToWord, files(pdf))
        #expect(outcome.failures.isEmpty)
        let docx = try #require(outcome.saved.first)
        #expect(docx.lastPathComponent == "letter.docx")
        #expect(try magic(docx, 2) == "PK")
        let text = try NSAttributedString(url: docx, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
                                          documentAttributes: nil).string
        #expect(text.contains("First page words"))
        #expect(text.contains("Second page words"))
    }

    @Test func scannedAndLockedPDFsSaySo() async throws {
        let s = try Samples()
        let scanned = try s.pdf("scan.pdf", pages: [CGSize(width: 100, height: 100)])
        #expect(await run(.pdfToWord, files(scanned)).failures.first?.message == "This PDF has no text to copy. It may be scanned pages.")
        let locked = try s.pdf("secret.pdf", pages: [CGSize(width: 100, height: 100)], password: "pw")
        #expect(await run(.pdfToWord, files(locked)).failures.first?.message == "This PDF is locked with a password.")
    }
}

@Suite struct OutputMoveTests {
    @Test func moveNeverReplacesAFile() throws {
        let s = try Samples()
        try Data("old".utf8).write(to: s.url("clip.mp4"))
        let temp = s.url("temp.bin")
        try Data("new".utf8).write(to: temp)
        let moved = try OutputWriter.move(temp, base: "clip", ext: "mp4", in: s.folder)
        #expect(moved.lastPathComponent == "clip (1).mp4")
        #expect(try String(contentsOf: s.url("clip.mp4"), encoding: .utf8) == "old")
        #expect(!FileManager.default.fileExists(atPath: temp.path))
    }
}
