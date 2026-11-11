import AppKit
import MacarumCore
import Observation

/// The converter section's state: what was dropped, what it can become, and how the last run
/// went. Converting runs off the main thread (ADR-0004, spec 2026-11-07-converter).
@MainActor @Observable
final class ConverterModel {
    enum Phase: Equatable {
        case idle
        /// Files are picked; the offers are showing.
        case picked
        /// `done` can be part of a file (2.4 of 3) for video and sound.
        case working(done: Double, total: Int)
        case finished(ConversionOutcome)
        /// Nothing to convert: a sentence instead of offers.
        case message(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var selection: InputSelection?
    private(set) var offers: [ConversionOffer] = []
    private(set) var copied = false
    /// The output picked in the panel; nothing runs until Convert is pressed.
    private(set) var chosen: ConversionOffer?
    /// A small picture of the first file: the photo itself for images, the Finder icon otherwise.
    private(set) var thumbnail: NSImage?
    private(set) var thumbnailIsPhoto = false
    /// True while files hover over the panel.
    var isDropTargeted = false {
        didSet { if isDropTargeted, !oldValue { dragsEntered += 1 } }
    }
    /// Counts drags that reached the panel, so the panel can stay open after one ends there.
    private(set) var dragsEntered = 0

    /// Puts results on the clipboard and in the history (set by the app delegate).
    var copyResults: ([URL]) -> Void = { _ in }
    /// Shows the standard open panel and hands back the chosen files.
    var presentOpenPanel: (_ completion: @escaping ([URL]) -> Void) -> Void = { _ in }

    private let preferences: Preferences
    private var task: Task<Void, Never>?
    private var offersTask: Task<Void, Never>?
    private(set) var runningOffer: ConversionOffer?
    /// True while video offers are being worked out (they need the video's size and length).
    private(set) var isLoadingOffers = false
    /// Turns on only when working out the offers takes a moment, so quick ones never flash.
    private(set) var showsLoadingHint = false

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    var usesQuality: Bool { chosen?.usesQuality ?? offers.contains(where: \.usesQuality) }
    var usesSVGScale: Bool { selection?.files.contains { $0.kind == .svg } ?? false }

    /// Offers grouped into rows, in display order.
    var rows: [(group: OfferGroup, offers: [ConversionOffer])] {
        OfferGroup.allCases.compactMap { group in
            let inGroup = offers.filter { $0.group == group }
            return inGroup.isEmpty ? nil : (group, inGroup)
        }
    }

    // MARK: Input

    func noteDrop() { dragsEntered += 1 }

    func pick(_ urls: [URL]) {
        guard !isWorking else { return }
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty else { return }
        let selection = InputSelection(urls: fileURLs)
        self.selection = selection
        copied = false
        offers = []
        chosen = nil
        offersTask?.cancel()
        loadThumbnail(for: selection.files.first)
        if selection.files.isEmpty {
            let ext = Set(selection.unsupported.map { $0.pathExtension.lowercased() }).sorted()
            phase = .message(ext.count == 1 && !ext[0].isEmpty
                ? "Macarum can't convert .\(ext[0]) files yet."
                : "Macarum can't convert these files yet.")
            return
        }
        phase = .picked
        isLoadingOffers = true
        showsLoadingHint = false
        let files = selection.files
        offersTask = Task { [weak self] in
            let hint = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, let self, self.isLoadingOffers else { return }
                self.showsLoadingHint = true
            }
            let offers = await ConverterRegistry.offers(for: files)
            hint.cancel()
            guard let self, !Task.isCancelled, self.selection == selection else { return }
            self.isLoadingOffers = false
            self.showsLoadingHint = false
            self.offers = offers
            self.chosen = offers.count == 1 ? offers.first : nil
            if offers.isEmpty {
                self.phase = .message(files.contains { $0.kind == .video || $0.kind == .audio } && Set(files.map(\.kind)).count == 1
                    ? "Macarum couldn't open \(files.count == 1 ? "this file" : "these files")."
                    : "These can't be converted together. Drop one kind of file at a time.")
            }
        }
    }

    /// What the picked offer leaves out or how it works, shown under the choices.
    var chosenNote: String? { chosen?.note }

