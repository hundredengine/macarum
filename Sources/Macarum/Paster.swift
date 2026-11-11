import AppKit
import ApplicationServices
import Carbon.HIToolbox
import MacarumCore

enum PasteMode {
    /// Put it back on the clipboard and paste into the app in front.
    case paste
    /// Same, but text only, without fonts or colours.
    case pastePlainText
    /// Only put it back on the clipboard.
    case copy
}

@MainActor
enum Paster {
    /// Writes a saved item back to the clipboard, marked so the monitor does not save it again.
    /// `marked: false` leaves the marker off, for new content (converted files) that other
    /// clipboard tools should see like any copy.
    static func write(_ snapshot: ClipSnapshot, plainTextOnly: Bool, marked: Bool = true) {
        let items: [NSPasteboardItem]
        if plainTextOnly, let text = plainText(of: snapshot) {
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            items = [item]
        } else {
            items = snapshot.items.map { reps in
                let item = NSPasteboardItem()
                for rep in reps { item.setData(rep.data, forType: NSPasteboard.PasteboardType(rep.type)) }
                return item
            }
        }
        if marked { items.first?.setData(Data("1".utf8), forType: NSPasteboard.PasteboardType(PasteboardType.macarumRestored)) }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
    }

    /// Plain text for text items, or file paths (one per line) for files.
    static func plainText(of snapshot: ClipSnapshot) -> String? {
        if let data = snapshot.first(PasteboardType.plainText), let text = String(data: data, encoding: .utf8) {
            return text
        }
        let paths = snapshot.all(PasteboardType.fileURL)
            .compactMap { String(data: $0, encoding: .utf8).flatMap(URL.init(string:))?.path }
        return paths.isEmpty ? nil : paths.joined(separator: "\n")
    }

    static var canPasteDirectly: Bool { AXIsProcessTrusted() }

    /// Shows the macOS prompt that leads to Privacy & Security > Accessibility.
    static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Presses ⌘V in the app in front. Needs the Accessibility permission.
    static func sendPasteKeystroke() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
