import AppKit
import MacarumCore

/// Watches the general pasteboard. macOS has no change notification, so this checks the
/// change counter twice a second (a single integer read) and only reads content when it moves.
@MainActor
final class ClipboardMonitor {
    private let pasteboard = NSPasteboard.general
    private var timer: DispatchSourceTimer?
    private var lastChangeCount = -1

    var rules: () -> CaptureRules = { CaptureRules() }
    var isPaused: () -> Bool = { false }
    var onCapture: (ClipSnapshot, SourceApp?) -> Void = { _, _ in }

    func start() {
        guard timer == nil else { return }
        // Whatever is on the clipboard at launch was already saved (or copied before Macarum
        // ran); reading it again would only count the same copy twice.
        lastChangeCount = pasteboard.changeCount
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // A generous leeway lets macOS batch the wake-ups with other work (saves energy).
        timer.schedule(deadline: .now(), repeating: .milliseconds(500), leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.resume()
        self.timer = timer
    }

    /// Skips whatever is on the pasteboard right now, so Macarum's own writes are not saved.
    func skipCurrent() {
        lastChangeCount = pasteboard.changeCount
    }

    private func poll() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        guard !isPaused() else { return }
        capture()
    }

    private func capture() {
        let front = NSWorkspace.shared.frontmostApplication
        let source = SourceApp(bundleID: front?.bundleIdentifier, name: front?.localizedName)
        let rules = rules()
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return }

        let allTypes = items.flatMap { $0.types.map(\.rawValue) }
        guard !rules.shouldIgnore(types: allTypes, source: source) else { return }

        let snapshot = ClipSnapshot(items: items.map { item in
            rules.typesToRead(from: item.types.map(\.rawValue)).compactMap { type in
                item.data(forType: NSPasteboard.PasteboardType(type)).map { ClipRepresentation(type: type, data: $0) }
            }
        })
        let trimmed = rules.addingPlainText(to: rules.trim(snapshot), extract: Self.plainText)
        guard !trimmed.items.isEmpty else { return }
        onCapture(trimmed, source)
    }

    /// Plain text out of RTF, RTFD or HTML, using AppKit's own readers.
    private static func plainText(type: String, data: Data) -> String? {
        let docType: NSAttributedString.DocumentType = switch type {
        case PasteboardType.rtf: .rtf
        case PasteboardType.rtfd: .rtfd
        default: .html
        }
        return try? NSAttributedString(data: data, options: [.documentType: docType], documentAttributes: nil).string
    }
}
