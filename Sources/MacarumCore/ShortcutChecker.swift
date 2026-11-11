import Carbon.HIToolbox

public struct KeyModifiers: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let option = KeyModifiers(rawValue: 1 << 1)
    public static let control = KeyModifiers(rawValue: 1 << 2)
    public static let shift = KeyModifiers(rawValue: 1 << 3)
}

/// A key plus modifiers, independent of AppKit and Carbon flag layouts.
public struct KeyCombo: Hashable, Sendable, Codable {
    public let keyCode: Int
    public let modifiers: KeyModifiers

    public init(_ keyCode: Int, _ modifiers: KeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public enum ShortcutVerdict: Equatable, Sendable {
    case ok
    /// Allowed, but the person should know what it takes over.
    case warning(String)
    /// Would take over something important, so it is refused.
    case blocked(String)
}

/// macOS lets any app register any global shortcut, even one already in use, and then it is
/// unclear who receives it. So Macarum checks for clashes itself before accepting one.
public struct ShortcutChecker: Sendable {
    /// Shortcuts that belong to someone else, with who they belong to.
    public var reserved: [KeyCombo: String]

    public init(extraReserved: [KeyCombo: String] = [:]) {
        reserved = Self.macOSDefaults.merging(Self.knownApps) { a, _ in a }.merging(extraReserved) { a, _ in a }
    }

    public func check(_ combo: KeyCombo) -> ShortcutVerdict {
        let m = combo.modifiers
        if let owner = reserved[combo] { return .blocked("Already used by \(owner).") }
        if m.isEmpty || m == .shift { return .blocked("Needs ⌘, ⌥ or ⌃, or it would type a letter.") }
        if m == .command { return .blocked("Apps use ⌘ with one key for their own commands (⌘C, ⌘V, ⌘Z…).") }
        if m == [.command, .shift] {
            return .warning("Many apps use ⌘⇧ shortcuts (for example ⌘⇧V for paste without formatting).")
        }
        if m == .option || m == [.option, .shift] {
            return .warning("⌥ with a key normally types a special character, which this would replace.")
        }
        if m == .control || m == [.control, .shift] {
            return .warning("Terminal and Claude Code use ⌃ with a key (⌃C, ⌃V…).")
        }
        return .ok
    }

    /// macOS shortcuts that are on by default (they may be missing from the user's
    /// preferences file until changed). See System Settings > Keyboard > Keyboard Shortcuts.
    public static let macOSDefaults: [KeyCombo: String] = {
        var r: [KeyCombo: String] = [:]
        func add(_ key: Int, _ m: KeyModifiers, _ owner: String) { r[KeyCombo(key, m)] = owner }
        add(kVK_Space, .command, "Spotlight")
        add(kVK_Space, [.command, .option], "Finder search")
        add(kVK_Space, .control, "switching input source")
        add(kVK_Space, [.control, .option], "switching input source")
        add(kVK_Space, [.control, .command], "the emoji picker")
        add(kVK_Tab, .command, "the app switcher")
        add(kVK_Tab, [.command, .shift], "the app switcher")
        add(kVK_ANSI_Grave, .command, "switching windows")
        add(kVK_ANSI_3, [.command, .shift], "screenshots")
        add(kVK_ANSI_4, [.command, .shift], "screenshots")
        add(kVK_ANSI_5, [.command, .shift], "screenshots")
        add(kVK_ANSI_6, [.command, .shift], "screenshots")
        add(kVK_ANSI_3, [.command, .shift, .control], "screenshots")
        add(kVK_ANSI_4, [.command, .shift, .control], "screenshots")
        add(kVK_UpArrow, .control, "Mission Control")
        add(kVK_DownArrow, .control, "App Exposé")
        add(kVK_LeftArrow, .control, "switching Spaces")
        add(kVK_RightArrow, .control, "switching Spaces")
        add(kVK_ANSI_D, [.command, .option], "showing the Dock")
        add(kVK_ANSI_Q, [.command, .control], "locking the screen")
        add(kVK_ANSI_F, [.command, .control], "full screen")
        add(kVK_Escape, [.command, .option], "Force Quit")
        add(kVK_ANSI_H, [.command, .option], "hiding other apps")
        add(kVK_ANSI_Slash, [.command, .shift], "the Help menu")
        add(kVK_ANSI_N, [.command, .control], "Quick Note")
        add(kVK_ANSI_8, [.command, .option], "Zoom")
        add(kVK_ANSI_Equal, [.command, .option], "Zoom")
        add(kVK_ANSI_Minus, [.command, .option], "Zoom")
        add(kVK_F5, [.command, .option], "Accessibility shortcuts")
        add(kVK_ANSI_T, [.command, .control], "the Characters viewer")
        return r
    }()

    /// Global shortcuts of popular apps that are hard to notice when taken over.
    public static let knownApps: [KeyCombo: String] = {
        var r: [KeyCombo: String] = [:]
        r[KeyCombo(kVK_Space, .option)] = "ChatGPT, Claude and Raycast"
        r[KeyCombo(kVK_Space, [.command, .shift])] = "1Password"
        r[KeyCombo(kVK_ANSI_Backslash, .command)] = "1Password"
        return r
    }()

    /// Reads the parameters macOS stores per shortcut: [character, key code, Cocoa modifier flags].
    public static func comboFromSymbolicHotKey(parameters: [Int]) -> KeyCombo? {
        guard parameters.count >= 3, parameters[1] != 0xFFFF else { return nil }
        let flags = parameters[2]
        var m: KeyModifiers = []
        if flags & (1 << 17) != 0 { m.insert(.shift) }
        if flags & (1 << 18) != 0 { m.insert(.control) }
        if flags & (1 << 19) != 0 { m.insert(.option) }
        if flags & (1 << 20) != 0 { m.insert(.command) }
        return KeyCombo(parameters[1], m)
    }
}