    private func loadThumbnail(for file: InputFile?) {
        thumbnail = file.map { NSWorkspace.shared.icon(forFile: $0.url.path) }
        thumbnailIsPhoto = false
        if let file, file.kind == .svg, let svg = NSImage(contentsOf: file.url) {
            thumbnail = svg
            return
        }
        guard let file, file.kind == .image else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let image = ImagePipeline.thumbnail(of: file.url, maxPixels: 80) else { return }
            await MainActor.run { [weak self] in
                guard let self, self.selection?.files.first == file else { return }
                self.thumbnail = NSImage(cgImage: image, size: .zero)
                self.thumbnailIsPhoto = true
            }
        }
    }

    func chooseFiles() {
        presentOpenPanel { [weak self] urls in self?.pick(urls) }
    }

    /// "Skipped notes.zip" when a mix had files Macarum cannot convert.
    var skippedNote: String? {
        guard let unsupported = selection?.unsupported, !unsupported.isEmpty, !(selection?.files.isEmpty ?? true) else { return nil }
        let names = unsupported.prefix(2).map(\.lastPathComponent).joined(separator: ", ")
        return "Skipped \(names)\(unsupported.count > 2 ? " and \(unsupported.count - 2) more" : ""): can't convert those yet."
    }

    // MARK: Running

    var isWorking: Bool {
        if case .working = phase { return true }
        return false
    }

    /// Picks an output; picking it again unpicks it.
    func choose(_ offer: ConversionOffer) {
        guard !isWorking else { return }
        chosen = chosen == offer ? nil : offer
    }

    func runChosen() {
        if let chosen { run(chosen) }
    }

    func run(_ offer: ConversionOffer) {
        guard let files = selection?.files, !files.isEmpty, !isWorking else { return }
        runningOffer = offer
        phase = .working(done: 0, total: files.count)
        let settings = preferences.conversionSettings
        let worker = Task.detached(priority: .userInitiated) { [weak self] in
            await ConverterRegistry.run(offer.conversion, files: files, settings: settings) { [weak self] done, total in
                Task { @MainActor [weak self] in
                    guard let self, self.isWorking else { return }
                    self.phase = .working(done: done, total: total)
                }
            }
        }
        task = Task { [weak self] in
            let outcome = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            self?.finish(outcome)
        }
    }

    func cancel() { task?.cancel() }

    private func finish(_ outcome: ConversionOutcome) {
        task = nil
        phase = .finished(outcome)
        copied = false
        if preferences.copyConversionResult, !outcome.saved.isEmpty { copy() }
    }

    // MARK: Results

    var results: [URL] {
        if case .finished(let outcome) = phase { return outcome.saved }
        return []
    }

    func showInFinder() {
        guard !results.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(results)
    }

    func copy() {
        guard !results.isEmpty else { return }
        copyResults(results)
        copied = true
    }

    func clear() {
        guard !isWorking else { return }
        offersTask?.cancel()
        isLoadingOffers = false
        showsLoadingHint = false
        phase = .idle
        selection = nil
        offers = []
        chosen = nil
        copied = false
    }

    /// One or two lines saying what happened, for the finished state.
    func summary(of outcome: ConversionOutcome) -> String {
        let saved = outcome.saved
        var text: String
        if saved.count == 1 {
            text = "Saved \(saved[0].lastPathComponent)"
        } else if saved.count > 1 {
            let folders = Set(saved.map { $0.deletingLastPathComponent() })
            let isPages = runningOffer.map { if case .pdfPages = $0.conversion { true } else { false } } ?? false
            text = "Saved \(saved.count) \(isPages ? "pages" : "files")"
            if folders.count == 1, let folder = folders.first { text += " in “\(FileManager.default.displayName(atPath: folder.path))”" }
        } else {
            text = outcome.cancelled ? "Stopped" : "Nothing saved"
        }
        if outcome.cancelled, !saved.isEmpty { text = "Stopped. " + text }
        if !outcome.failures.isEmpty, !saved.isEmpty {
            text = "\(saved.count) saved, \(outcome.failures.count) failed"
        }
        return text
    }

    /// The first problem, said plainly: "IMG_2041.heic: Macarum couldn't read this image."
    func failureLine(of outcome: ConversionOutcome) -> String? {
        guard let first = outcome.failures.first else { return nil }
        let more = outcome.failures.count > 1 ? " (and \(outcome.failures.count - 1) more)" : ""
        return "\(first.fileName): \(first.message)\(more)"
    }
}
