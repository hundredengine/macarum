import Foundation
import UniformTypeIdentifiers

/// What goes on the clipboard when results are copied. One image goes as its file plus its
/// image data, so Finder pastes the file and chat apps paste the picture; anything else (a PDF,
/// several results) goes as files.
public enum ConversionClipboard {
    /// Image data above this stays off the clipboard (the file URL still goes); the history
    /// would drop it anyway (`CaptureRules.maxRepresentationBytes`).
    static let maxImageBytes = 50 * 1024 * 1024

    public static func snapshot(for urls: [URL]) -> ClipSnapshot {
        let items = urls.map { [ClipRepresentation(type: PasteboardType.fileURL, data: Data($0.absoluteString.utf8))] }
        guard urls.count == 1, let url = urls.first, let type = imageType(of: url),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxImageBytes,
              let data = try? Data(contentsOf: url) else { return ClipSnapshot(items: items) }
        return ClipSnapshot(items: [items[0] + [ClipRepresentation(type: type, data: data)]])
    }

    /// The pasteboard type for an image file Macarum writes, nil for anything else.
    static func imageType(of url: URL) -> String? {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        return PasteboardType.images.first { type.identifier == $0 }
    }
}
