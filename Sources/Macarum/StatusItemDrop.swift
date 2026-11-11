import AppKit

/// Lets files be dragged onto the menu bar icon: hovering opens the panel (like a spring-loaded
/// folder) so the files can be dropped on the converter, and dropping on the icon itself picks
/// them straight away. The status item's window forwards dragging messages to its delegate.
@MainActor
final class StatusItemDropTarget: NSObject, NSWindowDelegate, NSDraggingDestination {
    private let onEnter: () -> Void
    private let onDrop: ([URL]) -> Void

    init(window: NSWindow, onEnter: @escaping () -> Void, onDrop: @escaping ([URL]) -> Void) {
        self.onEnter = onEnter
        self.onDrop = onDrop
        super.init()
        window.registerForDraggedTypes([.fileURL])
        window.delegate = self
    }

    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !Self.fileURLs(sender).isEmpty else { return [] }
        onEnter()
        return .copy
    }

    func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Self.fileURLs(sender).isEmpty ? [] : .copy
    }

    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = Self.fileURLs(sender)
        guard !urls.isEmpty else { return false }
        onDrop(urls)
        return true
    }

    private static func fileURLs(_ sender: any NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}
