import AppKit

/// The macaron silhouette for the menu bar, drawn in code as a template image so macOS
/// tints it for light, dark and tinted menu bars. It follows the app icon's proportions:
/// two broad, low shells, each with feet that stick out a little, and the cream between them
/// drawn fainter behind a hairline gap. Low shells and the faint cream are what keep it from
/// reading as a burger.
enum MenuBarIcon {
    static let image = make(withDot: false)
    /// Shown while memory pressure is high: a small dot at the top right, cut out of the
    /// macaron so it reads at menu bar size.
    static let imageWithDot = make(withDot: true)

    private static func make(withDot: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setFill()
            shell(flatY: 7.6, domeY: 4.0).fill()
            pill(y: 7.3, height: 1.1, inset: 1.5).fill()  // feet under the top shell
            NSColor.black.withAlphaComponent(0.42).setFill()
            pill(y: 8.9, height: 1.7, inset: 2.0).fill()  // cream
            NSColor.black.setFill()
            pill(y: 11.1, height: 1.1, inset: 1.5).fill() // feet over the bottom shell
            shell(flatY: 11.9, domeY: 15.5).fill()        // the same shell, mirrored
            if withDot {
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: NSRect(x: 11.6, y: -0.6, width: 7, height: 7)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSBezierPath(ovalIn: NSRect(x: 13.1, y: 0.9, width: 4, height: 4)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = withDot ? "Macarum, memory pressure high" : "Macarum"
        return image
    }

    /// One shell: straight sides from its flat edge at `flatY`, then a broad dome to `domeY`.
    private static func shell(flatY: CGFloat, domeY: CGFloat) -> NSBezierPath {
        let left: CGFloat = 2.0, right: CGFloat = 16.0, mid: CGFloat = 9
        let side = flatY + (domeY - flatY) * 0.35
        let p = NSBezierPath()
        p.move(to: NSPoint(x: left, y: flatY))
        p.line(to: NSPoint(x: left, y: side))
        p.curve(to: NSPoint(x: mid, y: domeY),
                controlPoint1: NSPoint(x: left, y: domeY),
                controlPoint2: NSPoint(x: mid - (right - left) * 0.32, y: domeY))
        p.curve(to: NSPoint(x: right, y: side),
                controlPoint1: NSPoint(x: mid + (right - left) * 0.32, y: domeY),
                controlPoint2: NSPoint(x: right, y: domeY))
        p.line(to: NSPoint(x: right, y: flatY))
        p.close()
        return p
    }

    /// A full-width band with round ends, `inset` from the icon's left and right edges.
    private static func pill(y: CGFloat, height: CGFloat, inset: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: NSRect(x: inset, y: y, width: 18 - inset * 2, height: height),
                     xRadius: height / 2, yRadius: height / 2)
    }
}
