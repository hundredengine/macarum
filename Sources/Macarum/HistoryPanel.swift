import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A floating panel that takes the keyboard without making Macarum the active app, so the
/// app underneath keeps focus and receives the paste (the way Spotlight works).
final class HistoryPanel: NSPanel {
    var onResignKey: () -> Void = {}

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: PanelMetrics.size),
            // Borderless: a titled window reserves an invisible title bar that pushes content down.
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey()
    }
}

@MainActor
final class HistoryPanelController {
    private let panel = HistoryPanel()
    private let model: HistoryModel
    private var keyMonitor: Any?

    var isVisible: Bool { panel.isVisible }
    var openSettings: () -> Void = {}

    init(model: HistoryModel, preferences: Preferences, accessDenied: @escaping () -> Bool) {
        self.model = model
        let glass = NSGlassEffectView()
        glass.cornerRadius = PanelMetrics.cornerRadius
        let host = NSHostingView(rootView: PanelRoot(model: model, preferences: preferences, accessDenied: accessDenied,
                                                      openSettings: { [weak self] in self?.openSettings() }))
        host.sizingOptions = []
        glass.contentView = host
        panel.contentView = glass
        panel.onResignKey = { [weak self] in self?.hide() }
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        guard !panel.isVisible else { return }
        model.panelWillOpen()
        position()
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    func hide() {
        guard panel.isVisible else { return }
        removeKeyMonitor()
        panel.orderOut(nil)
        model.panelDidClose()
    }

    /// Centred on the screen with the pointer, a little above the middle, like Spotlight.
    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = PanelMetrics.size
        let x = visible.midX - size.width / 2
        let y = visible.minY + (visible.height - size.height) * 0.62
        panel.setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height), display: false)
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let key = KeyPress(event)
            let windowNumber = event.windowNumber
            let used = MainActor.assumeIsolated { () -> Bool in
                guard let self, windowNumber == self.panel.windowNumber else { return false }
                return self.handle(key)
            }
            return used ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Returns true when the key was used; everything else goes to the search field.
    private func handle(_ key: KeyPress) -> Bool {
        let command = key.flags.contains(.command)
        let option = key.flags.contains(.option)
        let shift = key.flags.contains(.shift)

        // While the footer asks "Delete all?", only ↩ (yes) and Esc (no) mean something.
        if model.isConfirmingClearAll {
            switch key.code {
            case kVK_Return, kVK_ANSI_KeypadEnter: model.clearAll()
            case kVK_Escape: model.cancelClearAll()
            default: return true
            }
            return true
        }

        // While editing, keys belong to the text; only Esc (cancel) and ⌘↩ / ⌘S (save) are taken.
        if model.isEditing {
            switch key.code {
            case kVK_Escape: model.cancelEditing()
            case kVK_Return where command, kVK_ANSI_KeypadEnter where command, kVK_ANSI_S where command:
                model.saveEditing()
            default: return false
            }
            return true
        }

        switch key.code {
        case kVK_DownArrow:
            command ? model.moveToEdge(top: false, extend: shift) : model.moveSelection(by: 1, extend: shift)
        case kVK_UpArrow:
            command ? model.moveToEdge(top: true, extend: shift) : model.moveSelection(by: -1, extend: shift)
        case kVK_PageDown:
            model.moveSelection(by: 10, extend: shift)
        case kVK_PageUp:
            model.moveSelection(by: -10, extend: shift)
        case kVK_ANSI_Z where command && !shift && model.pendingUndo != nil:
            model.undoDelete()
        case kVK_Return, kVK_ANSI_KeypadEnter:
            model.choose(command ? .copy : (option ? .pastePlainText : .paste))
        case kVK_Escape:
            if model.query.isEmpty { hide() } else { model.query = "" }
        case kVK_Tab:
            model.cycleFilter(backwards: shift)
        case kVK_Delete where command && shift, kVK_ForwardDelete where command && shift:
            model.askToClearAll()
        case kVK_Delete where command, kVK_ForwardDelete where command:
            // Only ⌘⌫ deletes items; ⌫ alone always edits the search text (spec: "Selection and delete keys").
            model.deleteSelected()
        case kVK_ANSI_E where command:
            model.startEditing()
        case kVK_ANSI_P where command:
            model.togglePinSelected()
        case kVK_ANSI_Comma where command:
            hide()
            openSettings()
        default:
            if command, !option,
               let digit = Self.digitKeys.firstIndex(of: key.code) ?? Self.keypadDigitKeys.firstIndex(of: key.code) {
                model.choose(index: digit, mode: .paste)
                return true
            }
            return false
        }
        return true
    }

    private static let digitKeys = [
        kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
    ]
    private static let keypadDigitKeys = [
        kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4, kVK_ANSI_Keypad5,
        kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9,
    ]
}

/// The parts of a key event the panel needs, copied out so they can cross to the main actor.
private struct KeyPress: Sendable {
    let code: Int
    let flags: NSEvent.ModifierFlags

    init(_ event: NSEvent) {
        code = Int(event.keyCode)
        flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    }
}

/// Re-reads the access state each time the panel content redraws.
private struct PanelRoot: View {
    let model: HistoryModel
    let preferences: Preferences
    let accessDenied: () -> Bool
    let openSettings: () -> Void

    var body: some View {
        HistoryView(model: model, preferences: preferences, accessDenied: accessDenied(), openSettings: openSettings)
    }
}
