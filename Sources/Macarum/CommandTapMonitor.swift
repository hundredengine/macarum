import AppKit
import MacarumCore

/// Fires when ⌘ is pressed three times on its own. Watching keys in other apps needs the
/// Accessibility permission; without it macOS simply delivers nothing, so this re-arms
/// itself once the permission is granted.
@MainActor
final class CommandTapMonitor {
    private var detector = TapDetector()
    private var monitors: [Any] = []
    private var trustTimer: Timer?
    private var commandDownAt: TimeInterval?
    private var lastModifiers: TapDetector.Modifiers = .none
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    var isRunning: Bool { !monitors.isEmpty }

    func start() {
        guard monitors.isEmpty else { return }
        install()
        if !AXIsProcessTrusted() { waitForTrust() }
    }

    func stop() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        trustTimer?.invalidate()
        trustTimer = nil
        detector = TapDetector()
    }

    private func install() {
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let input = Input(event)
            MainActor.assumeIsolated { self?.feed(input) }
        }) {
            monitors.append(global)
        }
        // Global monitors skip Macarum's own windows, so the panel can be closed the same way.
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let input = Input(event)
            MainActor.assumeIsolated { self?.feed(input) }
            return event
        }) {
            monitors.append(local)
        }
    }

    /// Checks every few seconds until the permission arrives, then reinstalls the monitors.
    private func waitForTrust() {
        trustTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AXIsProcessTrusted() else { return }
                self.trustTimer?.invalidate()
                self.trustTimer = nil
                for m in self.monitors { NSEvent.removeMonitor(m) }
                self.monitors = []
                self.install()
            }
        }
        trustTimer?.tolerance = 1
    }

    private func feed(_ input: Input) {
        switch input {
        case .other:
            detector.keyPressed()
        case .modifiers(let m, let time):
            // Stamped on every fresh press, so a press whose release was never seen cannot linger.
            if m == .onlyTarget, lastModifiers != .onlyTarget { commandDownAt = time }
            defer { lastModifiers = m }
            if m == .none, let downAt = commandDownAt {
                // Another monitor (the panel's own key handling) may swallow a key before it
                // reaches this one, so also ask macOS when a key last went down: ⌘E or ⌘↩
                // inside the panel must not count as a tap.
                let sinceKey = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
                if sinceKey < time - downAt + 0.01 { detector.keyPressed() }
            }
            if m != .onlyTarget { commandDownAt = nil }
            if detector.modifiersChanged(to: m, at: time) { action() }
        }
    }

    /// The parts of an event that matter, copied out so they can cross to the main actor.
    private enum Input: Sendable {
        case modifiers(TapDetector.Modifiers, TimeInterval)
        case other

        init(_ event: NSEvent) {
            guard event.type == .flagsChanged else {
                self = .other
                return
            }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift, .function, .capsLock])
            let m: TapDetector.Modifiers = flags.isEmpty ? .none : (flags == .command ? .onlyTarget : .other)
            self = .modifiers(m, event.timestamp)
        }
    }
}
