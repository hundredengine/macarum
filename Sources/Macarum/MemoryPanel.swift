import AppKit
import SwiftUI

/// The window the menu bar icon opens. A plain NSPopover anchors to the icon, and when the
/// icon sits in a menu bar hider or behind the notch that anchor is off screen, so the popover
/// opened half above the screen. This panel is always placed just under the menu bar, under
/// the icon when possible, and kept inside the screen.
@MainActor
final class MemoryPanelController {
    private let panel: Panel
    private let host: SizingHostingView
    private var outsideClickMonitor: Any?
    private var keyMonitor: Any?
    var onClose: () -> Void = {}
    /// How many file drags have reached the panel so far (from the converter). A drag that
    /// started outside and ended here keeps the panel open.
    var dragsReached: () -> Int = { 0 }
    /// Above zero while an open panel (or another of Macarum's own windows) is in front.
    private var holdOpen = 0
    private var pendingClose: Task<Void, Never>?

    /// Tells the controller when the SwiftUI content changes size, so the panel can follow.
    private final class SizingHostingView: NSHostingView<AnyView> {
        var onSizeChange: () -> Void = {}
        override func invalidateIntrinsicContentSize() {
            super.invalidateIntrinsicContentSize()
            onSizeChange()
        }
    }

    private final class Panel: NSPanel {
        var onResignKey: () -> Void = {}
        override var canBecomeKey: Bool { true }
        override func resignKey() {
            super.resignKey()
            onResignKey()
        }
    }

    init(content: AnyView) {
        host = SizingHostingView(rootView: content)
        panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let background = NSVisualEffectView()
        background.material = .menu
        background.state = .active
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        host.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            host.topAnchor.constraint(equalTo: background.topAnchor),
            host.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
        panel.onResignKey = { [weak self] in self?.closeUnlessDragging() }
        host.onSizeChange = { [weak self] in
            DispatchQueue.main.async { self?.fitToContent() }
        }
    }

    /// Grows or shrinks with the content (the converter section changes height), keeping the
    /// top edge under the menu bar.
    private func fitToContent() {
        guard panel.isVisible else { return }
        let size = host.fittingSize
        let frame = panel.frame
        guard abs(size.height - frame.height) > 0.5 || abs(size.width - frame.width) > 0.5 else { return }
        var newFrame = NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height)
        if let visible = panel.screen?.visibleFrame { newFrame.origin.y = max(newFrame.minY, visible.minY + 8) }
        panel.setFrame(newFrame, display: true)
    }

    var isShown: Bool { panel.isVisible }

    /// `anchor` is the menu bar icon's frame on screen, when macOS knows it.
    func show(below anchor: NSRect?) {
        let size = host.fittingSize
        let screen = anchor.flatMap { rect in NSScreen.screens.first { $0.frame.intersects(rect) } }
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let centerX = anchor.map(\.midX) ?? NSEvent.mouseLocation.x
        let x = min(max(centerX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        let y = visible.maxY - size.height - 4
        panel.setFrame(NSRect(x: x, y: max(y, visible.minY + 8), width: size.width, height: size.height), display: true)
        panel.makeKeyAndOrderFront(nil)

        // A click anywhere else, or Esc, closes it like a menu.
        // A press in Finder may be the start of a file drag towards the converter, so the
        // decision waits for the button to come up (see closeUnlessDragging).
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            let isRight = event.type == .rightMouseDown
            MainActor.assumeIsolated {
                guard let self, !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
                if isRight { self.close() } else { self.closeUnlessDragging() }
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            // Esc in the open panel belongs to the open panel.
            let closed = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.holdOpen == 0 else { return false }
                self.close()
                return true
            }
            return closed ? nil : event
        }
    }

    /// Runs `body` (an open panel) while the menu panel stays open behind it, then makes the
    /// menu panel key again.
    func keepOpen<T>(during body: () -> T) -> T {
        holdOpen += 1
        defer {
            holdOpen -= 1
            if panel.isVisible { panel.makeKeyAndOrderFront(nil) }
        }
        return body()
    }

    /// Closes like a menu, except when the press outside turns into a file drag that ends on
    /// the panel: then it stays open with the dropped files. A plain click closes it as soon
    /// as the button comes up.
    private func closeUnlessDragging() {
        guard holdOpen == 0, pendingClose == nil, panel.isVisible else { return }
        guard NSEvent.pressedMouseButtons & 1 != 0 else { return close() }
        let dragCount = NSPasteboard(name: .drag).changeCount
        let reached = dragsReached()
        pendingClose = Task { [weak self] in
            while NSEvent.pressedMouseButtons & 1 != 0 {
                try? await Task.sleep(for: .milliseconds(30))
            }
            // The drop is delivered just after the button comes up.
            if NSPasteboard(name: .drag).changeCount != dragCount {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard let self else { return }
            self.pendingClose = nil
            if self.dragsReached() == reached { self.close() }
        }
    }

    func close() {
        pendingClose?.cancel()
        pendingClose = nil
        guard panel.isVisible else { return }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        outsideClickMonitor = nil
        keyMonitor = nil
        panel.orderOut(nil)
        onClose()
    }
}
