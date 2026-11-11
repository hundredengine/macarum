/// Decides who gets the welcome window on launch.
public enum WelcomeGate {
    /// `askedAccessibility` is what versions before the welcome window saved after showing the
    /// macOS Accessibility prompt at launch; someone who has it set already knows the app.
    public static func shouldShow(welcomed: Bool, askedAccessibility: Bool) -> Bool {
        !welcomed && !askedAccessibility
    }
}

/// The permission step of the welcome window: it explains first, waits once the person has
/// asked macOS for Accessibility, and ends when macOS reports the permission.
public struct WelcomeFlow: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        /// Nothing asked yet: the window says what the permission is for.
        case explaining
        /// The macOS prompt and System Settings are open; the switch is not on yet.
        case waiting
        /// macOS reports the permission.
        case granted
    }

    public private(set) var step: Step
    private var asked = false

    public init(granted: Bool) {
        step = granted ? .granted : .explaining
    }

    /// The person pressed the button that brings up the macOS prompt.
    public mutating func askedForPermission() {
        asked = true
        if step == .explaining { step = .waiting }
    }

    /// Feed in what macOS says, as often as it is checked. The permission can arrive without
    /// the button (switched on by hand) and can be taken away again while the window is open.
    public mutating func permissionChecked(granted: Bool) {
        step = granted ? .granted : (asked ? .waiting : .explaining)
    }
}
